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
    parse_release_asset_url,
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

    def test_windows_asset_selection_requires_supported_64_bit_architecture(self):
        for asset in (
            "app-Windows-x64.zip",
            "app-Windows-amd64.zip",
            "app-win64.zip",
        ):
            with self.subTest(asset=asset):
                self.assertEqual(select_release_asset([asset], "windows"), asset)

    def test_windows_asset_selection_rejects_other_architectures_and_macos(self):
        for asset in (
            "app-Windows-x86.zip",
            "app-Windows-32-bit.zip",
            "app-Windows-arm.zip",
            "app-Windows-arm64.zip",
            "app-macOS-x64.zip",
        ):
            with self.subTest(asset=asset):
                self.assertIsNone(select_release_asset([asset], "windows"))

    def test_update_asset_selection_rejects_windows_for_macos(self):
        asset = select_release_asset(
            ["app-Windows-x64.zip", "app-macOS-arm64.zip"],
            "macos",
        )

        self.assertEqual(asset, "app-macOS-arm64.zip")

    def test_update_asset_selection_accepts_darwin_for_macos(self):
        asset = select_release_asset(["app-darwin-arm64.zip"], "macos")

        self.assertEqual(asset, "app-darwin-arm64.zip")

    def test_release_asset_parser_returns_only_the_matching_https_windows_url(self):
        content = json.dumps(
            {
                "assets": [
                    {
                        "name": "YT-Downloader-Pro-v1.8.8-macOS-arm64.zip",
                        "browser_download_url": "https://downloads.example/macos.zip",
                    },
                    {
                        "name": "YT-Downloader-Pro-v1.8.8-Windows-x64.zip",
                        "browser_download_url": "https://downloads.example/windows-x64.zip",
                    },
                ]
            }
        )

        self.assertEqual(
            parse_release_asset_url(content, "windows"),
            "https://downloads.example/windows-x64.zip",
        )

    def test_release_asset_parser_skips_unsafe_x64_before_safe_x64(self):
        content = json.dumps(
            {
                "assets": [
                    {
                        "name": "app-Windows-x64.zip",
                        "browser_download_url": "http://downloads.example/unsafe.zip",
                    },
                    {
                        "name": "app-Windows-amd64.zip",
                        "browser_download_url": "https://downloads.example/safe.zip",
                    },
                ]
            }
        )

        self.assertEqual(
            parse_release_asset_url(content, "windows"),
            "https://downloads.example/safe.zip",
        )

    def test_release_asset_parser_returns_none_when_all_matching_x64_urls_are_unsafe(self):
        content = json.dumps(
            {
                "assets": [
                    {"name": "app-Windows-x64.zip"},
                    {
                        "name": "app-Windows-amd64.zip",
                        "browser_download_url": "http://downloads.example/unsafe.zip",
                    },
                    {
                        "name": "app-win64.zip",
                        "browser_download_url": "https:///missing-host.zip",
                    },
                ]
            }
        )

        self.assertIsNone(parse_release_asset_url(content, "windows"))

    def test_release_asset_parser_rejects_missing_or_non_https_windows_assets(self):
        cases = (
            {"assets": [{"name": "app-macOS-arm64.zip", "browser_download_url": "https://downloads.example/macos.zip"}]},
            {"assets": [{"name": "app-Windows-x86.zip", "browser_download_url": "https://downloads.example/x86.zip"}]},
            {"assets": [{"name": "app-Windows-arm64.zip", "browser_download_url": "https://downloads.example/arm64.zip"}]},
            {"assets": [{"name": "app-Windows-x64.zip", "browser_download_url": "http://downloads.example/windows.zip"}]},
        )

        for release in cases:
            with self.subTest(release=release):
                self.assertIsNone(parse_release_asset_url(json.dumps(release), "windows"))


class DownloadErrorLocalizationTests(unittest.TestCase):
    def test_youtube_http_403_has_actionable_message_in_each_language(self):
        expected = {
            "zh": "拒絕了這次影片串流",
            "en": "rejected this video stream",
            "ja": "動画ストリームを拒否",
        }

        for language, phrase in expected.items():
            with self.subTest(language=language):
                message = clean_download_error(
                    Exception("unable to download video data: HTTP Error 403: Forbidden"),
                    language,
                )
                self.assertIn(phrase, message)
                self.assertNotIn("HTTP Error 403", message)

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

    def test_helper_recovery_guidance_is_platform_neutral(self):
        for language in ("zh", "en", "ja"):
            with self.subTest(language=language):
                message = clean_download_error(
                    Exception("ffmpeg helper execution failed"), language
                )
                self.assertNotIn("Mac", message)
                self.assertNotIn("Apple Silicon", message)

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

    def test_diagnostic_log_redacts_sensitive_credential_values(self):
        secrets = (
            "cookie-secret",
            "plural-cookie-secret",
            "authorization-secret",
            "bearer-secret",
            "token-secret",
            "password-secret",
        )
        error = Exception(
            "Cookie: session=cookie-secret; theme=private\n"
            "cookies=plural-cookie-secret\n"
            "Authorization: Basic authorization-secret\n"
            "Bearer bearer-secret\n"
            "token=token-secret\n"
            "password: password-secret"
        )
        with tempfile.TemporaryDirectory() as directory:
            log_path = Path(directory) / "logs" / "download.log"
            clean_download_error(error, "en", log_path)
            diagnostic = log_path.read_text(encoding="utf-8")

        self.assertIn("[REDACTED]", diagnostic)
        for secret in secrets:
            with self.subTest(secret=secret):
                self.assertNotIn(secret, diagnostic)

    def test_diagnostic_log_redacts_extended_key_variants_without_dropping_context(self):
        secrets = (
            "abc",
            "xyz",
            "hyphen-key",
            "sigvalue",
            "credential-value",
            "secret-value",
            "session-value",
            "hyphen-session",
            "bearer-value",
        )
        error = Exception(
            "HTTP 403 GET https://api.example.test/download?access_token=abc&mode=diagnostic\n"
            'api_key: "xyz"; api-key=hyphen-key\n'
            "signature=sigvalue; credential='credential-value'; SeCrEt: \"secret-value\"\n"
            "session_token='session-value'; session-token=hyphen-session\n"
            "upstream rejected Bearer bearer-value"
        )
        with tempfile.TemporaryDirectory() as directory:
            log_path = Path(directory) / "logs" / "download.log"
            clean_download_error(error, "en", log_path)
            diagnostic = log_path.read_text(encoding="utf-8")

        self.assertIn("HTTP 403", diagnostic)
        self.assertIn("mode=diagnostic", diagnostic)
        self.assertIn("[REDACTED]", diagnostic)
        for secret in secrets:
            with self.subTest(secret=secret):
                self.assertNotIn(secret, diagnostic)

    def test_diagnostic_log_redacts_sig_query_without_matching_word_interior(self):
        error = Exception(
            "HTTP 403 GET https://cdn.example.test/file?sig=query-secret&design=keep-value"
        )
        with tempfile.TemporaryDirectory() as directory:
            log_path = Path(directory) / "logs" / "download.log"
            clean_download_error(error, "en", log_path)
            diagnostic = log_path.read_text(encoding="utf-8")

        self.assertNotIn("query-secret", diagnostic)
        self.assertIn("sig=[REDACTED]", diagnostic)
        self.assertIn("design=keep-value", diagnostic)


if __name__ == "__main__":
    unittest.main()
