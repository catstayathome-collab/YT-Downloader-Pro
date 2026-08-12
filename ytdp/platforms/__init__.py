"""Supported platform adapters."""

import sys

from .base import PlatformAdapter
from .macos import MacOSPlatform
from .windows import WindowsPlatform


def detect_platform() -> PlatformAdapter:
    """Return an adapter for the current supported operating system."""
    if sys.platform == "win32":
        return WindowsPlatform()
    if sys.platform == "darwin":
        return MacOSPlatform()
    raise RuntimeError(f"unsupported platform: {sys.platform}")


__all__ = ["PlatformAdapter", "MacOSPlatform", "WindowsPlatform", "detect_platform"]
