import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check_macos_public_release_readiness.py"


def load_script():
    if not SCRIPT.is_file():
        raise AssertionError(f"required script is missing: {SCRIPT}")
    spec = importlib.util.spec_from_file_location("check_macos_public_release_readiness", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeRunner:
    def __init__(self, responses):
        self.responses = responses

    def __call__(self, arguments):
        key = tuple(arguments)
        return self.responses.get(
            key,
            subprocess.CompletedProcess(arguments, 1, "", "not configured"),
        )


class MacOSPublicReleaseReadinessTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script()
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "updates").mkdir()
        (self.root / "tools").mkdir()
        (self.root / "docs" / "swift-2.0").mkdir(parents=True)
        (self.root / "updates" / "macos.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "platform": "macos",
                    "latest_version": "0.0.0",
                    "release_url": "https://example.invalid/release",
                    "download_url": "https://example.invalid/download.zip",
                    "sha256": "0" * 64,
                }
            ),
            encoding="utf-8",
        )
        (self.root / "tools" / "macos-source-archives.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "platform": "macos",
                    "releaseVersion": "2.0.1",
                    "publicDistributionReady": False,
                    "limitations": ["Transitive source review is incomplete."],
                    "components": [{"id": "component", "version": "1.0"}],
                }
            ),
            encoding="utf-8",
        )
        (self.root / "docs" / "swift-2.0" / "RELEASE_NOTES_2.0.1.md").write_text(
            "# YT Downloader Pro 2.0.1 Release Notes\n\ninternal release candidate\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_current_blockers_fail_closed_without_leaking_command_errors(self):
        runner = FakeRunner(
            {
                ("security", "find-identity", "-v", "-p", "codesigning"): subprocess.CompletedProcess(
                    [], 0, "0 valid identities found\n", ""
                ),
                ("xcrun", "notarytool", "history", "--keychain-profile", "YTDP_NOTARY"): subprocess.CompletedProcess(
                    [], 1, "", "secret-bearing keychain error"
                ),
            }
        )

        report = self.module.evaluate_repository(
            repository_root=self.root,
            expected_version="2.0.1",
            notary_profile="YTDP_NOTARY",
            command_runner=runner,
        )

        self.assertEqual(report["overallStatus"], "blocked")
        statuses = {gate["id"]: gate["status"] for gate in report["gates"]}
        self.assertEqual(statuses["developer_id"], "blocked")
        self.assertEqual(statuses["notary_profile"], "blocked")
        self.assertEqual(statuses["source_distribution"], "blocked")
        self.assertEqual(statuses["update_manifest"], "blocked")
        self.assertNotIn("secret-bearing", json.dumps(report))

    def test_all_machine_verifiable_gates_can_pass(self):
        manifest = json.loads((self.root / "updates" / "macos.json").read_text(encoding="utf-8"))
        manifest.update(
            {
                "latest_version": "2.0.1",
                "release_url": "https://github.com/example/releases/tag/macos-v2.0.1",
                "download_url": "https://github.com/example/releases/download/macos-v2.0.1/app.zip",
                "sha256": "a" * 64,
            }
        )
        (self.root / "updates" / "macos.json").write_text(json.dumps(manifest), encoding="utf-8")
        source_inventory = json.loads(
            (self.root / "tools" / "macos-source-archives.json").read_text(encoding="utf-8")
        )
        source_inventory["publicDistributionReady"] = True
        source_inventory["limitations"] = []
        source_inventory["approvalReference"] = "restricted-evidence:license-review-2026-09-30"
        (self.root / "tools" / "macos-source-archives.json").write_text(
            json.dumps(source_inventory),
            encoding="utf-8",
        )
        runner = FakeRunner(
            {
                ("security", "find-identity", "-v", "-p", "codesigning"): subprocess.CompletedProcess(
                    [], 0, '  1) ABC "Developer ID Application: Example (TEAMID1234)"\n     1 valid identities found\n', ""
                ),
                ("xcrun", "notarytool", "history", "--keychain-profile", "YTDP_NOTARY"): subprocess.CompletedProcess(
                    [], 0, "Successfully received submission history.\n", ""
                ),
            }
        )

        report = self.module.evaluate_repository(
            repository_root=self.root,
            expected_version="2.0.1",
            notary_profile="YTDP_NOTARY",
            command_runner=runner,
        )

        self.assertEqual(report["overallStatus"], "ready_for_signed_candidate")
        self.assertTrue(all(gate["status"] == "pass" for gate in report["gates"]))

    def test_source_distribution_requires_approval_reference(self):
        inventory = json.loads(
            (self.root / "tools" / "macos-source-archives.json").read_text(encoding="utf-8")
        )
        inventory["publicDistributionReady"] = True
        inventory["limitations"] = []
        (self.root / "tools" / "macos-source-archives.json").write_text(
            json.dumps(inventory),
            encoding="utf-8",
        )

        report = self.module.evaluate_repository(
            repository_root=self.root,
            expected_version="2.0.1",
            notary_profile="YTDP_NOTARY",
            command_runner=FakeRunner({}),
        )

        source_gate = next(gate for gate in report["gates"] if gate["id"] == "source_distribution")
        self.assertEqual(source_gate["status"], "blocked")
        self.assertIn("approval reference", source_gate["summary"].lower())

    def test_source_distribution_rejects_empty_component_inventory(self):
        inventory = json.loads(
            (self.root / "tools" / "macos-source-archives.json").read_text(encoding="utf-8")
        )
        inventory["publicDistributionReady"] = True
        inventory["limitations"] = []
        inventory["approvalReference"] = "restricted-evidence:license-review-2026-09-30"
        inventory["components"] = []
        (self.root / "tools" / "macos-source-archives.json").write_text(
            json.dumps(inventory),
            encoding="utf-8",
        )

        report = self.module.evaluate_repository(
            repository_root=self.root,
            expected_version="2.0.1",
            notary_profile="YTDP_NOTARY",
            command_runner=FakeRunner({}),
        )

        source_gate = next(gate for gate in report["gates"] if gate["id"] == "source_distribution")
        self.assertEqual(source_gate["status"], "blocked")
        self.assertIn("component", source_gate["summary"].lower())

    def test_developer_id_requires_positive_valid_identity_count(self):
        runner = FakeRunner(
            {
                ("security", "find-identity", "-v", "-p", "codesigning"): subprocess.CompletedProcess(
                    [], 0, '  1) ABC "Developer ID Application: Example (TEAMID1234)"\n     0 valid identities found\n', ""
                ),
            }
        )

        report = self.module.evaluate_repository(
            repository_root=self.root,
            expected_version="2.0.1",
            notary_profile="YTDP_NOTARY",
            command_runner=runner,
        )

        developer_id = next(gate for gate in report["gates"] if gate["id"] == "developer_id")
        self.assertEqual(developer_id["status"], "blocked")


if __name__ == "__main__":
    unittest.main()
