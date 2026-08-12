import base64
import json
import ssl
import tempfile
import unittest
from pathlib import Path

from ytdp.localization import clean_download_error
from ytdp.updater import (
    is_newer_version,
    make_update_ssl_context,
    parse_update_manifest,
    select_release_asset,
)


class UpdateHelpersTests(unittest.TestCase):
    def test_manifest_parses_plain_json_and_github_contents_versions(self):
        encoded = base64.b64encode(b"v1.8.9\n").decode()

        self.assertEqual(parse_update_manifest("v1.8.7\n"), "1.8.7")
        self.assertEqual(parse_update_manifest('{"latest_version": "1.8.8"}'), "1.8.8")
        self.assertEqual(
            parse_update_manifest(json.dumps({"content": encoded})),
            "1.8.9",
        )

    def test_version_comparison_keeps_numeric_release_semantics(self):
        self.assertTrue(is_newer_version("1.8.10", "1.8.7"))
        self.assertFalse(is_newer_version("1.8.7", "1.8.7"))
        self.assertFalse(is_newer_version("1.8.6", "1.8.7"))

    def test_update_context_keeps_hostname_and_certificate_verification(self):
        context = make_update_ssl_context()

        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)

    def test_update_asset_selection_rejects_macos_for_windows(self):
        asset = select_release_asset(
            ["app-macOS.zip", "app-Windows-x64.zip"],
            "windows",
        )

        self.assertEqual(asset, "app-Windows-x64.zip")

    def test_update_asset_selection_rejects_windows_for_macos(self):
        asset = select_release_asset(
            ["app-Windows-x64.zip", "app-macOS-arm64.zip"],
            "macos",
        )

        self.assertEqual(asset, "app-macOS-arm64.zip")

    def test_update_asset_selection_accepts_darwin_for_macos(self):
        asset = select_release_asset(["app-darwin-arm64.zip"], "macos")

        self.assertEqual(asset, "app-darwin-arm64.zip")


class DownloadErrorLocalizationTests(unittest.TestCase):
    def test_localizes_bot_helper_and_path_errors_for_supported_languages(self):
        cases = (
            ("Sign in to confirm you are not a bot", "zh", "登入驗證"),
            ("ffmpeg is not installed", "en", "bundled converter"),
            ("No space left on device", "ja", "空き容量"),
            ("The filename or extension is too long", "en", "path is too long"),
        )

        for error, language, expected in cases:
            with self.subTest(error=error, language=language):
                self.assertIn(expected, clean_download_error(Exception(error), language))

    def test_localizes_network_tls_content_permission_and_antivirus_errors(self):
        cases = (
            ("CERTIFICATE_VERIFY_FAILED", "certificate"),
            ("connection refused", "network"),
            ("Video unavailable", "unavailable"),
            (PermissionError("denied"), "cannot be written"),
            ("Operation did not complete successfully because the file contains a virus", "antivirus"),
        )

        for error, expected in cases:
            with self.subTest(error=str(error)):
                self.assertIn(expected, clean_download_error(error, "en").lower())

    def test_unknown_raw_error_is_written_only_to_diagnostic_log(self):
        with tempfile.TemporaryDirectory() as directory:
            log_path = Path(directory) / "logs" / "download.log"
            message = clean_download_error(
                Exception("private backend detail"),
                "en",
                log_path,
            )

            self.assertNotIn("private backend detail", message)
            self.assertIn("download failed", message.lower())
            self.assertIn("private backend detail", log_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
