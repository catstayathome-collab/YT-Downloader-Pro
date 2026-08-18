"""Windows 1.8.8 launcher for the shared YT Downloader Pro application."""

import argparse
import sys
from pathlib import Path


APP_NAME = "YT Downloader Pro"
VERSION = "1.8.8"


def _load_ui():
    from ytdp.app import YTDownloaderApp, run_app

    return YTDownloaderApp, run_app


def __getattr__(name):
    """Preserve legacy launcher imports without loading UI dependencies early."""
    if name in {"DownloadArtifactTracker", "DownloadRequest"}:
        from ytdp import DownloadArtifactTracker, DownloadRequest

        return {
            "DownloadArtifactTracker": DownloadArtifactTracker,
            "DownloadRequest": DownloadRequest,
        }[name]
    if name == "YTDownloaderApp":
        application, _launch = _load_ui()
        return application
    raise AttributeError(name)


def make_platform():
    """Build the Windows adapter with the current source or package root."""
    from ytdp.platforms import WindowsPlatform

    root = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
    return WindowsPlatform(frozen_dir=root, frozen=getattr(sys, "frozen", False))


def run_app(platform_adapter, version=VERSION):
    _application, launch = _load_ui()
    return launch(platform_adapter, version=version)


def main(argv=None):
    """Run the packaged self-test or launch the Windows interface."""
    args = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(prog=APP_NAME)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--self-test-report",
        help="atomic JSON evidence path; CI must always provide this with --self-test",
    )
    options = parser.parse_args(args)
    if options.self_test:
        from ytdp.selftest import run_self_test

        return run_self_test(make_platform(), options.self_test_report)
    if options.self_test_report is not None:
        parser.error("--self-test-report requires --self-test")
    if sys.platform != "win32":
        raise RuntimeError("YT Downloader Pro Windows can only launch on Windows.")
    run_app(make_platform(), version=VERSION)
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
