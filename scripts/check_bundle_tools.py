#!/usr/bin/env python3
import os
import platform
import subprocess
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check_bundle_tools.py /path/to/App.app", file=sys.stderr)
        return 2

    app = Path(sys.argv[1])
    helpers = app / "Contents" / "Helpers"
    expected = [helpers / "ffmpeg", helpers / "ffprobe"]
    missing = [str(path) for path in expected if not path.is_file()]
    if missing:
        print("Missing bundled tools:", ", ".join(missing), file=sys.stderr)
        return 1
    not_executable = [str(path) for path in expected if not os.access(path, os.X_OK)]
    if not_executable:
        print("Bundled tools are not executable:", ", ".join(not_executable), file=sys.stderr)
        return 1
    for path in expected:
        version = subprocess.run([str(path), "-version"], capture_output=True, text=True, timeout=8)
        if version.returncode != 0:
            print(f"{path} failed to run -version:", file=sys.stderr)
            print((version.stderr or version.stdout).strip(), file=sys.stderr)
            return 1
        if platform.machine() == "arm64":
            arches = subprocess.run(["/usr/bin/lipo", "-archs", str(path)], capture_output=True, text=True, timeout=5)
            if arches.returncode == 0 and "arm64" not in arches.stdout.split():
                print(f"{path} is not Apple Silicon compatible: {arches.stdout.strip()}", file=sys.stderr)
                return 1

    ffmpeg_paths = list((app / "Contents").rglob("ffmpeg"))
    real_files = {}
    for path in ffmpeg_paths:
        try:
            stat = path.stat()
        except OSError:
            continue
        real_files[(stat.st_dev, stat.st_ino)] = path.resolve()

    if len(real_files) != 1:
        print("Expected one physical ffmpeg file, found:", file=sys.stderr)
        for path in sorted(real_files.values()):
            print(f"  {path}", file=sys.stderr)
        return 1

    print(f"OK: one physical ffmpeg at {next(iter(real_files.values()))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
