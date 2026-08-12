"""Windows 1.8.7 launcher for the shared YT Downloader Pro application."""

import sys
from pathlib import Path

from ytdp import DownloadArtifactTracker, DownloadRequest
from ytdp.app import APP_NAME, VERSION, YTDownloaderApp, run_app
from ytdp.platforms import WindowsPlatform


def make_platform():
    """Build the Windows adapter with the current source or package root."""
    root = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
    return WindowsPlatform(frozen_dir=root, frozen=getattr(sys, "frozen", False))


def main(argv=None):
    """Launch on Windows, reserving packaged verification for Task 5."""
    args = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in args:
        try:
            from ytdp.selftest import run_self_test
        except ImportError:
            print("--self-test is implemented by Windows 1.8.7 Task 5.", file=sys.stderr)
            return 2
        return run_self_test(make_platform())
    if sys.platform != "win32":
        raise RuntimeError("YT Downloader Pro Windows can only launch on Windows.")
    run_app(make_platform())
    return 0


__all__ = [
    "APP_NAME",
    "DownloadArtifactTracker",
    "DownloadRequest",
    "VERSION",
    "YTDownloaderApp",
    "main",
    "make_platform",
]


if __name__ == "__main__":
    raise SystemExit(main())
