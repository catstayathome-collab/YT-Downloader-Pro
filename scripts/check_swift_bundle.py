#!/usr/bin/env python3
"""Fail-closed validation for a packaged YT Downloader Pro 2 app bundle."""

import argparse
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path


APP_BUNDLE_NAME = "YT Downloader Pro 2.app"
APP_EXECUTABLE_NAME = "YT Downloader Pro 2"
BUNDLE_IDENTIFIER = "com.tachouweng.ytdownloaderpro2"
MINIMUM_MACOS = "13.0"
EXPECTED_HELPERS = ("yt-dlp_macos", "ffmpeg", "ffprobe", "qjs")
EXPECTED_LOCALES = ("en", "ja", "zh-Hant")
EXPECTED_LICENSES = (
    "FFmpeg-LGPL-2.1.txt",
    "LAME-LGPL-2.0.txt",
    "QuickJS-MIT.txt",
)
SUPPORTED_ARCHITECTURES = ("arm64", "x86_64")
ALLOWED_DYLIB_PREFIXES = ("/System/Library/", "/usr/lib/")
FORBIDDEN_STATE_NAMES = {
    "diagnostics",
    "diagnostics.jsonl",
    "downloads.json",
    "downloads.next",
    "downloads.previous",
    "state",
    "thumbnails",
}


@dataclass(frozen=True)
class BundleVerificationReport:
    checked_path: str
    expected_version: str
    architectures: tuple[str, ...]
    executable_architectures: dict[str, tuple[str, ...]]
    helper_versions: dict[str, str]
    errors: tuple[str, ...]

    @property
    def ok(self):
        return not self.errors

    def as_dict(self):
        result = asdict(self)
        result["ok"] = self.ok
        return result

    def to_json(self):
        return json.dumps(self.as_dict(), indent=2, sort_keys=True) + "\n"


def _default_command_runner(command, **kwargs):
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=kwargs.pop("timeout", 15),
        check=False,
        **kwargs,
    )


def _command_output(result):
    return "\n".join(part for part in (result.stdout, result.stderr) if part).strip()


def _relative(path, bundle):
    try:
        return path.relative_to(bundle).as_posix()
    except ValueError:
        return str(path)


def _inside(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _bundle_entries(bundle):
    entries = []
    if not bundle.is_dir() or bundle.is_symlink():
        return entries
    for current, directories, files in os.walk(bundle, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        root = Path(current)
        entries.extend(root / name for name in directories)
        entries.extend(root / name for name in files)
    return entries


def _trusted_regular_file(path, bundle):
    try:
        if not stat.S_ISREG(path.lstat().st_mode):
            return False
        resolved_bundle = bundle.resolve(strict=True)
        resolved_path = path.resolve(strict=True)
    except OSError:
        return False
    if not _inside(resolved_path, resolved_bundle):
        return False
    current = path.parent
    while current != bundle.parent:
        try:
            if current.is_symlink():
                return False
        except OSError:
            return False
        if current == bundle:
            break
        current = current.parent
    return current == bundle


def _run(command_runner, command, errors, label, **kwargs):
    try:
        return command_runner(command, **kwargs)
    except (OSError, subprocess.SubprocessError) as error:
        errors.append(f"{label} could not run: {error}")
        return None


def _architectures(path, command_runner, errors):
    result = _run(
        command_runner,
        ["/usr/bin/lipo", "-archs", str(path)],
        errors,
        f"architecture check for {path.name}",
        timeout=8,
    )
    if result is None:
        return ()
    if result.returncode != 0:
        errors.append(
            f"architecture check failed for {path.name}: {_command_output(result) or 'no diagnostic'}"
        )
        return ()
    architectures = tuple(part for part in result.stdout.split() if part in SUPPORTED_ARCHITECTURES)
    if not architectures:
        errors.append(f"architecture check returned no supported slices for {path.name}")
    return architectures


def _deployment_target(path, command_runner, errors):
    result = _run(
        command_runner,
        ["/usr/bin/otool", "-l", str(path)],
        errors,
        f"deployment target check for {path.name}",
        timeout=8,
    )
    if result is None:
        return None
    if result.returncode != 0:
        errors.append(
            f"deployment target check failed for {path.name}: {_command_output(result) or 'no diagnostic'}"
        )
        return None
    match = re.search(r"^\s*(?:minos|version)\s+(\d+(?:\.\d+)*)\s*$", result.stdout, re.MULTILINE)
    if not match:
        errors.append(f"deployment target is missing for {path.name}")
        return None
    return match.group(1)


def _version_tuple(value):
    return tuple(int(part) for part in value.split("."))


def _check_dependencies(path, command_runner, errors):
    result = _run(
        command_runner,
        ["/usr/bin/otool", "-L", str(path)],
        errors,
        f"dependency check for {path.name}",
        timeout=8,
    )
    if result is None:
        return
    if result.returncode != 0:
        errors.append(f"dependency check failed for {path.name}: {_command_output(result) or 'no diagnostic'}")
        return
    dependencies = []
    architecture_names = "|".join(re.escape(value) for value in SUPPORTED_ARCHITECTURES)
    header = re.compile(
        rf"^{re.escape(str(path))}(?: \(architecture (?:{architecture_names})\))?:$"
    )
    for line in result.stdout.splitlines():
        if not line.strip() or header.fullmatch(line):
            continue
        if not line[0].isspace():
            errors.append(f"unexpected otool dependency output for {path.name}: {line}")
            continue
        dependencies.append(line.strip().split(" (", 1)[0])
    unexpected = sorted(
        dependency
        for dependency in dependencies
        if not dependency.startswith(ALLOWED_DYLIB_PREFIXES)
    )
    for dependency in unexpected:
        errors.append(f"unexpected dynamic dependency for {path.name}: {dependency}")


def _check_signature(path, command_runner, errors, deep=False):
    command = ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2"]
    if deep:
        command.append("--deep")
    command.append(str(path))
    result = _run(
        command_runner,
        command,
        errors,
        f"signature check for {path.name}",
        timeout=20,
    )
    if result is not None and result.returncode != 0:
        errors.append(f"signature check failed for {path.name}: {_command_output(result) or 'no diagnostic'}")


def _validate_info_plist(bundle, expected_version, errors):
    info_path = bundle / "Contents" / "Info.plist"
    if not info_path.is_file() or info_path.is_symlink():
        errors.append("missing trusted Contents/Info.plist")
        return
    try:
        with info_path.open("rb") as handle:
            metadata = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        errors.append(f"invalid Contents/Info.plist: {error}")
        return

    expected = {
        "CFBundleExecutable": APP_EXECUTABLE_NAME,
        "CFBundleIdentifier": BUNDLE_IDENTIFIER,
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": "AppIcon.icns",
        "CFBundleShortVersionString": expected_version,
        "CFBundleVersion": expected_version,
        "LSMinimumSystemVersion": MINIMUM_MACOS,
    }
    for key, expected_value in expected.items():
        actual = metadata.get(key)
        if actual != expected_value:
            errors.append(f"unexpected {key}: {actual!r} (expected {expected_value!r})")


def _validate_resources(bundle, errors):
    resources = bundle / "Contents" / "Resources"
    required = [
        resources / "AppIcon.icns",
        resources / "AppMetadata.json",
        resources / "Localizable.xcstrings",
        resources / "THIRD_PARTY_NOTICES.md",
    ]
    required.extend(
        resources / "ThirdPartyLicenses" / license_name
        for license_name in EXPECTED_LICENSES
    )
    required.extend(
        resources / f"{locale}.lproj" / "Localizable.strings"
        for locale in EXPECTED_LOCALES
    )
    for path in required:
        if not path.is_file() or path.is_symlink():
            errors.append(f"missing trusted bundle resource: {_relative(path, bundle)}")
            continue
        try:
            if path.stat().st_size == 0:
                errors.append(f"empty bundle resource: {_relative(path, bundle)}")
        except OSError as error:
            errors.append(f"bundle resource is unreadable: {_relative(path, bundle)}: {error}")


def _validate_layout(bundle, entries, errors):
    if bundle.name != APP_BUNDLE_NAME:
        errors.append(f"app bundle must be named {APP_BUNDLE_NAME}")
    if bundle.is_symlink():
        errors.append("app bundle root must not be a symbolic link")
    if not bundle.is_dir():
        errors.append(f"app bundle is not a directory: {bundle}")
        return

    for path in entries:
        if path.is_symlink():
            try:
                target = os.readlink(path)
            except OSError:
                target = "unreadable target"
            errors.append(f"symbolic link is not allowed: {_relative(path, bundle)} -> {target}")

    inode_paths = {}
    for path in entries:
        try:
            metadata = path.lstat()
        except OSError as error:
            errors.append(f"bundle entry is unreadable: {_relative(path, bundle)}: {error}")
            continue
        if stat.S_ISREG(metadata.st_mode):
            inode_paths.setdefault((metadata.st_dev, metadata.st_ino), []).append(path)
    for aliases in sorted(inode_paths.values(), key=lambda paths: _relative(paths[0], bundle)):
        if len(aliases) > 1:
            names = ", ".join(sorted(_relative(path, bundle) for path in aliases))
            errors.append(f"duplicate physical inode appears at multiple bundle paths: {names}")

    helpers = bundle / "Contents" / "Helpers"
    helper_children = sorted(path.name for path in helpers.iterdir()) if helpers.is_dir() else []
    if helper_children != sorted(EXPECTED_HELPERS):
        errors.append(
            f"Contents/Helpers must contain exactly {sorted(EXPECTED_HELPERS)}; found {helper_children}"
        )
    if helpers.is_dir():
        for path in entries:
            try:
                relative = path.relative_to(helpers)
            except ValueError:
                continue
            if len(relative.parts) > 1:
                errors.append(f"nested Helpers content is not allowed: {_relative(path, bundle)}")

    for helper in EXPECTED_HELPERS:
        matches = sorted(
            (path for path in entries if path.name.casefold() == helper.casefold()),
            key=lambda path: _relative(path, bundle),
        )
        canonical = helpers / helper
        if len(matches) != 1 or matches[0] != canonical:
            locations = [_relative(path, bundle) for path in matches]
            errors.append(f"duplicate or misplaced helper {helper}: found {locations}")
        for path in matches:
            if path != canonical:
                errors.append(f"helper {helper} exists outside Contents/Helpers: {_relative(path, bundle)}")

    macos = bundle / "Contents" / "MacOS"
    macos_files = sorted(path.name for path in macos.iterdir()) if macos.is_dir() else []
    if macos_files != [APP_EXECUTABLE_NAME]:
        errors.append(f"Contents/MacOS must contain exactly {APP_EXECUTABLE_NAME!r}; found {macos_files}")

    expected_executables = {
        macos / APP_EXECUTABLE_NAME,
        *(helpers / helper for helper in EXPECTED_HELPERS),
    }
    for path in entries:
        try:
            mode = path.lstat().st_mode
        except OSError:
            continue
        if stat.S_ISREG(mode) and mode & 0o111 and path not in expected_executables:
            errors.append(f"unexpected executable outside canonical code paths: {_relative(path, bundle)}")

    for path in sorted(entries, key=lambda item: _relative(item, bundle)):
        relative_parts = {part.casefold() for part in path.relative_to(bundle).parts}
        forbidden = sorted(relative_parts & FORBIDDEN_STATE_NAMES)
        if forbidden:
            errors.append(
                f"writable app-state path is not allowed inside the bundle: {_relative(path, bundle)}"
            )


def _execute_helper(path, helper, command_runner, errors):
    arguments = {
        "yt-dlp_macos": ["--version"],
        "ffmpeg": ["-version"],
        "ffprobe": ["-version"],
        "qjs": ["--help"],
    }[helper]
    environment = {
        "HOME": "/var/empty",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONNOUSERSITE": "1",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    }
    result = _run(
        command_runner,
        [str(path), *arguments],
        errors,
        f"version check for {helper}",
        cwd=str(path.parent),
        env=environment,
        timeout=30,
    )
    if result is None:
        return ""
    accepted_codes = (0, 1) if helper == "qjs" else (0,)
    output = _command_output(result)
    if result.returncode not in accepted_codes:
        errors.append(f"version check failed for {helper} with exit {result.returncode}: {output or 'no diagnostic'}")
        return ""

    patterns = {
        "yt-dlp_macos": r"(?m)^(\d{4}\.\d{2}\.\d{2}(?:[^\s]*)?)\s*$",
        "ffmpeg": r"(?m)^ffmpeg version\s+(\S+)",
        "ffprobe": r"(?m)^ffprobe version\s+(\S+)",
        "qjs": r"QuickJS version\s+(\S+)",
    }
    match = re.search(patterns[helper], output)
    if not match:
        errors.append(f"version output for {helper} is missing its expected marker")
        return ""
    if helper in {"ffmpeg", "ffprobe"} and "--enable-nonfree" in output:
        errors.append(f"{helper} reports --enable-nonfree and is not releasable")
    return match.group(1)


def _normalize_architectures(architectures):
    normalized = []
    for architecture in architectures:
        values = SUPPORTED_ARCHITECTURES if architecture == "universal" else architecture.split(",")
        for value in values:
            value = value.strip()
            if not value:
                continue
            if value not in SUPPORTED_ARCHITECTURES:
                raise ValueError(f"unsupported architecture: {value}")
            if value not in normalized:
                normalized.append(value)
    if not normalized:
        raise ValueError("at least one architecture is required")
    return tuple(architecture for architecture in SUPPORTED_ARCHITECTURES if architecture in normalized)


def verify_bundle(
    bundle,
    expected_version="2.0.0",
    expected_architectures=("arm64",),
    command_runner=None,
):
    """Return deterministic diagnostics while executing only trusted bundle code."""
    bundle = Path(bundle).absolute()
    command_runner = command_runner or _default_command_runner
    architectures = _normalize_architectures(expected_architectures)
    errors = []
    executable_architectures = {}
    helper_versions = {}

    entries = _bundle_entries(bundle)
    _validate_layout(bundle, entries, errors)
    _validate_info_plist(bundle, expected_version, errors)
    _validate_resources(bundle, errors)

    helpers = bundle / "Contents" / "Helpers"
    app_executable = bundle / "Contents" / "MacOS" / APP_EXECUTABLE_NAME
    code_paths = [(APP_EXECUTABLE_NAME, app_executable)] + [
        (helper, helpers / helper) for helper in EXPECTED_HELPERS
    ]
    trusted_code = {}
    for name, path in code_paths:
        if not _trusted_regular_file(path, bundle):
            errors.append(f"trusted regular executable is missing for {name}: {_relative(path, bundle)}")
            continue
        try:
            mode = path.stat().st_mode
        except OSError as error:
            errors.append(f"executable is unreadable for {name}: {error}")
            continue
        if not mode & 0o111:
            errors.append(f"executable permission is missing for {name}")
            continue
        trusted_code[name] = path

    for name, path in code_paths:
        if name not in trusted_code:
            continue
        actual_architectures = _architectures(path, command_runner, errors)
        executable_architectures[name] = actual_architectures
        missing = [architecture for architecture in architectures if architecture not in actual_architectures]
        if missing:
            errors.append(f"{name} is missing required architecture slices: {missing}")
        target = _deployment_target(path, command_runner, errors)
        if target is not None:
            if name == APP_EXECUTABLE_NAME and _version_tuple(target) != _version_tuple(MINIMUM_MACOS):
                errors.append(
                    f"{APP_EXECUTABLE_NAME} deployment target is {target}; expected {MINIMUM_MACOS}"
                )
            if name != APP_EXECUTABLE_NAME and _version_tuple(target) > _version_tuple(MINIMUM_MACOS):
                errors.append(f"{name} requires macOS {target}; expected {MINIMUM_MACOS} or earlier")
        _check_dependencies(path, command_runner, errors)

    for helper in EXPECTED_HELPERS:
        path = trusted_code.get(helper)
        if path is None:
            continue
        helper_versions[helper] = _execute_helper(path, helper, command_runner, errors)

    if (
        helper_versions.get("ffmpeg")
        and helper_versions.get("ffprobe")
        and helper_versions["ffmpeg"] != helper_versions["ffprobe"]
    ):
        errors.append(
            "FFmpeg and FFprobe versions do not match: "
            f"{helper_versions['ffmpeg']} != {helper_versions['ffprobe']}"
        )

    for helper in EXPECTED_HELPERS:
        path = trusted_code.get(helper)
        if path is not None:
            _check_signature(path, command_runner, errors)
    if APP_EXECUTABLE_NAME in trusted_code:
        _check_signature(app_executable, command_runner, errors)
    if bundle.is_dir() and not bundle.is_symlink():
        _check_signature(bundle, command_runner, errors, deep=True)

    return BundleVerificationReport(
        checked_path=str(bundle),
        expected_version=expected_version,
        architectures=architectures,
        executable_architectures=executable_architectures,
        helper_versions=helper_versions,
        errors=tuple(errors),
    )


def write_deterministic_zip(bundle, archive_path):
    """Archive a verified-style bundle with stable ordering, metadata, and modes."""
    bundle = Path(bundle).absolute()
    archive_path = Path(archive_path).absolute()
    if not bundle.is_dir() or bundle.is_symlink():
        raise ValueError(f"bundle is not a trusted directory: {bundle}")
    entries = [bundle, *_bundle_entries(bundle)]
    symlinks = [path for path in entries if path.is_symlink()]
    if symlinks:
        names = ", ".join(_relative(path, bundle) for path in symlinks)
        raise ValueError(f"cannot archive symbolic links: {names}")

    archive_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = archive_path.with_name(archive_path.name + ".tmp")
    temporary_path.unlink(missing_ok=True)
    try:
        with zipfile.ZipFile(
            temporary_path,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            for path in sorted(entries, key=lambda item: (item != bundle, _relative(item, bundle))):
                relative = Path(bundle.name) if path == bundle else Path(bundle.name) / path.relative_to(bundle)
                is_directory = path.is_dir()
                member_name = relative.as_posix() + ("/" if is_directory else "")
                info = zipfile.ZipInfo(member_name, date_time=(2000, 1, 1, 0, 0, 0))
                info.create_system = 3
                permissions = stat.S_IMODE(path.stat().st_mode)
                file_type = stat.S_IFDIR if is_directory else stat.S_IFREG
                info.external_attr = (file_type | permissions) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                payload = b"" if is_directory else path.read_bytes()
                archive.writestr(info, payload, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        temporary_path.replace(archive_path)
    finally:
        temporary_path.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--expected-version", default="2.0.0")
    parser.add_argument(
        "--architectures",
        action="append",
        default=[],
        help="arm64, x86_64, universal, or a comma-separated set (default: arm64)",
    )
    parser.add_argument("--report", type=Path, help="also write the JSON report to this path")
    parser.add_argument("--archive", type=Path, help="write a deterministic ZIP only when verification passes")
    options = parser.parse_args(argv)
    try:
        architectures = _normalize_architectures(options.architectures or ["arm64"])
    except ValueError as error:
        parser.error(str(error))
    report = verify_bundle(
        options.app,
        expected_version=options.expected_version,
        expected_architectures=architectures,
    )
    output = report.to_json()
    sys.stdout.write(output)
    if options.report:
        options.report.parent.mkdir(parents=True, exist_ok=True)
        options.report.write_text(output, encoding="utf-8")
    if report.ok and options.archive:
        write_deterministic_zip(options.app, options.archive)
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
