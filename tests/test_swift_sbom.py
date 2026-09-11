import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts" / "generate_swift_sbom.py"
REPOSITORY_INVENTORY = ROOT / "tools" / "macos-helper-inventory.json"
REPOSITORY_HELPERS = ROOT / "tools"
REPOSITORY_LICENSES = ROOT / "tools" / "licenses"


def load_generator():
    if not GENERATOR.is_file():
        raise AssertionError(f"required script is missing: {GENERATOR}")
    spec = importlib.util.spec_from_file_location("generate_swift_sbom", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SwiftSBOMTests(unittest.TestCase):
    def setUp(self):
        self.generator = load_generator()
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.helpers = self.root / "Helpers"
        self.licenses = self.root / "licenses"
        self.helpers.mkdir()
        self.licenses.mkdir()

        self.helper_payloads = {
            "yt-dlp_macos": b"yt-dlp-test-binary",
            "ffmpeg": b"ffmpeg-test-binary",
            "ffprobe": b"ffprobe-test-binary",
            "qjs": b"qjs-test-binary",
        }
        for name, payload in self.helper_payloads.items():
            (self.helpers / name).write_bytes(payload)

        for name in (
            "GPL-3.0-or-later.txt",
            "yt-dlp-Unlicense.txt",
            "yt-dlp-THIRD_PARTY_LICENSES.txt",
            "FFmpeg-LGPL-2.1.txt",
            "LAME-LGPL-2.0.txt",
            "QuickJS-MIT.txt",
        ):
            (self.licenses / name).write_text(f"license for {name}\n", encoding="utf-8")

        components = [
            self.component(
                component_id="yt-dlp",
                name="yt-dlp macOS standalone",
                version="2026.07.04",
                license_expression="GPL-3.0-or-later",
                helper_names=["yt-dlp_macos"],
                license_files=[
                    "GPL-3.0-or-later.txt",
                    "yt-dlp-Unlicense.txt",
                    "yt-dlp-THIRD_PARTY_LICENSES.txt",
                ],
            ),
            self.component(
                component_id="ffmpeg",
                name="FFmpeg",
                version="9.0",
                license_expression="LGPL-2.1-or-later AND LGPL-2.0-or-later",
                helper_names=["ffmpeg", "ffprobe"],
                license_files=["FFmpeg-LGPL-2.1.txt", "LAME-LGPL-2.0.txt"],
            ),
            self.component(
                component_id="quickjs",
                name="QuickJS",
                version="2026-06-04",
                license_expression="MIT",
                helper_names=["qjs"],
                license_files=["QuickJS-MIT.txt"],
            ),
        ]
        self.inventory = self.root / "macos-helper-inventory.json"
        self.inventory.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "platform": "macos",
                    "components": components,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def component(
        self,
        *,
        component_id,
        name,
        version,
        license_expression,
        helper_names,
        license_files,
    ):
        return {
            "id": component_id,
            "name": name,
            "version": version,
            "supplier": "Organization: upstream project",
            "downloadLocation": f"https://example.invalid/{component_id}/{version}",
            "sourceInfo": "Pinned upstream source used for this bundled component.",
            "licenseConcluded": license_expression,
            "licenseDeclared": license_expression,
            "licenseFiles": [
                {
                    "name": license_name,
                    "sha256": hashlib.sha256(
                        (self.licenses / license_name).read_bytes()
                    ).hexdigest(),
                }
                for license_name in license_files
            ],
            "helpers": [
                {
                    "name": helper_name,
                    "sha256": hashlib.sha256(self.helper_payloads[helper_name]).hexdigest(),
                    "architectures": ["arm64", "x86_64"] if helper_name == "yt-dlp_macos" else ["arm64"],
                }
                for helper_name in helper_names
            ],
        }

    def generate(self):
        return self.generator.generate_sbom(
            inventory_path=self.inventory,
            helper_root=self.helpers,
            license_root=self.licenses,
            app_version="2.0.0",
            created="2026-08-27T00:00:00Z",
        )

    def test_generates_deterministic_spdx_with_exact_helper_checksums(self):
        first = self.generate()
        second = self.generate()

        self.assertEqual(first, second)
        self.assertEqual(first["spdxVersion"], "SPDX-2.3")
        self.assertEqual(first["dataLicense"], "CC0-1.0")
        self.assertEqual(first["name"], "YT Downloader Pro 2 2.0.0 macOS SBOM")
        self.assertEqual(first["creationInfo"]["created"], "2026-08-27T00:00:00Z")
        self.assertEqual(
            [package["name"] for package in first["packages"]],
            ["YT Downloader Pro 2", "FFmpeg", "QuickJS", "yt-dlp macOS standalone"],
        )
        helper_files = {item["fileName"]: item for item in first["files"]}
        self.assertEqual(set(helper_files), {f"./Contents/Helpers/{name}" for name in self.helper_payloads})
        for helper_name, payload in self.helper_payloads.items():
            checksum = helper_files[f"./Contents/Helpers/{helper_name}"]["checksums"][0]
            self.assertEqual(checksum, {"algorithm": "SHA256", "checksumValue": hashlib.sha256(payload).hexdigest()})
        self.assertEqual(first["documentNamespace"], second["documentNamespace"])
        self.assertFalse(
            any(
                relationship["relationshipType"] == "CONTAINS"
                for relationship in first["relationships"]
            )
        )
        self.assertIn(
            {
                "spdxElementId": "SPDXRef-File-qjs",
                "relationshipType": "GENERATED_FROM",
                "relatedSpdxElement": "SPDXRef-Package-quickjs",
            },
            first["relationships"],
        )

    def test_rejects_helper_hash_mismatch(self):
        (self.helpers / "ffmpeg").write_bytes(b"tampered")

        with self.assertRaisesRegex(self.generator.InventoryError, "ffmpeg.*SHA-256"):
            self.generate()

    def test_rejects_missing_declared_license_file(self):
        (self.licenses / "GPL-3.0-or-later.txt").unlink()

        with self.assertRaisesRegex(self.generator.InventoryError, "GPL-3.0-or-later.txt"):
            self.generate()

    def test_rejects_declared_license_hash_mismatch(self):
        (self.licenses / "QuickJS-MIT.txt").write_text("tampered license\n", encoding="utf-8")

        with self.assertRaisesRegex(self.generator.InventoryError, "QuickJS-MIT.txt.*SHA-256"):
            self.generate()

    def test_rejects_duplicate_or_missing_helper_ownership(self):
        data = json.loads(self.inventory.read_text(encoding="utf-8"))
        data["components"][1]["helpers"].append(data["components"][0]["helpers"][0])
        self.inventory.write_text(json.dumps(data), encoding="utf-8")

        with self.assertRaisesRegex(self.generator.InventoryError, "yt-dlp_macos.*more than once"):
            self.generate()

    def test_represents_static_library_as_its_own_component(self):
        data = json.loads(self.inventory.read_text(encoding="utf-8"))
        data["components"].append(
            {
                "id": "lame",
                "name": "LAME",
                "version": "3.100",
                "supplier": "Organization: The LAME Project",
                "downloadLocation": "https://example.invalid/lame/3.100",
                "sourceInfo": "Pinned upstream source statically linked into FFmpeg.",
                "licenseConcluded": "LGPL-2.0-or-later",
                "licenseDeclared": "LGPL-2.0-or-later",
                "licenseFiles": [
                    {
                        "name": "LAME-LGPL-2.0.txt",
                        "sha256": hashlib.sha256(
                            (self.licenses / "LAME-LGPL-2.0.txt").read_bytes()
                        ).hexdigest(),
                    }
                ],
                "helpers": [],
                "embeddedInHelpers": ["ffmpeg"],
            }
        )
        self.inventory.write_text(json.dumps(data), encoding="utf-8")

        sbom = self.generate()

        packages = {package["name"]: package for package in sbom["packages"]}
        self.assertEqual(packages["LAME"]["licenseConcluded"], "LGPL-2.0-or-later")
        self.assertIn(
            {
                "spdxElementId": "SPDXRef-File-ffmpeg",
                "relationshipType": "STATIC_LINK",
                "relatedSpdxElement": "SPDXRef-Package-lame",
            },
            sbom["relationships"],
        )

    def test_validates_source_helpers_but_records_resigned_bundle_checksums(self):
        signed_helpers = self.root / "SignedHelpers"
        signed_helpers.mkdir()
        for helper_name, payload in self.helper_payloads.items():
            (signed_helpers / helper_name).write_bytes(payload + b"-developer-id-signature")

        sbom = self.generator.generate_sbom(
            inventory_path=self.inventory,
            source_helper_root=self.helpers,
            helper_root=signed_helpers,
            license_root=self.licenses,
            app_version="2.0.0",
            created="2026-08-27T00:00:00Z",
        )

        helper_files = {item["fileName"]: item for item in sbom["files"]}
        for helper_name, payload in self.helper_payloads.items():
            helper = helper_files[f"./Contents/Helpers/{helper_name}"]
            self.assertEqual(
                helper["checksums"],
                [
                    {
                        "algorithm": "SHA256",
                        "checksumValue": hashlib.sha256(
                            payload + b"-developer-id-signature"
                        ).hexdigest(),
                    }
                ],
            )
            self.assertIn(
                f"Canonical source SHA-256: {hashlib.sha256(payload).hexdigest()}",
                helper["comment"],
            )

    def test_rejects_impossible_created_timestamp(self):
        with self.assertRaisesRegex(self.generator.InventoryError, "created"):
            self.generator.generate_sbom(
                inventory_path=self.inventory,
                helper_root=self.helpers,
                license_root=self.licenses,
                app_version="2.0.0",
                created="2026-99-99T99:99:99Z",
            )


class SwiftRepositoryInventoryTests(unittest.TestCase):
    def test_repository_inventory_matches_every_bundled_helper_and_license(self):
        generator = load_generator()
        with tempfile.TemporaryDirectory() as temporary_directory:
            bundle_helpers = Path(temporary_directory) / "Helpers"
            bundle_helpers.mkdir()
            for helper_name in ("yt-dlp_macos", "ffmpeg", "ffprobe", "qjs"):
                (bundle_helpers / helper_name).write_bytes(
                    (REPOSITORY_HELPERS / helper_name).read_bytes()
                )

            sbom = generator.generate_sbom(
                inventory_path=REPOSITORY_INVENTORY,
                source_helper_root=REPOSITORY_HELPERS,
                helper_root=bundle_helpers,
                license_root=REPOSITORY_LICENSES,
                app_version="2.0.0",
            )

        helper_files = {item["fileName"]: item for item in sbom["files"]}
        self.assertEqual(
            set(helper_files),
            {f"./Contents/Helpers/{name}" for name in ("yt-dlp_macos", "ffmpeg", "ffprobe", "qjs")},
        )
        for helper_name in ("yt-dlp_macos", "ffmpeg", "ffprobe", "qjs"):
            expected = hashlib.sha256((REPOSITORY_HELPERS / helper_name).read_bytes()).hexdigest()
            self.assertEqual(
                helper_files[f"./Contents/Helpers/{helper_name}"]["checksums"],
                [{"algorithm": "SHA256", "checksumValue": expected}],
            )
        packages = {item["name"]: item for item in sbom["packages"]}
        self.assertEqual(packages["yt-dlp macOS standalone"]["licenseConcluded"], "GPL-3.0-or-later")
        self.assertEqual(
            packages["yt-dlp macOS standalone"]["attributionTexts"],
            [
                "Bundled license: Contents/Resources/ThirdPartyLicenses/GPL-3.0-or-later.txt (SHA-256 3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986)",
                "Bundled license: Contents/Resources/ThirdPartyLicenses/yt-dlp-Unlicense.txt (SHA-256 7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c)",
                "Bundled license: Contents/Resources/ThirdPartyLicenses/yt-dlp-THIRD_PARTY_LICENSES.txt (SHA-256 b085c65586a953cdb4b13c6390d63ec984d66912e4b6a19e66ba3582f2ed104b)",
            ],
        )


if __name__ == "__main__":
    unittest.main()
