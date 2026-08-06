import json
import os
import sys
import tempfile
import unittest
import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import YT_downloader_186 as app_module


class SettingsPersistenceTests(unittest.TestCase):
    def test_saved_download_path_is_reused_when_directory_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            download_dir = Path(tmpdir) / "downloads"
            download_dir.mkdir()
            settings_path = Path(tmpdir) / "settings.json"
            settings_path.write_text(json.dumps({"download_path": str(download_dir)}), encoding="utf-8")

            app = object.__new__(app_module.YTDownloaderApp)
            app.settings_path = str(settings_path)
            app.settings = app.load_settings()

            self.assertEqual(app.get_saved_download_path(), str(download_dir))

    def test_missing_saved_download_path_falls_back_to_downloads(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            settings_path = Path(tmpdir) / "settings.json"
            settings_path.write_text(json.dumps({"download_path": str(Path(tmpdir) / "missing")}), encoding="utf-8")

            app = object.__new__(app_module.YTDownloaderApp)
            app.settings_path = str(settings_path)
            app.settings = app.load_settings()

            self.assertEqual(app.get_saved_download_path(), app_module.DEFAULT_DOWNLOAD_PATH)


class FormatSelectionTests(unittest.TestCase):
    def test_hls_progressive_video_is_not_used_for_merge_menu(self):
        app = object.__new__(app_module.YTDownloaderApp)
        hls_progressive = {
            "format_id": "96",
            "height": 1080,
            "ext": "mp4",
            "protocol": "m3u8_native",
            "vcodec": "avc1.640028",
            "acodec": "mp4a.40.2",
        }

        self.assertFalse(app.is_video_merge_format(hls_progressive))

    def test_https_video_only_format_is_used_for_merge_menu(self):
        app = object.__new__(app_module.YTDownloaderApp)
        video_only = {
            "format_id": "137",
            "height": 1080,
            "ext": "mp4",
            "protocol": "https",
            "vcodec": "avc1.640028",
            "acodec": "none",
            "format_note": "1080p",
        }

        self.assertTrue(app.is_video_merge_format(video_only))
        self.assertEqual(app.make_video_option(video_only)["id"], "137")

    def test_requested_format_error_is_translated(self):
        app = object.__new__(app_module.YTDownloaderApp)
        app.text = app_module.LANG_DATA["zh"]

        message = app.clean_download_error(Exception("ERROR: Requested format is not available"))

        self.assertIn("格式已變動", message)


class UpdateManifestTests(unittest.TestCase):
    def test_plain_text_manifest_version_is_parsed(self):
        app = object.__new__(app_module.YTDownloaderApp)

        self.assertEqual(app.parse_update_manifest("v1.8.7\n"), "1.8.7")

    def test_json_manifest_version_is_parsed(self):
        app = object.__new__(app_module.YTDownloaderApp)

        self.assertEqual(app.parse_update_manifest('{"latest_version": "1.8.8"}'), "1.8.8")

    def test_github_contents_manifest_version_is_parsed(self):
        app = object.__new__(app_module.YTDownloaderApp)
        encoded = base64.b64encode(b"1.8.9\n").decode()

        self.assertEqual(app.parse_update_manifest(json.dumps({"content": encoded})), "1.8.9")


if __name__ == "__main__":
    unittest.main()
