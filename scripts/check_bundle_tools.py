#!/usr/bin/env python3
import hashlib
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path


EXPECTED_METADATA = {
    "CFBundleShortVersionString": "1.8.7",
    "CFBundleVersion": "187",
    "LSMinimumSystemVersion": "11.0",
}

ALLOWED_DYLIB_PREFIXES = ("/System/Library/", "/usr/lib/")
MAXIMUM_DEPLOYMENT_TARGET = (11, 0)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def physical_files(paths):
    files = {}
    for path in paths:
        try:
            stat = path.stat()
        except OSError:
            continue
        files[(stat.st_dev, stat.st_ino)] = path.resolve()
    return files


def unexpected_dependencies(path):
    result = subprocess.run(
        ["/usr/bin/otool", "-L", str(path)],
        capture_output=True,
        text=True,
        timeout=8,
    )
    if result.returncode != 0:
        return [f"otool failed: {(result.stderr or result.stdout).strip()}"]
    dependencies = [line.strip().split(" (", 1)[0] for line in result.stdout.splitlines()[1:]]
    return [dependency for dependency in dependencies if not dependency.startswith(ALLOWED_DYLIB_PREFIXES)]


def deployment_target(path):
    result = subprocess.run(
        ["/usr/bin/otool", "-l", str(path)],
        capture_output=True,
        text=True,
        timeout=8,
    )
    if result.returncode != 0:
        return None
    match = re.search(r"^\s+(?:minos|version)\s+(\d+(?:\.\d+)*)\s*$", result.stdout, re.MULTILINE)
    if not match:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check_bundle_tools.py /path/to/App.app", file=sys.stderr)
        return 2

    app = Path(sys.argv[1])
    info_plist = app / "Contents" / "Info.plist"
    if not info_plist.is_file():
        print(f"Missing bundle metadata: {info_plist}", file=sys.stderr)
        return 1
    with info_plist.open("rb") as handle:
        metadata = plistlib.load(handle)
    for key, expected_value in EXPECTED_METADATA.items():
        actual_value = str(metadata.get(key, ""))
        if actual_value != expected_value:
            print(f"Unexpected {key}: {actual_value!r} (expected {expected_value!r})", file=sys.stderr)
            return 1

    source_icon = Path(__file__).resolve().parent.parent / "AppIcon.icns"
    bundled_icon = app / "Contents" / "Resources" / metadata.get("CFBundleIconFile", "")
    if not source_icon.is_file() or not bundled_icon.is_file():
        print("Source or bundled app icon is missing", file=sys.stderr)
        return 1
    if sha256(source_icon) != sha256(bundled_icon):
        print("Bundled app icon does not match AppIcon.icns", file=sys.stderr)
        return 1

    helpers = app / "Contents" / "Helpers"
    expected = [helpers / "ffmpeg", helpers / "ffprobe", helpers / "qjs"]
    missing = [str(path) for path in expected if not path.is_file()]
    if missing:
        print("Missing bundled tools:", ", ".join(missing), file=sys.stderr)
        return 1
    not_executable = [str(path) for path in expected if not os.access(path, os.X_OK)]
    if not_executable:
        print("Bundled tools are not executable:", ", ".join(not_executable), file=sys.stderr)
        return 1
    versions = {}
    for path in expected[:2]:
        version = subprocess.run([str(path), "-version"], capture_output=True, text=True, timeout=8)
        if version.returncode != 0:
            print(f"{path} failed to run -version:", file=sys.stderr)
            print((version.stderr or version.stdout).strip(), file=sys.stderr)
            return 1
        output = f"{version.stdout}\n{version.stderr}"
        if "--enable-nonfree" in output:
            print(f"{path} was built with --enable-nonfree and cannot be released", file=sys.stderr)
            return 1
        match = re.search(r"(?:ffmpeg|ffprobe) version\s+(\S+)", output)
        versions[path.name] = match.group(1) if match else ""

    if not versions.get("ffmpeg") or versions["ffmpeg"] != versions.get("ffprobe"):
        print(f"FFmpeg and FFprobe versions do not match: {versions}", file=sys.stderr)
        return 1

    qjs = helpers / "qjs"
    qjs_version = subprocess.run(
        [str(qjs), "--help"], capture_output=True, text=True, timeout=8
    )
    qjs_output = f"{qjs_version.stdout}\n{qjs_version.stderr}"
    if qjs_version.returncode not in (0, 1) or "QuickJS version" not in qjs_output:
        print(f"{qjs} failed its QuickJS version check", file=sys.stderr)
        return 1

    app_executable = app / "Contents" / "MacOS" / "YT Downloader Pro"
    for path in [app_executable, *expected]:
        arches = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(path)],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if arches.returncode != 0 or "arm64" not in arches.stdout.split():
            detail = (arches.stderr or arches.stdout).strip()
            print(f"{path} is not Apple Silicon compatible: {detail}", file=sys.stderr)
            return 1
        target = deployment_target(path)
        if target is None or target > MAXIMUM_DEPLOYMENT_TARGET:
            detail = ".".join(str(part) for part in target) if target else "unknown"
            print(f"{path} requires macOS {detail}; expected macOS 11.0 or earlier", file=sys.stderr)
            return 1

    for path in expected:
        dependencies = unexpected_dependencies(path)
        if dependencies:
            print(f"{path} has unexpected dynamic dependencies:", file=sys.stderr)
            for dependency in dependencies:
                print(f"  {dependency}", file=sys.stderr)
            return 1

    for tool in ("ffmpeg", "ffprobe", "qjs"):
        real_files = physical_files((app / "Contents").rglob(tool))
        if len(real_files) != 1:
            print(f"Expected one physical {tool} file, found:", file=sys.stderr)
            for path in sorted(real_files.values()):
                print(f"  {path}", file=sys.stderr)
            return 1

    signature = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if signature.returncode != 0:
        print("App signature verification failed:", file=sys.stderr)
        print((signature.stderr or signature.stdout).strip(), file=sys.stderr)
        return 1

    print(f"OK: {app.name} v1.8.7 build 187 is arm64 compatible and internally consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
