"""macOS application environment support."""

from pathlib import Path
import platform
import re
import subprocess

from ytdp.models import ToolchainError

from .base import APP_NAME, PlatformAdapter


class MacOSPlatform(PlatformAdapter):
    """Preserve the existing macOS bundle and language behavior."""

    def settings_dir(self) -> Path:
        return Path.home() / "Library" / "Application Support" / APP_NAME

    def log_dir(self) -> Path:
        return self.settings_dir() / "logs"

    def default_download_dir(self) -> Path:
        return Path.home() / "Downloads"

    def helper_dir(self) -> Path:
        if not self.frozen:
            return self.frozen_dir / "tools"
        canonical = self.frozen_dir / "Helpers"
        bundled = self.frozen_dir / "_internal" / "Helpers"
        if canonical.is_dir() or not bundled.is_dir():
            return canonical
        return bundled

    def helper_name(self, tool) -> str:
        return tool

    def language(self) -> str:
        try:
            result = subprocess.run(
                ["defaults", "read", "-g", "AppleLanguages"],
                capture_output=True,
                text=True,
                timeout=1,
                **self.subprocess_kwargs(),
            )
            match = re.search(r'"([^"]+)"', result.stdout.lower())
            if match:
                primary = match.group(1)
                if primary.startswith("ja"):
                    return "ja"
                if primary.startswith("zh"):
                    return "zh"
        except Exception:
            pass
        return "en"

    def subprocess_kwargs(self) -> dict:
        return {}

    def validate_architecture(self, path) -> None:
        if platform.machine() != "arm64":
            return
        try:
            result = subprocess.run(
                ["/usr/bin/lipo", "-archs", str(path)],
                capture_output=True,
                text=True,
                timeout=5,
                **self.subprocess_kwargs(),
            )
        except Exception as error:
            raise ToolchainError(f"cannot inspect helper architecture: {path}") from error
        if result.returncode == 0 and "arm64" not in result.stdout.split():
            raise ToolchainError(f"helper is not arm64: {path}")

    def filename_platform(self) -> str:
        return "macos"

    def js_runtime_name(self) -> str:
        return "quickjs"

    def js_runtime_tool(self) -> str:
        return "qjs"

    def js_runtime_check_args(self) -> tuple[str, ...]:
        return ("--help",)

    def js_runtime_output_marker(self) -> str:
        return "QuickJS version"
