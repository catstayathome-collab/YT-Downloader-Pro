import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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
