import importlib.util
import plistlib
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "prepare_macos_auth_signing.py"
BUNDLE_IDENTIFIER = "com.tachouweng.ytdownloaderpro2"
TEAM_ID = "TEAM123456"
APP_IDENTIFIER = f"{TEAM_ID}.{BUNDLE_IDENTIFIER}"


def load_helper():
    if not HELPER.is_file():
        raise AssertionError(f"required script is missing: {HELPER}")
    spec = importlib.util.spec_from_file_location("prepare_macos_auth_signing", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MacOSAuthenticationSigningTests(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.now = datetime(2026, 9, 18, tzinfo=timezone.utc)

    def profile(self, *, entitlements=None, expiration=None):
        return {
            "ApplicationIdentifierPrefix": [TEAM_ID],
            "TeamIdentifier": [TEAM_ID],
            "ExpirationDate": expiration or self.now + timedelta(days=30),
            "Entitlements": entitlements
            or {
                "com.apple.application-identifier": APP_IDENTIFIER,
                "com.apple.developer.team-identifier": TEAM_ID,
                "keychain-access-groups": [APP_IDENTIFIER],
            },
        }

    def test_builds_minimal_deterministic_entitlements_from_authorized_profile(self):
        entitlements = self.helper.build_auth_entitlements(
            self.profile(),
            team_id=TEAM_ID,
            bundle_identifier=BUNDLE_IDENTIFIER,
            now=self.now,
        )

        self.assertEqual(
            entitlements,
            {
                "com.apple.application-identifier": APP_IDENTIFIER,
                "com.apple.developer.team-identifier": TEAM_ID,
                "keychain-access-groups": [APP_IDENTIFIER],
            },
        )

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "auth.entitlements"
            self.helper.write_entitlements(output, entitlements)
            first = output.read_bytes()
            self.helper.write_entitlements(output, entitlements)
            self.assertEqual(output.read_bytes(), first)
            self.assertEqual(plistlib.loads(first), entitlements)

    def test_rejects_profile_with_wrong_team_or_application_identifier(self):
        wrong_team = self.profile()
        wrong_team["TeamIdentifier"] = ["WRONGTEAM1"]
        with self.assertRaisesRegex(self.helper.ProfileValidationError, "TeamIdentifier"):
            self.helper.build_auth_entitlements(
                wrong_team,
                team_id=TEAM_ID,
                bundle_identifier=BUNDLE_IDENTIFIER,
                now=self.now,
            )

        wrong_app = self.profile()
        wrong_app["Entitlements"]["com.apple.application-identifier"] = (
            f"{TEAM_ID}.com.example.wrong"
        )
        with self.assertRaisesRegex(
            self.helper.ProfileValidationError,
            "application identifier",
        ):
            self.helper.build_auth_entitlements(
                wrong_app,
                team_id=TEAM_ID,
                bundle_identifier=BUNDLE_IDENTIFIER,
                now=self.now,
            )

    def test_rejects_missing_keychain_group_and_expired_profile(self):
        missing_group = self.profile()
        missing_group["Entitlements"]["keychain-access-groups"] = []
        with self.assertRaisesRegex(self.helper.ProfileValidationError, "keychain access group"):
            self.helper.build_auth_entitlements(
                missing_group,
                team_id=TEAM_ID,
                bundle_identifier=BUNDLE_IDENTIFIER,
                now=self.now,
            )

    def test_accepts_team_scoped_profile_wildcards_but_emits_exact_entitlements(self):
        wildcard_profile = self.profile()
        wildcard_profile["Entitlements"]["com.apple.application-identifier"] = (
            f"{TEAM_ID}.*"
        )
        wildcard_profile["Entitlements"]["keychain-access-groups"] = [
            f"{TEAM_ID}.*"
        ]

        entitlements = self.helper.build_auth_entitlements(
            wildcard_profile,
            team_id=TEAM_ID,
            bundle_identifier=BUNDLE_IDENTIFIER,
            now=self.now,
        )

        self.assertEqual(
            entitlements["com.apple.application-identifier"],
            APP_IDENTIFIER,
        )
        self.assertEqual(
            entitlements["keychain-access-groups"],
            [APP_IDENTIFIER],
        )

    def test_rejects_wildcards_outside_the_requested_team_prefix(self):
        wrong_wildcard = self.profile()
        wrong_wildcard["Entitlements"]["keychain-access-groups"] = [
            "WRONGTEAM1.*"
        ]

        with self.assertRaisesRegex(
            self.helper.ProfileValidationError,
            "keychain access group",
        ):
            self.helper.build_auth_entitlements(
                wrong_wildcard,
                team_id=TEAM_ID,
                bundle_identifier=BUNDLE_IDENTIFIER,
                now=self.now,
            )

        with self.assertRaisesRegex(self.helper.ProfileValidationError, "expired"):
            self.helper.build_auth_entitlements(
                self.profile(expiration=self.now - timedelta(seconds=1)),
                team_id=TEAM_ID,
                bundle_identifier=BUNDLE_IDENTIFIER,
                now=self.now,
            )


if __name__ == "__main__":
    unittest.main()
