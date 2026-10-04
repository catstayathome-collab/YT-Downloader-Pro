import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "create_macos_source_review_packet.py"


def load_script():
    if not SCRIPT.is_file():
        raise AssertionError(f"required script is missing: {SCRIPT}")
    spec = importlib.util.spec_from_file_location("create_macos_source_review_packet", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MacOSSourceReviewPacketTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script()
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "tools" / "licenses").mkdir(parents=True)
        (self.root / "docs" / "swift-2.0").mkdir(parents=True)
        self.archive_root = self.root / "archives"
        self.archive_root.mkdir()
        self.output = self.root / "packet.zip"

        self.archive_payload = b"source archive contents\n"
        (self.archive_root / "component-1.0.tar.xz").write_bytes(self.archive_payload)
        (self.root / "SOURCE_AVAILABILITY.md").write_text(
            "> **Status: incomplete for public distribution.**\n",
            encoding="utf-8",
        )
        (self.root / "THIRD_PARTY_NOTICES.md").write_text("notices\n", encoding="utf-8")
        (self.root / "LICENSE_REVIEW_BRIEF.md").write_text("review brief\n", encoding="utf-8")
        (self.root / "docs" / "swift-2.0" / "SBOM_AND_LICENSES.md").write_text(
            "SBOM and licenses\n",
            encoding="utf-8",
        )
        (self.root / "tools" / "macos-helper-inventory.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "platform": "macos",
                    "components": [{"id": "component", "version": "1.0"}],
                }
            ),
            encoding="utf-8",
        )
        (self.root / "tools" / "licenses" / "Component-MIT.txt").write_text(
            "license\n",
            encoding="utf-8",
        )
        (self.root / "docs" / "BUILD_INFO.md").write_text("build info\n", encoding="utf-8")

        self.inventory_path = self.root / "tools" / "macos-source-archives.json"
        self.inventory_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "platform": "macos",
                    "releaseVersion": "2.0.1",
                    "publicDistributionReady": False,
                    "limitations": ["Transitive source review is incomplete."],
                    "components": [
                        {
                            "id": "component",
                            "name": "Component",
                            "version": "1.0",
                            "source": {
                                "fileName": "component-1.0.tar.xz",
                                "url": "https://example.com/component-1.0.tar.xz",
                                "sha256": hashlib.sha256(self.archive_payload).hexdigest(),
                            },
                            "evidenceFiles": [
                                "tools/licenses/Component-MIT.txt",
                                "docs/BUILD_INFO.md",
                            ],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def create_packet(self, *, metadata_only=False):
        return self.module.create_packet(
            repository_root=self.root,
            inventory_path=self.inventory_path,
            archive_root=self.archive_root,
            output_path=self.output,
            metadata_only=metadata_only,
        )

    def test_creates_deterministic_internal_review_packet(self):
        first = self.create_packet()
        first_bytes = self.output.read_bytes()
        second = self.create_packet()

        self.assertEqual(first, second)
        self.assertEqual(first_bytes, self.output.read_bytes())
        self.assertFalse(first["publicDistributionReady"])
        self.assertEqual(first["releaseVersion"], "2.0.1")

        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(
                archive.namelist(),
                sorted(archive.namelist()),
            )
            self.assertIn("INTERNAL_REVIEW_ONLY.json", archive.namelist())
            self.assertIn("SourceArchives/component-1.0.tar.xz", archive.namelist())
            status = json.loads(archive.read("INTERNAL_REVIEW_ONLY.json"))
            self.assertFalse(status["publicDistributionReady"])
            self.assertEqual(status["limitations"], ["Transitive source review is incomplete."])

    def test_rejects_missing_source_archive_by_default(self):
        (self.archive_root / "component-1.0.tar.xz").unlink()

        with self.assertRaisesRegex(self.module.PacketError, "missing source archive"):
            self.create_packet()

    def test_rejects_source_archive_hash_mismatch(self):
        (self.archive_root / "component-1.0.tar.xz").write_bytes(b"tampered")

        with self.assertRaisesRegex(self.module.PacketError, "SHA-256 mismatch"):
            self.create_packet()

    def test_metadata_only_packet_omits_archives_and_stays_internal(self):
        (self.archive_root / "component-1.0.tar.xz").unlink()

        result = self.create_packet(metadata_only=True)

        self.assertFalse(result["includesSourceArchives"])
        with zipfile.ZipFile(self.output) as archive:
            self.assertNotIn("SourceArchives/component-1.0.tar.xz", archive.namelist())
            self.assertIn("SOURCE_ARCHIVE_INVENTORY.json", archive.namelist())

    def test_rejects_credential_bearing_or_non_https_source_url(self):
        inventory = json.loads(self.inventory_path.read_text(encoding="utf-8"))
        inventory["components"][0]["source"]["url"] = "https://user:secret@example.com/source.tar.xz"
        self.inventory_path.write_text(json.dumps(inventory), encoding="utf-8")

        with self.assertRaisesRegex(self.module.PacketError, "credential-free HTTPS"):
            self.create_packet()

    def test_rejects_version_mismatch_with_helper_inventory(self):
        inventory = json.loads(self.inventory_path.read_text(encoding="utf-8"))
        inventory["components"][0]["version"] = "2.0"
        self.inventory_path.write_text(json.dumps(inventory), encoding="utf-8")

        with self.assertRaisesRegex(self.module.PacketError, "version.*helper inventory"):
            self.create_packet()

    def test_rejects_source_archive_symlink_outside_archive_root(self):
        outside = self.root / "outside.tar.xz"
        outside.write_bytes(self.archive_payload)
        archive = self.archive_root / "component-1.0.tar.xz"
        archive.unlink()
        archive.symlink_to(outside)

        with self.assertRaisesRegex(self.module.PacketError, "stay inside archive root"):
            self.create_packet()


if __name__ == "__main__":
    unittest.main()
