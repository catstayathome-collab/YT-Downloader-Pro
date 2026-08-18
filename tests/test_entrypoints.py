import builtins
import importlib
import importlib.util
import io
import json
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
        self.app.toolchain_error = None

    def _run_update_check(self, responses, *, silent):
        class FakeResponse:
            def __init__(self, payload):
                self.payload = payload

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return self.payload.encode("utf-8")

        class ImmediateThread:
            def __init__(self, target, daemon):
                self.target = target

            def start(self):
                self.target()

        def fake_urlopen(request, *, timeout, context):
            self.assertEqual(timeout, 5)
            self.assertIsNotNone(context)
            return FakeResponse(responses[request.full_url])

        self.app.post_to_ui = mock.Mock()
        with mock.patch.object(self.shared.threading, "Thread", ImmediateThread):
            with mock.patch.object(self.shared.urllib.request, "urlopen", side_effect=fake_urlopen):
                self.app.check_update(silent=silent)


    def test_windows_entrypoint_declares_version_1_8_7(self):
        module = importlib.import_module("YT_downloader_187_windows")

        self.assertEqual(module.VERSION, "1.8.7")
        self.assertIs(module.YTDownloaderApp, self.shared.YTDownloaderApp)

    def test_windows_launcher_bootstrap_does_not_import_ui_dependencies(self):
        source = ROOT / "YT_downloader_187_windows.py"
        spec = importlib.util.spec_from_file_location("isolated_windows_launcher", source)
        module = importlib.util.module_from_spec(spec)
        original_import = builtins.__import__

        def guarded_import(name, *args, **kwargs):
            if name == "ytdp.app" or name.split(".", 1)[0] in {
                "tkinter", "yt_dlp", "certifi"
            }:
                raise AssertionError(f"eager UI dependency import: {name}")
            return original_import(name, *args, **kwargs)

        with mock.patch("builtins.__import__", side_effect=guarded_import):
            spec.loader.exec_module(module)

        self.assertEqual(module.VERSION, "1.8.7")

    def test_macos_entrypoint_reexports_shared_application(self):
        module = importlib.import_module("YT_downloader_187")

        self.assertEqual(module.VERSION, "1.8.7")
        self.assertIs(module.YTDownloaderApp, self.shared.YTDownloaderApp)

    def test_windows_normal_launch_rejects_non_windows_hosts(self):
        module = importlib.import_module("YT_downloader_187_windows")

        with mock.patch.object(module.sys, "platform", "darwin"):
            with self.assertRaisesRegex(RuntimeError, "Windows"):
                module.main([])

    def test_windows_normal_launch_returns_zero_after_ui_closes(self):
        module = importlib.import_module("YT_downloader_187_windows")
        closed_app = object()
        run = mock.Mock(return_value=closed_app)

        with mock.patch.object(module.sys, "platform", "win32"):
            with mock.patch.object(
                module,
                "_load_ui",
                return_value=(self.shared.YTDownloaderApp, run),
                create=True,
            ):
                with mock.patch.object(module, "run_app", run):
                    self.assertEqual(module.main([]), 0)

        run.assert_called_once()

    def test_windows_self_test_passes_optional_report_path_without_opening_ui(self):
        module = importlib.import_module("YT_downloader_187_windows")
        report_path = "/tmp/windows-self-test.json"

        with mock.patch.object(module.sys, "platform", "darwin"):
            with mock.patch("ytdp.selftest.run_self_test", return_value=0) as run:
                with mock.patch.object(module, "_load_ui", create=True) as load_ui:
                    self.assertEqual(
                        module.main(["--self-test", "--self-test-report", report_path]),
                        0,
                    )

        run.assert_called_once_with(mock.ANY, report_path)
        load_ui.assert_not_called()

    def test_invalid_selftest_argument_combinations_fail_without_opening_ui(self):
        module = importlib.import_module("YT_downloader_187_windows")
        cases = (
            (["--self-test-report", "report.json"], "requires --self-test"),
            (["--self-test-report"], "expected one argument"),
            (["--self-test", "--unknown"], "unrecognized arguments"),
        )

        for args, expected in cases:
            with self.subTest(args=args):
                stderr = io.StringIO()
                with mock.patch.object(module.sys, "platform", "win32"):
                    with mock.patch.object(module.sys, "stderr", stderr):
                        with mock.patch.object(module, "_load_ui", create=True) as load_ui:
                            with self.assertRaises(SystemExit) as raised:
                                module.main(args)
                self.assertNotEqual(raised.exception.code, 0)
                self.assertIn(expected, stderr.getvalue())
                load_ui.assert_not_called()

    def test_windows_update_uses_the_matching_release_asset_and_opens_its_url(self):
        manifest_url = "https://api.example/version.txt"
        release_url = "https://api.github.com/repos/catstayathome-collab/YT-Downloader-Pro/releases/latest"
        download_url = "https://downloads.example/YT-Downloader-Pro-v1.8.8-Windows-x64.zip"
        responses = {
            manifest_url: "1.8.8\n",
            release_url: json.dumps(
                {
                    "assets": [
                        {"name": "app-macOS-arm64.zip", "browser_download_url": "https://downloads.example/macos.zip"},
                        {"name": "app-Windows-x64.zip", "browser_download_url": download_url},
                    ]
                }
            ),
        }

        with mock.patch.object(self.shared, "PUBLIC_UPDATE_MANIFEST_URL", manifest_url):
            self._run_update_check(responses, silent=False)

        self.app.post_to_ui.assert_called_once_with(
            self.app.show_update_dialog,
            "1.8.8",
            download_url,
        )
        with mock.patch.object(self.shared.messagebox, "askyesno", return_value=True):
            with mock.patch.object(self.shared.webbrowser, "open") as open_url:
                self.app.show_update_dialog("1.8.8", download_url)
        open_url.assert_called_once_with(download_url)

    def test_windows_update_without_a_safe_matching_asset_uses_release_page(self):
        manifest_url = "https://api.example/version.txt"
        release_url = "https://api.github.com/repos/catstayathome-collab/YT-Downloader-Pro/releases/latest"
        release = json.dumps(
            {
                "assets": [
                    {"name": "app-macOS-arm64.zip", "browser_download_url": "https://downloads.example/macos.zip"},
                    {"name": "app-Windows-x86.zip", "browser_download_url": "https://downloads.example/x86.zip"},
                    {"name": "app-Windows-arm64.zip", "browser_download_url": "https://downloads.example/arm64.zip"},
                    {"name": "app-Windows-x64.zip", "browser_download_url": "http://downloads.example/windows.zip"},
                ]
            }
        )

        with mock.patch.object(self.shared, "PUBLIC_UPDATE_MANIFEST_URL", manifest_url):
            self._run_update_check({manifest_url: "1.8.8\n", release_url: release}, silent=False)

        self.app.post_to_ui.assert_called_once_with(
            self.app.show_update_dialog,
            "1.8.8",
            self.shared.DEFAULT_UPDATE_DOWNLOAD_URL,
        )

    def test_startup_toolchain_validation_runs_in_background(self):
        captured = []
        self.app.toolchain = mock.Mock()
        self.app.toolchain.validate.return_value = object()
        self.app.apply_toolchain_validation = mock.Mock()
        self.app.post_to_ui = mock.Mock()

        class FakeThread:
            def __init__(self, target, daemon):
                captured.append((target, daemon))

            def start(self):
                return None

        with mock.patch.object(self.shared.threading, "Thread", FakeThread):
            self.app.check_toolchain_on_startup()

        self.app.toolchain.validate.assert_not_called()
        self.assertTrue(captured[0][1])
        captured[0][0]()
        self.app.post_to_ui.assert_called_once_with(
            self.app.apply_toolchain_validation,
            self.app.toolchain.validate.return_value,
            None,
        )

    def test_unexpected_startup_validation_failure_is_returned_to_ui(self):
        captured = []
        self.app.toolchain = mock.Mock()
        self.app.toolchain.validate.side_effect = OSError("helper directory blocked")
        self.app.apply_toolchain_validation = mock.Mock()
        self.app.post_to_ui = mock.Mock()

        class FakeThread:
            def __init__(self, target, daemon):
                captured.append(target)

            def start(self):
                return None

        with mock.patch.object(self.shared.threading, "Thread", FakeThread):
            self.app.check_toolchain_on_startup()

        captured[0]()
        callback, report, error = self.app.post_to_ui.call_args.args
        self.assertIs(callback, self.app.apply_toolchain_validation)
        self.assertIsNone(report)
        self.assertIsInstance(error, OSError)

    def test_failed_toolchain_validation_disables_actions_and_shows_log_location(self):
        self.app.diagnostic_logger = mock.Mock()
        self.app.diagnostic_logger.path = Path("C:/logs/diagnostics.jsonl")
        self.app.diagnostic_logger.log.return_value = self.app.diagnostic_logger.path

        with mock.patch.object(self.shared.messagebox, "showerror") as showerror:
            self.app.apply_toolchain_validation(None, self.shared.ToolchainError("deno token=secret"))

        self.assertEqual(self.app.btn_analyze.values["state"], "disabled")
        self.assertEqual(self.app.btn_download.values["state"], "disabled")
        self.assertNotIn("secret", showerror.call_args.args[1])
        self.assertIn("diagnostics.jsonl", showerror.call_args.args[1])

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

    def test_editing_pending_url_restores_analyze_button(self):
        self.app.btn_analyze.config(
            state="disabled", text=self.app.text["analyzing"]
        )
        self.app.url_entry.value = "https://youtu.be/changed"

        self.app.handle_url_change()

        self.assertEqual(self.app.analysis_request_id, 2)
        self.assertEqual(self.app.btn_analyze.values["state"], "normal")
        self.assertEqual(
            self.app.btn_analyze.values["text"], self.app.text["analyze"]
        )

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

    def test_start_download_initializes_flags_before_worker_starts(self):
        self.app.apply_analysis_result(
            1, URL, "Title", VIDEO_OPTIONS, AUDIO_OPTIONS
        )
        self.app.download_path = "/tmp/output"
        self.app.is_cancelled = True
        self.app.is_paused = True
        self.app.pause_event.clear()
        observed = []

        class FakeThread:
            def __init__(self, target, args, daemon):
                self.target = target
                self.args = args
                self.daemon = daemon

            def start(_self):
                observed.append((
                    self.app.is_cancelled,
                    self.app.is_paused,
                    self.app.pause_event.is_set(),
                ))

        with mock.patch.object(self.shared.threading, "Thread", FakeThread):
            self.app.start_download()

        self.assertEqual(observed, [(False, False, True)])

    def test_immediate_pause_and_cancel_survive_worker_entry(self):
        self.app.apply_analysis_result(
            1, URL, "Title", VIDEO_OPTIONS, AUDIO_OPTIONS
        )
        self.app.download_path = "/tmp/output"
        captured = []

        class FakeThread:
            def __init__(self, target, args, daemon):
                captured.append(args[0])

            def start(self):
                return None

        with mock.patch.object(self.shared.threading, "Thread", FakeThread):
            self.app.start_download()

        self.app.toggle_pause()
        self.app.cancel_download()
        observed = []
        self.app.post_to_ui = mock.Mock()

        def fail_tool_lookup():
            observed.append((
                self.app.is_cancelled,
                self.app.is_paused,
                self.app.pause_event.is_set(),
            ))
            raise self.shared.ToolchainError("missing helper")

        self.app.get_ffmpeg_path = fail_tool_lookup
        self.app.download_video(captured[0])

        self.assertEqual(observed, [(True, True, True)])


if __name__ == "__main__":
    unittest.main()
