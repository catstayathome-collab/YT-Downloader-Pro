import builtins
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import ytdp.selftest as selftest
from ytdp.selftest import _run_ffmpeg_cycle, run_self_test
from ytdp.toolchain import ToolchainReport


def successful_report(root):
    helper_dir = Path(root) / "Helpers"
    return ToolchainReport(
        paths={
            "ffmpeg": str(helper_dir / "ffmpeg.exe"),
            "ffprobe": str(helper_dir / "ffprobe.exe"),
            "deno": str(helper_dir / "deno.exe"),
        },
        versions={"ffmpeg": "7.1", "ffprobe": "7.1", "deno": "2.8.1"},
        architectures={"ffmpeg": "AMD64", "ffprobe": "AMD64", "deno": "AMD64"},
        duplicate_counts={"ffmpeg.exe": 1, "ffprobe.exe": 1, "deno.exe": 1},
        lgpl_configuration={"compatible": True, "configuration": "--disable-gpl"},
    )


class FakeAdapter:
    frozen = True

    def __init__(self, root):
        self.frozen_dir = Path(root)

    def settings_dir(self):
        return self.frozen_dir / "settings"

    def log_dir(self):
        return self.frozen_dir / "logs"

    def subprocess_kwargs(self):
        return {"creationflags": 0x08000000}


class SelfTestTests(unittest.TestCase):
    def test_selftest_module_bootstrap_does_not_import_checked_third_parties(self):
        source = Path(selftest.__file__)
        spec = importlib.util.spec_from_file_location("isolated_ytdp_selftest", source)
        module = importlib.util.module_from_spec(spec)
        original_import = builtins.__import__

        def guarded_import(name, *args, **kwargs):
            if name.split(".", 1)[0] in {"certifi", "yt_dlp", "yt_dlp_ejs"}:
                raise AssertionError(f"eager third-party import: {name}")
            return original_import(name, *args, **kwargs)

        with mock.patch("builtins.__import__", side_effect=guarded_import):
            spec.loader.exec_module(module)

        self.assertTrue(callable(module.run_self_test))

    def test_selftest_writes_the_same_machine_readable_report_to_stdout_and_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            adapter = FakeAdapter(root)
            report_path = root / "self-test.json"
            stdout = io.StringIO()
            with mock.patch("ytdp.selftest.Toolchain.validate", return_value=successful_report(root)):
                with mock.patch("ytdp.selftest._run_ffmpeg_cycle", return_value={"streams": ["video", "audio"], "mp3_bytes": 42}):
                    with mock.patch("sys.stdout", stdout):
                        code = run_self_test(adapter, report_path)

            from_stdout = json.loads(stdout.getvalue())
            from_file = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(code, 0)
        self.assertEqual(from_stdout, from_file)
        self.assertEqual(from_file["status"], "ok")
        self.assertEqual(from_file["schema_version"], 1)
        self.assertEqual(
            [check["name"] for check in from_file["checks"]],
            ["imports", "certificate", "settings_writable", "logs_writable", "filename_rules", "toolchain", "ffmpeg_cycle"],
        )

    def test_selftest_returns_nonzero_and_sanitizes_failed_check(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            adapter = FakeAdapter(tmpdir)
            stdout = io.StringIO()
            with mock.patch("ytdp.selftest._check_imports", side_effect=RuntimeError("token=secret-value")):
                with mock.patch("ytdp.selftest.Toolchain.validate", return_value=successful_report(tmpdir)):
                    with mock.patch("ytdp.selftest._run_ffmpeg_cycle", return_value={}):
                        with mock.patch("sys.stdout", stdout):
                            code = run_self_test(adapter)

            report = json.loads(stdout.getvalue())

        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "failed")
        self.assertNotIn("secret-value", stdout.getvalue())
        self.assertIn("[REDACTED]", stdout.getvalue())

    def test_windowed_selftest_attaches_parent_console_and_emits_json(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            attached_stdout = io.StringIO()
            with mock.patch("ytdp.selftest.Toolchain.validate", return_value=successful_report(tmpdir)):
                with mock.patch("ytdp.selftest._run_ffmpeg_cycle", return_value={}):
                    with mock.patch("sys.stdout", None):
                        with mock.patch(
                            "ytdp.selftest._attach_parent_stdout",
                            return_value=attached_stdout,
                            create=True,
                        ) as attach:
                            code = run_self_test(FakeAdapter(tmpdir))

        attach.assert_called_once_with()
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(attached_stdout.getvalue())["status"], "ok")

    def test_windowed_selftest_without_stdout_or_report_cannot_succeed(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            with mock.patch("ytdp.selftest.Toolchain.validate", return_value=successful_report(tmpdir)):
                with mock.patch("ytdp.selftest._run_ffmpeg_cycle", return_value={}):
                    with mock.patch("sys.stdout", None):
                        with mock.patch(
                            "ytdp.selftest._attach_parent_stdout",
                            return_value=None,
                            create=True,
                        ) as attach:
                            code = run_self_test(FakeAdapter(tmpdir))

        attach.assert_called_once_with()
        self.assertNotEqual(code, 0)

    def test_unwritable_stdout_retries_with_attached_parent_console(self):
        class BrokenStdout:
            closed = False

            def write(self, _value):
                raise OSError("stdout unavailable")

            def flush(self):
                return None

        with tempfile.TemporaryDirectory() as tmpdir:
            attached_stdout = io.StringIO()
            with mock.patch("ytdp.selftest.Toolchain.validate", return_value=successful_report(tmpdir)):
                with mock.patch("ytdp.selftest._run_ffmpeg_cycle", return_value={}):
                    with mock.patch("sys.stdout", BrokenStdout()):
                        with mock.patch(
                            "ytdp.selftest._attach_parent_stdout",
                            return_value=attached_stdout,
                        ) as attach:
                            code = run_self_test(FakeAdapter(tmpdir))

        attach.assert_called_once_with()
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(attached_stdout.getvalue())["status"], "ok")

    def test_atomic_report_allows_success_when_windowed_stdout_is_unavailable(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "self-test.json"
            with mock.patch("ytdp.selftest.Toolchain.validate", return_value=successful_report(tmpdir)):
                with mock.patch("ytdp.selftest._run_ffmpeg_cycle", return_value={}):
                    with mock.patch("sys.stdout", None):
                        with mock.patch(
                            "ytdp.selftest._attach_parent_stdout",
                            return_value=None,
                            create=True,
                        ):
                            code = run_self_test(FakeAdapter(tmpdir), report_path)

            report = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "ok")

    def test_report_replace_failure_is_nonzero_and_preserves_previous_report(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "self-test.json"
            report_path.write_text("previous report\n", encoding="utf-8")
            stdout = io.StringIO()
            with mock.patch("ytdp.selftest.Toolchain.validate", return_value=successful_report(tmpdir)):
                with mock.patch("ytdp.selftest._run_ffmpeg_cycle", return_value={}):
                    with mock.patch("sys.stdout", stdout):
                        with mock.patch.object(Path, "replace", side_effect=RuntimeError("replace blocked")):
                            code = run_self_test(FakeAdapter(tmpdir), report_path)

            emitted = json.loads(stdout.getvalue())
            previous = report_path.read_text(encoding="utf-8")

        self.assertNotEqual(code, 0)
        self.assertEqual(previous, "previous report\n")
        self.assertEqual(emitted["status"], "failed")
        self.assertEqual(emitted["checks"][-1]["name"], "report_writable")

    def test_attach_parent_stdout_uses_windows_attach_console(self):
        kernel32 = mock.Mock()
        attached = io.StringIO()
        fake_windll = mock.Mock(kernel32=kernel32)
        attach_parent = getattr(selftest, "_attach_parent_stdout", None)

        self.assertIsNotNone(attach_parent)

        with mock.patch.object(sys, "platform", "win32"):
            with mock.patch.object(selftest.ctypes, "windll", fake_windll, create=True):
                with mock.patch(
                    "ytdp.selftest._open_windows_stdout",
                    return_value=attached,
                    create=True,
                ) as open_stdout:
                    result = attach_parent()

        kernel32.AttachConsole.assert_called_once_with(0xFFFFFFFF)
        open_stdout.assert_called_once_with(kernel32)
        self.assertIs(result, attached)

    def test_ffmpeg_cycle_uses_only_lgpl_compatible_encoders_and_hidden_execution(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            adapter = FakeAdapter(root)
            commands = []

            def run(command, **kwargs):
                commands.append((list(command), kwargs))
                output = Path(command[-1])
                if output.suffix in {".mp4", ".wav", ".mp3"}:
                    output.write_bytes(b"media")
                probe_output = '{"streams":[{"codec_type":"video"},{"codec_type":"audio"}]}' if "ffprobe.exe" in command[0] else ""
                return subprocess.CompletedProcess(command, 0, probe_output, "")

            with mock.patch("ytdp.selftest.subprocess.run", side_effect=run):
                result = _run_ffmpeg_cycle(adapter, successful_report(root))

        flattened = "\n".join(" ".join(command) for command, _kwargs in commands)
        self.assertNotIn("libx264", flattened)
        self.assertNotIn("-strict", flattened)
        self.assertIn("-c:v mpeg4", flattened)
        self.assertIn("-c:a aac", flattened)
        self.assertIn("-c:a libmp3lame", flattened)
        self.assertEqual(result["streams"], ["video", "audio"])
        for _command, kwargs in commands:
            self.assertEqual(kwargs["timeout"], 8)
            self.assertEqual(kwargs["creationflags"], 0x08000000)


if __name__ == "__main__":
    unittest.main()
