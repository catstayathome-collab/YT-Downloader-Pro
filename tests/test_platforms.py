import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ytdp.models import ToolchainError
from ytdp.platforms import MacOSPlatform, WindowsPlatform, detect_platform
from ytdp.settings import load_settings, save_settings, valid_output_directory


def write_pe(path, machine):
    data = bytearray(0x90)
    data[:2] = b"MZ"
    data[0x3C:0x40] = (0x80).to_bytes(4, "little")
    data[0x80:0x84] = b"PE\0\0"
    data[0x84:0x86] = machine.to_bytes(2, "little")
    Path(path).write_bytes(data)


class WindowsPlatformTests(unittest.TestCase):
    def test_windows_paths_use_roaming_and_local_appdata(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            with mock.patch.dict(
                os.environ,
                {
                    "APPDATA": str(root / "Roaming"),
                    "LOCALAPPDATA": str(root / "Local"),
                },
                clear=False,
            ):
                adapter = WindowsPlatform(frozen_dir=root)

                self.assertEqual(
                    adapter.settings_dir(),
                    root / "Roaming" / "YT Downloader Pro",
                )
                self.assertEqual(
                    adapter.log_dir(),
                    root / "Local" / "YT Downloader Pro" / "logs",
                )

    def test_windows_helper_names_and_console_suppression(self):
        adapter = WindowsPlatform(frozen_dir=Path("C:/App"))

        self.assertEqual(adapter.helper_name("ffmpeg"), "ffmpeg.exe")
        self.assertEqual(adapter.helper_dir(), Path("C:/App/Helpers"))
        self.assertNotEqual(adapter.subprocess_kwargs()["creationflags"], 0)

    def test_windows_download_directory_falls_back_to_userprofile(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            userprofile = Path(tmpdir) / "User"
            with mock.patch.dict(
                os.environ, {"USERPROFILE": str(userprofile)}, clear=False
            ):
                adapter = WindowsPlatform(frozen_dir=Path(tmpdir))
                with mock.patch.object(adapter, "_known_download_dir", return_value=None):
                    self.assertEqual(
                        adapter.default_download_dir(), userprofile / "Downloads"
                    )

    def test_windows_download_directory_falls_back_to_home(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            home = Path(tmpdir) / "Home"
            with mock.patch.dict(os.environ, {}, clear=True):
                adapter = WindowsPlatform(frozen_dir=Path(tmpdir))
                with mock.patch.object(adapter, "_known_download_dir", return_value=None):
                    with mock.patch("ytdp.platforms.windows.Path.home", return_value=home):
                        self.assertEqual(adapter.default_download_dir(), home / "Downloads")

    def test_windows_language_uses_the_user_interface_language(self):
        adapter = WindowsPlatform()
        with mock.patch.object(adapter, "_user_ui_language_id", return_value=0x0404):
            self.assertEqual(adapter.language(), "zh")
        with mock.patch.object(adapter, "_user_ui_language_id", return_value=0x0411):
            self.assertEqual(adapter.language(), "ja")
        with mock.patch.object(adapter, "_user_ui_language_id", return_value=0x0409):
            self.assertEqual(adapter.language(), "en")

    def test_windows_language_falls_back_to_process_locale(self):
        adapter = WindowsPlatform()
        with mock.patch.object(adapter, "_user_ui_language_id", side_effect=OSError):
            with mock.patch("ytdp.platforms.windows.locale.getlocale", return_value=("ja_JP", "UTF-8")):
                self.assertEqual(adapter.language(), "ja")

    def test_windows_accepts_amd64_pe_header(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "ffmpeg.exe"
            write_pe(path, 0x8664)

            WindowsPlatform().validate_architecture(path)

    def test_windows_rejects_arm64_and_corrupt_helpers(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            arm64 = Path(tmpdir) / "arm64.exe"
            corrupt = Path(tmpdir) / "corrupt.exe"
            write_pe(arm64, 0xAA64)
            corrupt.write_bytes(b"not a PE")
            adapter = WindowsPlatform()

            with self.assertRaises(ToolchainError):
                adapter.validate_architecture(arm64)
            with self.assertRaises(ToolchainError):
                adapter.validate_architecture(corrupt)


class MacOSPlatformTests(unittest.TestCase):
    def test_macos_preserves_application_support_and_apple_language_lookup(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            home = Path(tmpdir) / "Home"
            adapter = MacOSPlatform(frozen_dir=Path(tmpdir), frozen=False)
            with mock.patch("ytdp.platforms.macos.Path.home", return_value=home):
                self.assertEqual(
                    adapter.settings_dir(),
                    home / "Library" / "Application Support" / "YT Downloader Pro",
                )
            completed = mock.Mock(stdout='(\n    "ja-JP",\n)\n')
            with mock.patch("ytdp.platforms.macos.subprocess.run", return_value=completed):
                self.assertEqual(adapter.language(), "ja")


class PlatformDetectionTests(unittest.TestCase):
    def test_detect_platform_uses_current_platform(self):
        with mock.patch("ytdp.platforms.sys.platform", "win32"):
            self.assertIsInstance(detect_platform(), WindowsPlatform)
        with mock.patch("ytdp.platforms.sys.platform", "darwin"):
            self.assertIsInstance(detect_platform(), MacOSPlatform)


class SettingsTests(unittest.TestCase):
    def test_settings_save_filters_values_and_loads_utf8_json(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "new" / "settings.json"

            save_settings(
                path,
                {"download_path": "/tmp/\u4e0b\u8f09", "language": "zh", "ignored": "value"},
            )

            self.assertEqual(
                json.loads(path.read_text(encoding="utf-8")),
                {"download_path": "/tmp/\u4e0b\u8f09", "language": "zh"},
            )
            self.assertEqual(
                load_settings(path),
                {"download_path": "/tmp/\u4e0b\u8f09", "language": "zh"},
            )

    def test_settings_handles_malformed_json_and_unavailable_destination(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "settings.json"
            path.write_text("{broken", encoding="utf-8")

            self.assertEqual(load_settings(path), {})
            self.assertIsNone(save_settings(Path("/dev/null") / "settings.json", {}))

    def test_valid_output_directory_uses_existing_saved_path_or_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            saved = root / "saved"
            fallback = root / "fallback"
            saved.mkdir()

            self.assertEqual(valid_output_directory(saved, fallback), saved)
            self.assertEqual(valid_output_directory(root / "missing", fallback), fallback)

    def test_valid_output_directory_falls_back_for_invalid_os_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            fallback = Path(tmpdir) / "fallback"

            with mock.patch("ytdp.settings.Path.is_dir", side_effect=OSError("bad path")):
                self.assertEqual(valid_output_directory("\0invalid", fallback), fallback)

    def test_valid_output_directory_falls_back_when_saved_path_is_not_writable(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            saved = root / "saved"
            fallback = root / "fallback"
            saved.mkdir()

            with mock.patch("os.access", return_value=False):
                self.assertEqual(valid_output_directory(saved, fallback), fallback)


if __name__ == "__main__":
    unittest.main()
