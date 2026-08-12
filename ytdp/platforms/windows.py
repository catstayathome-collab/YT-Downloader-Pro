"""Windows application environment support."""

import ctypes
import locale
import os
from pathlib import Path
import subprocess
import sys

from ytdp.models import ToolchainError

from .base import APP_NAME, PlatformAdapter


class WindowsPlatform(PlatformAdapter):
    """Locate Windows application data and validate x64 helper binaries."""

    def settings_dir(self) -> Path:
        roaming = os.environ.get("APPDATA")
        base = Path(roaming) if roaming else Path.home() / "AppData" / "Roaming"
        return base / APP_NAME

    def log_dir(self) -> Path:
        local = os.environ.get("LOCALAPPDATA")
        base = Path(local) if local else Path.home() / "AppData" / "Local"
        return base / APP_NAME / "logs"

    def _known_download_dir(self):
        if sys.platform != "win32":
            return None

        class Guid(ctypes.Structure):
            _fields_ = [
                ("Data1", ctypes.c_ulong),
                ("Data2", ctypes.c_ushort),
                ("Data3", ctypes.c_ushort),
                ("Data4", ctypes.c_ubyte * 8),
            ]

        downloads = Guid(
            0x374DE290,
            0x123F,
            0x4565,
            (ctypes.c_ubyte * 8)(0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B),
        )
        result = ctypes.c_wchar_p()
        try:
            status = ctypes.windll.shell32.SHGetKnownFolderPath(
                ctypes.byref(downloads), 0, None, ctypes.byref(result)
            )
            if status != 0 or not result.value:
                return None
            return Path(result.value)
        except Exception:
            return None
        finally:
            if result:
                try:
                    ctypes.windll.ole32.CoTaskMemFree(result)
                except Exception:
                    pass

    def default_download_dir(self) -> Path:
        known = self._known_download_dir()
        if known is not None:
            return known
        userprofile = os.environ.get("USERPROFILE")
        if userprofile:
            return Path(userprofile) / "Downloads"
        return Path.home() / "Downloads"

    def helper_dir(self) -> Path:
        return self.frozen_dir / "Helpers"

    def helper_name(self, tool) -> str:
        return tool if str(tool).lower().endswith(".exe") else f"{tool}.exe"

    def language(self) -> str:
        try:
            language = locale.getlocale()[0] or ""
        except Exception:
            language = ""
        language = language.lower()
        if language.startswith("ja"):
            return "ja"
        if language.startswith("zh"):
            return "zh"
        return "en"

    def subprocess_kwargs(self) -> dict:
        kwargs = {
            "creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000),
        }
        if hasattr(subprocess, "STARTUPINFO"):
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= getattr(subprocess, "STARTF_USESHOWWINDOW", 1)
            startupinfo.wShowWindow = getattr(subprocess, "SW_HIDE", 0)
            kwargs["startupinfo"] = startupinfo
        return kwargs

    def validate_architecture(self, path) -> None:
        path = Path(path)
        try:
            with path.open("rb") as helper:
                header = helper.read(64)
                if len(header) < 64 or header[:2] != b"MZ":
                    raise ValueError("missing DOS header")
                pe_offset = int.from_bytes(header[0x3C:0x40], "little")
                helper.seek(pe_offset)
                pe_header = helper.read(6)
            if len(pe_header) != 6 or pe_header[:4] != b"PE\0\0":
                raise ValueError("missing PE header")
            machine = int.from_bytes(pe_header[4:6], "little")
        except (OSError, ValueError) as error:
            raise ToolchainError(f"invalid Windows helper: {path}") from error
        if machine != 0x8664:
            raise ToolchainError(f"Windows helper is not AMD64: {path}")

    def filename_platform(self) -> str:
        return "windows"

    def js_runtime_name(self) -> str:
        return "deno"

    def js_runtime_tool(self) -> str:
        return "deno"

    def js_runtime_check_args(self) -> tuple[str, ...]:
        return ("--version",)

    def js_runtime_output_marker(self) -> str:
        return "deno"
