"""macOS 1.8.8 launcher for the shared YT Downloader Pro application."""

import os
import sys
from pathlib import Path

from ytdp import DownloadArtifactTracker, DownloadRequest, ToolchainError, format_bytes, reserve_output_stem
from ytdp.app import (
    APP_NAME,
    COOKIES_BROWSER,
    DEFAULT_DOWNLOAD_PATH,
    DEFAULT_UPDATE_DOWNLOAD_URL,
    DEFAULT_UPDATE_MANIFEST_URL,
    LANG_DATA,
    PUBLIC_UPDATE_MANIFEST_URL,
    UPDATE_DOWNLOAD_URL,
    YTDownloaderApp,
    run_app as _run_app,
)
from ytdp.platforms import MacOSPlatform

VERSION = "1.8.8"


def run_app(platform_adapter, version=VERSION):
    return _run_app(platform_adapter, version=version)


def make_platform():
    """Build the macOS adapter with the current source or bundle root."""
    if getattr(sys, "frozen", False):
        executable_dir = Path(sys.executable).resolve().parent
        contents_dir = (
            executable_dir.parent
            if executable_dir.name == "MacOS" and executable_dir.parent.name == "Contents"
            else executable_dir
        )
    else:
        contents_dir = Path(__file__).resolve().parents[2]
    return MacOSPlatform(frozen_dir=contents_dir, frozen=getattr(sys, "frozen", False))


def main():
    return run_app(make_platform(), version=VERSION)


__all__ = [
    "APP_NAME",
    "COOKIES_BROWSER",
    "DEFAULT_DOWNLOAD_PATH",
    "DEFAULT_UPDATE_DOWNLOAD_URL",
    "DEFAULT_UPDATE_MANIFEST_URL",
    "DownloadArtifactTracker",
    "DownloadRequest",
    "LANG_DATA",
    "PUBLIC_UPDATE_MANIFEST_URL",
    "ToolchainError",
    "UPDATE_DOWNLOAD_URL",
    "VERSION",
    "YTDownloaderApp",
    "format_bytes",
    "main",
    "make_platform",
    "reserve_output_stem",
    "run_app",
]


if __name__ == "__main__":
    main()
