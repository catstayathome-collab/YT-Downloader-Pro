import json
import os
import sys
import tempfile
import unittest
import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import YT_downloader_187 as app_module


class ReleaseMetadataTests(unittest.TestCase):
    def test_release_version_is_1_8_7(self):
        self.assertEqual(app_module.VERSION, "1.8.7")

    def test_update_page_uses_github_releases(self):
        self.assertEqual(
            app_module.DEFAULT_UPDATE_DOWNLOAD_URL,
            "https://github.com/catstayathome-collab/YT-Downloader-Pro/releases/latest",
        )


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


class ArtifactCleanupTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.other_tempdir = tempfile.TemporaryDirectory()
        self.tmpdir = self.tempdir.name
        self.otherdir = self.other_tempdir.name

    def tearDown(self):
        self.other_tempdir.cleanup()
        self.tempdir.cleanup()

    def test_cleanup_preserves_preexisting_same_title_files(self):
        existing = Path(self.tmpdir) / "Same Title.mp4"
        existing.write_text("keep", encoding="utf-8")
        tracker = app_module.DownloadArtifactTracker(self.tmpdir, "Same Title (1).mp4")
        partial = Path(self.tmpdir) / "Same Title (1).mp4.part"
        partial.write_text("partial", encoding="utf-8")
        tracker.track(str(partial))

        removed = tracker.cleanup()

        self.assertTrue(existing.exists())
        self.assertFalse(partial.exists())
        self.assertEqual(removed, [str(partial)])

    def test_cleanup_preserves_preexisting_tracked_path(self):
        partial = Path(self.tmpdir) / "Same Title.mp4.part"
        partial.write_text("old", encoding="utf-8")
        tracker = app_module.DownloadArtifactTracker(self.tmpdir, "Same Title.mp4")
        tracker.track(str(partial))

        tracker.cleanup()

        self.assertTrue(partial.exists())

    def test_cleanup_rejects_path_outside_output_directory(self):
        outside = Path(self.otherdir) / "outside.part"
        outside.write_text("keep", encoding="utf-8")
        tracker = app_module.DownloadArtifactTracker(self.tmpdir, "Same Title.mp4")
        tracker.track(str(outside))

        tracker.cleanup()

        self.assertTrue(outside.exists())

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks unavailable")
    def test_cleanup_preserves_symlink_resolving_outside_directory(self):
        outside = Path(self.otherdir) / "outside.part"
        outside.write_text("keep", encoding="utf-8")
        link = Path(self.tmpdir) / "linked.part"
        link.symlink_to(outside)
        tracker = app_module.DownloadArtifactTracker(self.tmpdir, "Same Title.mp4")
        tracker.track(str(link))

        tracker.cleanup()

        self.assertTrue(link.is_symlink())
        self.assertTrue(outside.exists())


class AnalysisStateTests(unittest.TestCase):
    def setUp(self):
        self.app = object.__new__(app_module.YTDownloaderApp)
        self.app.analyzed_url = "https://youtu.be/first"
        self.app.video_format_list = ["137"]
        self.app.audio_format_list = ["140"]

    def test_changed_url_invalidates_download_selection(self):
        self.assertFalse(
            self.app.download_selection_is_valid("https://youtu.be/second", False)
        )

    def test_video_download_requires_video_and_audio_formats(self):
        self.app.video_format_list = []

        self.assertFalse(
            self.app.download_selection_is_valid("https://youtu.be/first", False)
        )

    def test_audio_only_requires_an_audio_format(self):
        self.app.audio_format_list = []

        self.assertFalse(
            self.app.download_selection_is_valid("https://youtu.be/first", True)
        )

    def test_download_request_is_immutable(self):
        request = app_module.DownloadRequest(
            url="https://youtu.be/first",
            video_format_id="137",
            audio_format_id="140",
            audio_only=False,
            output_directory="/tmp",
            title="Title",
        )

        with self.assertRaises(AttributeError):
            request.url = "https://youtu.be/second"


class NetworkSafetyTests(unittest.TestCase):
    def setUp(self):
        self.app = object.__new__(app_module.YTDownloaderApp)
        self.app.text = app_module.LANG_DATA["zh"]
        self.app.browser_cookies = None

    def test_analysis_options_keep_certificate_checks_enabled(self):
        self.assertNotIn("nocheckcertificate", self.app.make_analysis_options())

    def test_download_options_keep_certificate_checks_enabled(self):
        request = app_module.DownloadRequest(
            url="https://youtu.be/first",
            video_format_id="137",
            audio_format_id="140",
            audio_only=False,
            output_directory="/tmp",
            title="Title",
        )

        options = self.app.make_download_options(request, "/tmp/helpers")

        self.assertNotIn("nocheckcertificate", options)

    def test_certificate_error_is_localized(self):
        message = self.app.clean_download_error(Exception("CERTIFICATE_VERIFY_FAILED"))

        self.assertIn("安全憑證", message)

    def test_permission_error_is_localized(self):
        message = self.app.clean_download_error(PermissionError("denied"))

        self.assertIn("權限", message)


class FakeButton:
    def __init__(self):
        self.values = {}

    def config(self, **kwargs):
        self.values.update(kwargs)


class DownloadPhaseTests(unittest.TestCase):
    def setUp(self):
        self.app = object.__new__(app_module.YTDownloaderApp)
        self.app.text = app_module.LANG_DATA["zh"]
        self.app.btn_pause = FakeButton()
        self.app.btn_cancel = FakeButton()

    def test_downloading_enables_pause_and_cancel(self):
        self.app.set_download_phase("downloading")

        self.assertEqual(self.app.btn_pause.values["state"], "normal")
        self.assertEqual(self.app.btn_cancel.values["state"], "normal")

    def test_merging_disables_pause_and_cancel(self):
        self.app.set_download_phase("merging")

        self.assertEqual(self.app.btn_pause.values["state"], "disabled")
        self.assertEqual(self.app.btn_cancel.values["state"], "disabled")

    def test_idle_disables_pause_and_cancel(self):
        self.app.set_download_phase("idle")

        self.assertEqual(self.app.btn_pause.values["state"], "disabled")
        self.assertEqual(self.app.btn_cancel.values["state"], "disabled")

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
