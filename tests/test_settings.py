import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import YT_downloader_180 as app_module


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


if __name__ == "__main__":
    unittest.main()
