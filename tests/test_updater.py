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
    parse_platform_update_manifest,
    parse_release_asset_url,
    parse_update_manifest,
    select_release_asset,
)


class UpdateHelpersTests(unittest.TestCase):
    def test_contents_api_windows_manifest_selects_only_x64_asset(self):
        manifest = self.windows_manifest(
            assets=[
                self.manifest_asset("arm64", "https://downloads.example/windows-arm64.zip"),
                self.manifest_asset("x64", "https://downloads.example/windows-x64.zip"),
            ]
        )
        encoded = base64.b64encode(json.dumps(manifest).encode()).decode()

        selected = parse_platform_update_manifest(
            json.dumps({"encoding": "base64", "content": encoded}),
            "windows",
            architecture="x64",
        )

        self.assertIsNotNone(selected)
        self.assertEqual(selected.latest_version, "1.8.9")
        self.assertEqual(
            selected.download_url,
            "https://downloads.example/windows-x64.zip",
        )
        self.assertFalse(selected.is_legacy)

    def test_windows_client_rejects_macos_platform_manifest(self):
        manifest = self.windows_manifest()
        manifest["platform"] = "macos"

        self.assertIsNone(
            parse_platform_update_manifest(json.dumps(manifest), "windows")
        )

    def test_windows_manifest_without_exact_x64_asset_is_rejected(self):
        manifest = self.windows_manifest(
            assets=[
                self.manifest_asset("arm64", "https://downloads.example/windows-arm64.zip"),
                self.manifest_asset("x86", "https://downloads.example/windows-x86.zip"),
            ]
        )

        self.assertIsNone(
            parse_platform_update_manifest(
                json.dumps(manifest), "windows", architecture="x64"
            )
        )

    def test_legacy_version_txt_remains_a_compatible_version_source(self):
        selected = parse_platform_update_manifest("v1.8.9\n", "windows")

        self.assertIsNotNone(selected)
        self.assertEqual(selected.latest_version, "1.8.9")
        self.assertIsNone(selected.download_url)
        self.assertTrue(selected.is_legacy)

    def test_windows_manifest_rejects_unsafe_urls_and_checksums(self):
        cases = []
        unsafe_release = self.windows_manifest()
        unsafe_release["release_url"] = "http://downloads.example/releases"
        cases.append(unsafe_release)
        unsafe_asset = self.windows_manifest()
        unsafe_asset["assets"][0]["download_url"] = "http://downloads.example/windows.zip"
        cases.append(unsafe_asset)
        uppercase_checksum = self.windows_manifest()
        uppercase_checksum["assets"][0]["sha256"] = "A" * 64
        cases.append(uppercase_checksum)

        for manifest in cases:
            with self.subTest(manifest=manifest):
                self.assertIsNone(
                    parse_platform_update_manifest(json.dumps(manifest), "windows")
                )

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

    def test_structured_manifest_uses_semver_precedence(self):
        cases = (
            ("1.8.9-rc.1", "1.8.9", False),
            ("1.8.9+build.2", "1.8.9+build.1", False),
            ("1.8.10-alpha.1", "1.8.9", True),
            ("1.8.9-rc.2", "1.8.9-rc.1", True),
        )

        for latest, current, expected in cases:
            with self.subTest(latest=latest, current=current):
                selected = parse_platform_update_manifest(
                    json.dumps(self.windows_manifest(latest_version=latest)),
                    "windows",
                )
                self.assertIsNotNone(selected)
                self.assertEqual(selected.is_newer_than(current), expected)

    def test_structured_manifest_compares_5000_digit_core_without_integer_conversion(self):
        huge_major = "9" * 5_001
        selected = parse_platform_update_manifest(
            json.dumps(self.windows_manifest(latest_version=f"{huge_major}.0.0")),
            "windows",
        )

        self.assertIsNotNone(selected)
        self.assertTrue(selected.is_newer_than("2.0.0"))
        self.assertFalse(
            selected.is_newer_than(f"{huge_major}.0.0+different-build")
        )

    def test_structured_manifest_compares_5000_digit_numeric_prerelease(self):
        huge_identifier = "9" * 5_001
        selected = parse_platform_update_manifest(
            json.dumps(
                self.windows_manifest(
                    latest_version=f"1.0.0-{huge_identifier}"
                )
            ),
            "windows",
        )

        self.assertIsNotNone(selected)
        self.assertTrue(selected.is_newer_than("1.0.0-2"))
        self.assertFalse(selected.is_newer_than("1.0.0"))

    def test_structured_manifest_rejects_long_leading_zero_prerelease(self):
        malformed_versions = (
            "1.0.0-00",
            f"1.0.0-0{'1' * 5_000}",
            f"1.0.0-alpha.0{'1' * 5_000}",
        )

        for version in malformed_versions:
            with self.subTest(version_length=len(version)):
                self.assertIsNone(
                    parse_platform_update_manifest(
                        json.dumps(self.windows_manifest(latest_version=version)),
                        "windows",
                    )
                )

    def test_legacy_sources_keep_numeric_comparison_semantics(self):
        selected = parse_platform_update_manifest("v1.8.9-rc.1\n", "windows")

        self.assertIsNotNone(selected)
        self.assertTrue(selected.is_legacy)
        self.assertTrue(selected.is_newer_than("1.8.9"))

    def test_structured_manifest_rejects_unicode_digits_in_semver(self):
        for version in ("1\u0661.0.0", "1.0.0-rc.\u0661"):
            with self.subTest(version=version):
                self.assertIsNone(
                    parse_platform_update_manifest(
                        json.dumps(self.windows_manifest(latest_version=version)),
                        "windows",
                    )
                )

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

    @staticmethod
    def manifest_asset(architecture, download_url):
        return {
            "platform": "windows",
            "architecture": architecture,
            "name": f"YT-Downloader-Pro-Windows-{architecture}.zip",
            "download_url": download_url,
            "sha256": "0" * 64,
        }

    def windows_manifest(self, assets=None, latest_version="1.8.9"):
        return {
            "schema_version": 1,
            "platform": "windows",
            "latest_version": latest_version,
            "release_url": "https://example.invalid/releases/windows-example",
            "published_at": "2026-08-18T00:00:00Z",
            "release_notes": "Example manifest only; not a release.",
            "assets": assets
            if assets is not None
            else [
                self.manifest_asset(
                    "x64", "https://downloads.example/windows-x64.zip"
                )
            ],
        }


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
