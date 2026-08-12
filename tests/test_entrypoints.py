import importlib
import io
import queue
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


URL = "https://youtu.be/example"
VIDEO_OPTIONS = [{"id": "137", "label": "1080p - mp4", "priority": 1}]
AUDIO_OPTIONS = [{"id": "140", "label": "Audio: original (medium) - m4a", "priority": 1}]


class FakeWidget:
    def __init__(self, value=""):
        self.value = value
        self.values = {}
        self.selected_index = -1
        self.bindings = {}

    def __getitem__(self, key):
        return self.values[key]

    def __setitem__(self, key, value):
        self.values[key] = value

    def bind(self, event, callback):
        self.bindings[event] = callback

    def config(self, **kwargs):
        self.values.update(kwargs)

    def current(self, index=None):
        if index is not None:
            self.selected_index = index
        return self.selected_index

    def delete(self, _start, _end):
        self.value = ""

    def get(self):
        return self.value

    def insert(self, _index, value):
        self.value = value

    def set(self, value):
        self.value = value


class FakeBool:
    def __init__(self, value=False):
        self.value = value

    def get(self):
        return self.value


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.shared = importlib.import_module("ytdp.app")
        self.app = object.__new__(self.shared.YTDownloaderApp)
        self.app.text = self.shared.LANG_DATA["en"]
        self.app.platform = mock.Mock()
        self.app.platform.filename_platform.return_value = "windows"
        self.app.analysis_request_id = 1
        self.app.analyzed_url = ""
        self.app.pending_analysis_url = URL
        self.app.current_video_title = ""
        self.app.video_format_list = []
        self.app.audio_format_list = []
        self.app.url_entry = FakeWidget(URL)
        self.app.combo_quality = FakeWidget()
        self.app.combo_audio = FakeWidget()
        self.app.lbl_video_title = FakeWidget()
        self.app.btn_analyze = FakeWidget()
        self.app.btn_download = FakeWidget()
        self.app.btn_pause = FakeWidget()
        self.app.btn_cancel = FakeWidget()
        self.app.audio_only_var = FakeBool()
        self.app.pause_event = threading.Event()
        self.app.pause_event.set()
        self.app.is_paused = False
        self.app.is_cancelled = False
        self.app.download_phase = "idle"

    def test_windows_entrypoint_declares_version_1_8_7(self):
        module = importlib.import_module("YT_downloader_187_windows")

        self.assertEqual(module.VERSION, "1.8.7")
        self.assertIs(module.YTDownloaderApp, self.shared.YTDownloaderApp)

    def test_macos_entrypoint_reexports_shared_application(self):
        module = importlib.import_module("YT_downloader_187")

        self.assertEqual(module.VERSION, "1.8.7")
        self.assertIs(module.YTDownloaderApp, self.shared.YTDownloaderApp)

    def test_windows_normal_launch_rejects_non_windows_hosts(self):
        module = importlib.import_module("YT_downloader_187_windows")

        with mock.patch.object(module.sys, "platform", "darwin"):
            with self.assertRaisesRegex(RuntimeError, "Windows"):
                module.main([])

    def test_windows_self_test_has_clear_task_five_boundary(self):
        module = importlib.import_module("YT_downloader_187_windows")
        stderr = io.StringIO()

        with mock.patch.object(module.sys, "platform", "darwin"):
            with mock.patch.object(module.sys, "stderr", stderr):
                self.assertEqual(module.main(["--self-test"]), 2)

        self.assertIn("Task 5", stderr.getvalue())

    def test_enter_starts_analysis_and_default_format_is_first(self):
        self.app.apply_analysis_result(
            1, URL, "Title", VIDEO_OPTIONS, AUDIO_OPTIONS
        )

        self.assertEqual(self.app.combo_quality.current(), 0)
        self.assertEqual(self.app.combo_audio.current(), 0)

        captured = []

        class FakeThread:
            def __init__(self, target, args, daemon):
                captured.append((target, args, daemon))

            def start(self):
                return None

        with mock.patch.object(self.shared.threading, "Thread", FakeThread):
            self.app.start_analyze()

        self.assertEqual(captured[0][1][1], URL)
        self.assertTrue(captured[0][2])

    def test_stale_analysis_result_does_not_replace_current_selection(self):
        self.app.apply_analysis_result(
            0, "https://youtu.be/stale", "Stale", [], []
        )

        self.assertEqual(self.app.analyzed_url, "")
        self.assertEqual(self.app.video_format_list, [])
        self.assertEqual(self.app.combo_quality.current(), -1)

    def test_pause_resume_and_cancel_follow_download_phase(self):
        self.app.set_download_phase("downloading")
        self.app.toggle_pause()

        self.assertEqual(self.app.download_phase, "paused")
        self.assertTrue(self.app.is_paused)
        self.assertFalse(self.app.pause_event.is_set())
        self.assertEqual(self.app.btn_cancel.values["state"], "normal")

        self.app.toggle_pause()
        self.app.cancel_download()

        self.assertEqual(self.app.download_phase, "downloading")
        self.assertFalse(self.app.is_paused)
        self.assertTrue(self.app.pause_event.is_set())
        self.assertTrue(self.app.is_cancelled)

    def test_change_path_persists_output_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            self.app.download_path = ""
            self.app.settings = {}
            self.app.lbl_path = FakeWidget()
            self.app.save_settings = mock.Mock()

            with mock.patch.object(self.shared.filedialog, "askdirectory", return_value=directory):
                self.app.change_path()

            self.assertEqual(self.app.download_path, directory)
            self.assertEqual(self.app.settings["download_path"], directory)
            self.app.save_settings.assert_called_once_with()

    def test_download_captures_immutable_request_before_worker_starts(self):
        self.app.apply_analysis_result(
            1, URL, "Title", VIDEO_OPTIONS, AUDIO_OPTIONS
        )
        self.app.download_path = "/tmp/output"
        captured = []

        class FakeThread:
            def __init__(self, target, args, daemon):
                captured.append((target, args[0], daemon))

            def start(self):
                return None

        with mock.patch.object(self.shared.threading, "Thread", FakeThread):
            self.app.start_download()

        request = captured[0][1]
        self.app.url_entry.value = "https://youtu.be/changed"
        self.app.current_video_title = "Changed"

        self.assertEqual(request.url, URL)
        self.assertEqual(request.title, "Title")
        with self.assertRaises(AttributeError):
            request.title = "mutated"


if __name__ == "__main__":
    unittest.main()
