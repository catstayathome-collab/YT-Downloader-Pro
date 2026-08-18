#!/usr/bin/env python3
"""Inspect the static layout of a Windows portable package or ZIP."""

import argparse
import json
import tempfile
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath

try:
    from fetch_windows_tools import validate_amd64_pe
except ImportError:
    from scripts.fetch_windows_tools import validate_amd64_pe


PACKAGE_NAME = "YT-Downloader-Pro-v1.8.7-Windows-x64"
ARCHIVE_NAME = f"{PACKAGE_NAME}.zip"
APP_EXE = "YT Downloader Pro.exe"
EXPECTED_HELPERS = ("ffmpeg.exe", "ffprobe.exe", "deno.exe")
EXPECTED_DOCUMENTS = ("THIRD_PARTY_NOTICES.txt", "README-Windows.txt")
EXPECTED_LICENSES = (
    "Deno-MIT.txt",
    "FFmpeg-LGPL-2.1.txt",
    "LAME-LGPL-2.0.txt",
    "QuickJS-MIT.txt",
)
EXPECTED_EXECUTABLES = {
    APP_EXE,
    *(f"Helpers/{helper}" for helper in EXPECTED_HELPERS),
}


@dataclass(frozen=True)
class PackageCheckResult:
    checked_path: str
    errors: tuple[str, ...]

    @property
    def ok(self):
        return not self.errors

    def as_dict(self):
        result = asdict(self)
        result["ok"] = self.ok
        return result


def _check_pe(path, errors):
    try:
        validate_amd64_pe(path)
    except ValueError as error:
        errors.append(str(error))


def _check_directory(package_root, checked_path=None, check_root_name=True):
    package_root = Path(package_root)
    errors = []
    if check_root_name and package_root.name != PACKAGE_NAME:
        errors.append(f"package root must be named {PACKAGE_NAME}")
    if not package_root.is_dir():
        errors.append(f"package root is not a directory: {package_root}")
        return PackageCheckResult(str(checked_path or package_root), tuple(errors))

    top_level_exes = sorted(
        path.name for path in package_root.iterdir() if path.is_file() and path.suffix.casefold() == ".exe"
    )
    if top_level_exes != [APP_EXE]:
        errors.append(f"package root must contain exactly one {APP_EXE}; found {top_level_exes}")
    else:
        _check_pe(package_root / APP_EXE, errors)

    helper_root = package_root / "Helpers"
    canonical_paths = {name: helper_root / name for name in EXPECTED_HELPERS}
    helper_files = (
        sorted(path.name for path in helper_root.iterdir() if path.is_file())
        if helper_root.is_dir()
        else []
    )
    if helper_files != sorted(EXPECTED_HELPERS):
        errors.append(
            f"Helpers must contain exactly {sorted(EXPECTED_HELPERS)}; found {helper_files}"
        )
    all_files = [path for path in package_root.rglob("*") if path.is_file()]
    executable_paths = {
        path.relative_to(package_root).as_posix()
        for path in all_files
        if path.suffix.casefold() == ".exe"
    }
    unexpected_executables = sorted(executable_paths - EXPECTED_EXECUTABLES)
    missing_executables = sorted(EXPECTED_EXECUTABLES - executable_paths)
    for relative_path in unexpected_executables:
        errors.append(f"unexpected executable: {relative_path}")
    if missing_executables:
        errors.append(f"missing required executables: {missing_executables}")

    if helper_root.is_dir():
        for path in sorted(helper_root.rglob("*")):
            relative_to_helpers = path.relative_to(helper_root)
            if path.is_dir() or len(relative_to_helpers.parts) != 1:
                relative_path = path.relative_to(package_root).as_posix()
                errors.append(f"nested Helpers content is not allowed: {relative_path}")

    for helper, canonical_path in canonical_paths.items():
        if not canonical_path.is_file():
            errors.append(f"missing canonical helper: Helpers/{helper}")
        else:
            _check_pe(canonical_path, errors)
        matches = [path for path in all_files if path.name.casefold() == helper.casefold()]
        if len(matches) > 1:
            errors.append(f"duplicate helper {helper}: found {len(matches)} copies")

    for document in EXPECTED_DOCUMENTS:
        if not (package_root / document).is_file():
            errors.append(f"missing package document: {document}")

    license_root = package_root / "tools" / "licenses"
    packaged_licenses = (
        sorted(path.name for path in license_root.iterdir() if path.is_file())
        if license_root.is_dir()
        else []
    )
    if packaged_licenses != sorted(EXPECTED_LICENSES):
        errors.append(
            f"license directory must contain {sorted(EXPECTED_LICENSES)}; "
            f"found {packaged_licenses}"
        )

    return PackageCheckResult(str(checked_path or package_root), tuple(errors))


def _safe_archive_name(name):
    normalized = name.replace("\\", "/")
    path = PurePosixPath(normalized)
    if (
        not normalized
        or normalized.startswith("/")
        or path.is_absolute()
        or any(part in {"", ".", ".."} for part in path.parts)
        or any(":" in part for part in path.parts)
    ):
        raise ValueError(f"unsafe ZIP member: {name}")
    return path


def _check_archive(archive_path):
    archive_path = Path(archive_path)
    errors = []
    if archive_path.name != ARCHIVE_NAME:
        errors.append(f"Windows archive must be named {ARCHIVE_NAME}")
    try:
        with zipfile.ZipFile(archive_path) as archive:
            safe_entries = []
            seen_entries = set()
            for info in archive.infolist():
                try:
                    safe_path = _safe_archive_name(info.filename)
                    normalized = safe_path.as_posix().casefold()
                    if normalized in seen_entries:
                        errors.append(f"duplicate ZIP member: {info.filename}")
                    seen_entries.add(normalized)
                    safe_entries.append((info, safe_path))
                except ValueError as error:
                    errors.append(str(error))
            top_levels = {path.parts[0] for _info, path in safe_entries if path.parts}
            if top_levels != {PACKAGE_NAME}:
                errors.append(
                    f"archive must contain one {PACKAGE_NAME} top-level directory; found {sorted(top_levels)}"
                )
            if errors:
                return PackageCheckResult(str(archive_path), tuple(errors))

            with tempfile.TemporaryDirectory(prefix="windows-package-check-") as tmpdir:
                extraction_root = Path(tmpdir)
                for info, safe_path in safe_entries:
                    if info.is_dir():
                        continue
                    destination = extraction_root.joinpath(*safe_path.parts)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(info, "r") as source, destination.open("wb") as output:
                        output.write(source.read())
                checked = _check_directory(
                    extraction_root / PACKAGE_NAME,
                    checked_path=archive_path,
                    check_root_name=False,
                )
                errors.extend(checked.errors)
    except (OSError, zipfile.BadZipFile) as error:
        errors.append(f"invalid Windows package archive: {error}")
    return PackageCheckResult(str(archive_path), tuple(errors))


def check_package(path):
    """Return static package diagnostics without executing Windows binaries."""
    path = Path(path)
    if path.suffix.casefold() == ".zip":
        return _check_archive(path)
    return _check_directory(path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    options = parser.parse_args(argv)
    result = check_package(options.package)
    print(json.dumps(result.as_dict(), indent=2, sort_keys=True))
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
