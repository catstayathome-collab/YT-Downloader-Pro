import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "check_supabase_configuration.py"
FIXTURE = (
    ROOT
    / "swift-2.0"
    / "Tests"
    / "YTDownloaderPro2Tests"
    / "Fixtures"
    / "supabase-staging-configuration.json"
)


class SupabaseConfigurationCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.valid = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def tearDown(self):
        self.temporary_directory.cleanup()

    def run_checker(self, payload=None, *, path=None):
        target = path or self.root / "SupabaseConfiguration.json"
        if path is None:
            target.write_text(json.dumps(payload or self.valid), encoding="utf-8")
        return subprocess.run(
            ["python3", str(CHECKER), str(target)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_accepts_publishable_staging_material_only(self):
        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("valid", result.stdout.lower())
        self.assertNotIn(self.valid["publishableKey"], result.stdout)

    def test_rejects_forbidden_secret_fields_and_values_without_echoing_them(self):
        cases = {
            "serviceRoleKey": "service-role-secret-marker",
            "privateKey": "-----BEGIN PRIVATE KEY-----secret-marker",
            "googleClientSecret": "GOCSPX-secret-marker",
            "hashKey": "hash-key-secret-marker",
            "hashIV": "hash-iv-secret-marker",
            "publishableKey": "sb_secret_forbidden-secret-marker",
        }
        for field, value in cases.items():
            with self.subTest(field=field):
                payload = dict(self.valid)
                payload[field] = value
                result = self.run_checker(payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(value, result.stdout + result.stderr)

    def test_rejects_malformed_json_unapproved_hosts_and_invalid_public_keys(self):
        malformed = self.root / "malformed.json"
        malformed.write_text("{not-json", encoding="utf-8")
        self.assertNotEqual(self.run_checker(path=malformed).returncode, 0)

        for field, value in (
            ("projectURL", "https://attacker.example"),
            ("entitlementURL", "https://other.example/functions/v1/entitlement"),
            ("redirectURL", "https://staging-ref.supabase.co/callback"),
            ("publicKeys", {"bad key": "AQID"}),
        ):
            with self.subTest(field=field):
                payload = dict(self.valid)
                payload[field] = value
                self.assertNotEqual(self.run_checker(payload).returncode, 0)

    def test_rejects_symlink_and_world_writable_configuration(self):
        target = self.root / "target.json"
        target.write_text(json.dumps(self.valid), encoding="utf-8")
        symlink = self.root / "linked.json"
        symlink.symlink_to(target)
        self.assertNotEqual(self.run_checker(path=symlink).returncode, 0)

        target.chmod(0o666)
        try:
            self.assertNotEqual(self.run_checker(path=target).returncode, 0)
        finally:
            target.chmod(0o600)


if __name__ == "__main__":
    unittest.main()
