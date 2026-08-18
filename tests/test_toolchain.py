import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ytdp.diagnostics import DiagnosticLogger
from ytdp.models import ToolchainError
from ytdp.platforms import MacOSPlatform, WindowsPlatform
from ytdp.toolchain import Toolchain


FFMPEG_VERSION = "N-126086-ge5ecfe8970"


def write_pe(path, machine=0x8664):
    data = bytearray(0x90)
    data[:2] = b"MZ"
    data[0x3C:0x40] = (0x80).to_bytes(4, "little")
    data[0x80:0x84] = b"PE\0\0"
    data[0x84:0x86] = machine.to_bytes(2, "little")
    Path(path).write_bytes(data)
    Path(path).chmod(0o755)


def create_helpers(root):
    helper_dir = Path(root) / "Helpers"
    helper_dir.mkdir(parents=True)
    for name in ("ffmpeg.exe", "ffprobe.exe", "deno.exe"):
        write_pe(helper_dir / name)
    return helper_dir


def completed_for(command):
    name = Path(command[0]).name.lower()
    if name == "ffmpeg.exe":
        output = (
            f"ffmpeg version {FFMPEG_VERSION}\n"
            "configuration: --disable-gpl --disable-nonfree --enable-libmp3lame\n"
        )
    elif name == "ffprobe.exe":
        output = f"ffprobe version {FFMPEG_VERSION}\n"
    else:
        output = "deno 2.8.1\nv8 14.2.231.17\ntypescript 5.9.2\n"
    return subprocess.CompletedProcess(command, 0, output, "")


class ToolchainTests(unittest.TestCase):
    def test_valid_toolchain_reports_paths_versions_architectures_and_lgpl(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            helper_dir = create_helpers(root)
            adapter = WindowsPlatform(frozen_dir=root, frozen=True)
            commands = []

            def run(command, **kwargs):
                commands.append((command, kwargs))
                return completed_for(command)

            with mock.patch("ytdp.toolchain.subprocess.run", side_effect=run):
                report = Toolchain(adapter).validate()

            self.assertEqual(
                report.paths,
                {
                    "ffmpeg": str((helper_dir / "ffmpeg.exe").resolve()),
                    "ffprobe": str((helper_dir / "ffprobe.exe").resolve()),
                    "deno": str((helper_dir / "deno.exe").resolve()),
                },
            )
            self.assertEqual(report.versions["ffmpeg"], FFMPEG_VERSION)
            self.assertEqual(report.versions["ffprobe"], FFMPEG_VERSION)
            self.assertEqual(report.versions["deno"], "2.8.1")
            self.assertEqual(set(report.architectures.values()), {"AMD64"})
            self.assertEqual(report.duplicate_counts, {
                "ffmpeg.exe": 1,
                "ffprobe.exe": 1,
                "deno.exe": 1,
            })
            self.assertTrue(report.lgpl_configuration["compatible"])
            self.assertIn("--disable-gpl", report.lgpl_configuration["configuration"])
            self.assertEqual(len(commands), 3)
            for _command, kwargs in commands:
                self.assertEqual(kwargs["timeout"], 8)
                self.assertTrue(kwargs["capture_output"])
                self.assertNotEqual(kwargs["creationflags"], 0)

    def test_rejects_missing_corrupt_and_arm64_helpers(self):
        for problem in ("missing", "corrupt", "arm64"):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                helper_dir = create_helpers(root)
                if problem == "missing":
                    (helper_dir / "deno.exe").unlink()
                elif problem == "corrupt":
                    (helper_dir / "ffmpeg.exe").write_bytes(b"not a PE")
                else:
                    write_pe(helper_dir / "ffprobe.exe", 0xAA64)

                expected = "missing" if problem == "missing" else "helper"
                with mock.patch(
                    "ytdp.toolchain.subprocess.run",
                    side_effect=lambda command, **_kwargs: completed_for(command),
                ):
                    with self.assertRaisesRegex(ToolchainError, expected):
                        Toolchain(WindowsPlatform(frozen_dir=root, frozen=True)).validate()

    def test_rejects_version_mismatch_execution_failure_and_non_lgpl_build(self):
        scenarios = {
            "mismatch": (lambda command, **_kwargs: subprocess.CompletedProcess(
                command,
                0,
                "ffprobe version 7.0\n" if "ffprobe" in Path(command[0]).name else completed_for(command).stdout,
                "",
            ), "version mismatch"),
            "execution": (
                lambda command, **_kwargs: (_ for _ in ()).throw(OSError("blocked token=secret")),
                "execution failed",
            ),
            "gpl": (lambda command, **_kwargs: subprocess.CompletedProcess(
                command,
                0,
                (
                    f"ffmpeg version {FFMPEG_VERSION}\nconfiguration: --enable-gpl\n"
                    if "ffmpeg" in Path(command[0]).name and "ffprobe" not in Path(command[0]).name
                    else completed_for(command).stdout
                ),
                "",
            ), "--enable-gpl"),
            "nonfree": (lambda command, **_kwargs: subprocess.CompletedProcess(
                command,
                0,
                (
                    f"ffmpeg version {FFMPEG_VERSION}\nconfiguration: --enable-nonfree\n"
                    if Path(command[0]).name.lower() == "ffmpeg.exe"
                    else completed_for(command).stdout
                ),
                "",
            ), "--enable-nonfree"),
        }
        for problem, (result, expected) in scenarios.items():
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                create_helpers(root)
                with mock.patch("ytdp.toolchain.subprocess.run", side_effect=result):
                    with self.assertRaisesRegex(ToolchainError, expected):
                        Toolchain(WindowsPlatform(frozen_dir=root, frozen=True)).validate()

    def test_windows_deno_version_requires_zero_exit_code(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            create_helpers(root)

            def deno_fails(command, **_kwargs):
                result = completed_for(command)
                if Path(command[0]).name.lower() == "deno.exe":
                    result.returncode = 1
                return result

            with mock.patch("ytdp.toolchain.subprocess.run", side_effect=deno_fails):
                with self.assertRaisesRegex(ToolchainError, "deno execution failed"):
                    Toolchain(WindowsPlatform(frozen_dir=root, frozen=True)).validate()

    def test_rejects_ffmpeg_without_configuration_evidence(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            create_helpers(root)

            def no_configuration(command, **_kwargs):
                result = completed_for(command)
                if Path(command[0]).name.lower() == "ffmpeg.exe":
                    result.stdout = f"ffmpeg version {FFMPEG_VERSION}\n"
                return result

            with mock.patch("ytdp.toolchain.subprocess.run", side_effect=no_configuration):
                with self.assertRaisesRegex(ToolchainError, "configuration"):
                    Toolchain(WindowsPlatform(frozen_dir=root, frozen=True)).validate()

    def test_macos_quickjs_version_output_remains_supported(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            helper_dir = root / "tools"
            helper_dir.mkdir()
            for name in ("ffmpeg", "ffprobe", "qjs"):
                path = helper_dir / name
                path.write_bytes(b"helper")
                path.chmod(0o755)
            adapter = MacOSPlatform(frozen_dir=root, frozen=False)

            def run(command, **_kwargs):
                name = Path(command[0]).name
                if name == "ffmpeg":
                    output = f"ffmpeg version 9.0\nconfiguration: --disable-gpl\n"
                    return subprocess.CompletedProcess(command, 0, output, "")
                if name == "ffprobe":
                    return subprocess.CompletedProcess(command, 0, "ffprobe version 9.0\n", "")
                return subprocess.CompletedProcess(
                    command, 1, "QuickJS version 2026-06-04\nusage: qjs", ""
                )

            with mock.patch.object(adapter, "validate_architecture"):
                with mock.patch("ytdp.toolchain.subprocess.run", side_effect=run):
                    report = Toolchain(adapter).validate()

            self.assertEqual(report.versions["quickjs"], "2026-06-04")
            self.assertEqual(report.architectures["quickjs"], "native")

    def test_frozen_package_rejects_duplicate_physical_helper(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            create_helpers(root)
            write_pe(root / "ffmpeg.exe")
            adapter = WindowsPlatform(frozen_dir=root, frozen=True)

            with self.assertRaisesRegex(ToolchainError, "duplicate"):
                Toolchain(adapter).validate()

    def test_source_mode_duplicate_scan_ignores_tool_cache_outside_helper_dir(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            create_helpers(root)
            cached = root / "build" / "windows-tools" / "Helpers"
            cached.mkdir(parents=True)
            write_pe(cached / "ffmpeg.exe")
            adapter = WindowsPlatform(frozen_dir=root, frozen=False)

            with mock.patch(
                "ytdp.toolchain.subprocess.run",
                side_effect=lambda command, **_kwargs: completed_for(command),
            ):
                report = Toolchain(adapter).validate()

            self.assertEqual(report.duplicate_counts["ffmpeg.exe"], 1)


class DiagnosticLoggerTests(unittest.TestCase):
    def test_logger_redacts_sensitive_message_and_separate_command_arguments(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "diagnostics.jsonl"
            logger = DiagnosticLogger(path=path)
            logger.log(
                "helper failed authorization=header-secret sig=query-secret",
                stage="toolchain",
                command=[
                    "deno.exe",
                    "--cookies",
                    "cookie-secret",
                    "--access-token=token-secret",
                    "--password",
                    "password-secret",
                ],
            )

            entry = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual(entry["stage"], "toolchain")
        self.assertIn("[REDACTED]", entry["message"])
        rendered = json.dumps(entry)
        for secret in (
            "header-secret",
            "query-secret",
            "cookie-secret",
            "token-secret",
            "password-secret",
        ):
            self.assertNotIn(secret, rendered)

    def test_logger_recursively_redacts_sensitive_keys_and_compound_options(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "diagnostics.jsonl"
            logger = DiagnosticLogger(path=path)
            logger.log(
                "helper failed",
                stage="toolchain",
                command=[
                    "deno.exe",
                    "--cookies-from-browser", "firefox-secret",
                    "--password-file=password-secret",
                    "--access-token", "access-secret",
                    "--api-key=api-secret",
                    "--signature", "signature-secret",
                    "--credential=credential-secret",
                    "--session-token", "session-secret",
                ],
                token="top-secret",
                metadata={
                    "authorization": "authorization-secret",
                    "nested": [
                        {"sig": "sig-secret", "safe": "keep-me"},
                        {
                            "api_key": "nested-api-secret",
                            "accessToken": "camel-access-secret",
                            "passwordFile": "camel-password-secret",
                            "cookiesFromBrowser": "camel-cookie-secret",
                            "sessionToken": "camel-session-secret",
                        },
                    ],
                },
            )

            entry = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual(entry["token"], "[REDACTED]")
        self.assertEqual(entry["metadata"]["authorization"], "[REDACTED]")
        self.assertEqual(entry["metadata"]["nested"][0]["sig"], "[REDACTED]")
        self.assertEqual(entry["metadata"]["nested"][0]["safe"], "keep-me")
        rendered = json.dumps(entry)
        for secret in (
            "firefox-secret", "password-secret", "access-secret", "api-secret",
            "signature-secret", "credential-secret", "session-secret", "top-secret",
            "authorization-secret", "sig-secret", "nested-api-secret",
            "camel-access-secret", "camel-password-secret",
            "camel-cookie-secret", "camel-session-secret",
        ):
            self.assertNotIn(secret, rendered)

    def test_logger_redacts_camelcase_suffix_keys_without_substring_false_positives(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "diagnostics.jsonl"
            logger = DiagnosticLogger(path=path)
            logger.log(
                "helper failed",
                command=[
                    "helper.exe",
                    "--refreshToken", "cli-refresh-secret",
                    "--clientSecret=cli-client-secret",
                    "--tokenizer", "wordpiece",
                    "--signatureAlgorithm=sha256",
                    "refreshToken", "positional-safe",
                ],
                metadata={
                    "nested": [
                        {
                            "refreshToken": "nested-refresh-secret",
                            "authToken": "nested-auth-secret",
                        },
                        {
                            "idToken": "nested-id-secret",
                            "clientSecret": "nested-client-secret",
                            "tokenizer": "bert-tokenizer",
                            "signatureAlgorithm": "sha256",
                        },
                    ],
                },
            )

            entry = json.loads(path.read_text(encoding="utf-8"))

        nested = entry["metadata"]["nested"]
        self.assertEqual(nested[0]["refreshToken"], "[REDACTED]")
        self.assertEqual(nested[0]["authToken"], "[REDACTED]")
        self.assertEqual(nested[1]["idToken"], "[REDACTED]")
        self.assertEqual(nested[1]["clientSecret"], "[REDACTED]")
        self.assertEqual(nested[1]["tokenizer"], "bert-tokenizer")
        self.assertEqual(nested[1]["signatureAlgorithm"], "sha256")
        self.assertEqual(
            entry["command"],
            [
                "helper.exe",
                "--refreshToken", "[REDACTED]",
                "--clientSecret=[REDACTED]",
                "--tokenizer", "wordpiece",
                "--signatureAlgorithm=sha256",
                "refreshToken", "positional-safe",
            ],
        )


if __name__ == "__main__":
    unittest.main()
