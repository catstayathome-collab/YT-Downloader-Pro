#!/usr/bin/env python3
"""Fail-closed validation for a packaged YT Downloader Pro 2 app bundle."""

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import zipfile
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path


APP_BUNDLE_NAME = "YT Downloader Pro 2.app"
APP_EXECUTABLE_NAME = "YT Downloader Pro 2"
BUNDLE_IDENTIFIER = "com.tachouweng.ytdownloaderpro2"
MINIMUM_MACOS = "13.0"
EXPECTED_HELPERS = ("yt-dlp_macos", "ffmpeg", "ffprobe", "qjs")
EXPECTED_LOCALES = ("en", "ja", "zh-Hant")
EXPECTED_LICENSES = (
    "FFmpeg-LGPL-2.1.txt",
    "GPL-3.0-or-later.txt",
    "LAME-LGPL-2.0.txt",
    "QuickJS-MIT.txt",
    "yt-dlp-THIRD_PARTY_LICENSES.txt",
    "yt-dlp-Unlicense.txt",
)
SBOM_PACKAGE_TO_HELPERS = {
    "yt-dlp macOS standalone": ("yt-dlp_macos",),
    "FFmpeg": ("ffmpeg", "ffprobe"),
    "LAME": (),
    "QuickJS": ("qjs",),
}
SBOM_PACKAGE_DETAILS = {
    "yt-dlp macOS standalone": {
        "id": "SPDXRef-Package-yt-dlp",
        "license": "GPL-3.0-or-later",
        "licenses": (
            "GPL-3.0-or-later.txt",
            "yt-dlp-Unlicense.txt",
            "yt-dlp-THIRD_PARTY_LICENSES.txt",
        ),
    },
    "FFmpeg": {
        "id": "SPDXRef-Package-ffmpeg",
        "license": "LGPL-2.1-or-later",
        "licenses": ("FFmpeg-LGPL-2.1.txt",),
    },
    "LAME": {
        "id": "SPDXRef-Package-lame",
        "license": "LGPL-2.0-or-later",
        "licenses": ("LAME-LGPL-2.0.txt",),
    },
    "QuickJS": {
        "id": "SPDXRef-Package-quickjs",
        "license": "MIT",
        "licenses": ("QuickJS-MIT.txt",),
    },
}
SBOM_HELPER_PACKAGES = {
    "yt-dlp_macos": "yt-dlp macOS standalone",
    "ffmpeg": "FFmpeg",
    "ffprobe": "FFmpeg",
    "qjs": "QuickJS",
}


def _sbom_helper_id(helper):
    return "SPDXRef-File-" + helper.replace("_", "-")
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


def _valid_rfc3339_utc(value):
    if not isinstance(value, str) or not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value
    ):
        return False
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == value


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


def _trusted_external_regular_file(path):
    try:
        return stat.S_ISREG(path.lstat().st_mode) and not path.is_symlink()
    except OSError:
        return False


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
    if result is None:
        return False
    if result.returncode != 0:
        errors.append(f"signature check failed for {path.name}: {_command_output(result) or 'no diagnostic'}")
        return False
    return True


def _check_developer_identity(path, expected_team_id, command_runner, errors):
    result = _run(
        command_runner,
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(path)],
        errors,
        f"Developer ID identity check for {path.name}",
        timeout=20,
    )
    if result is None:
        return False
    output = _command_output(result)
    if result.returncode != 0:
        errors.append(
            f"Developer ID identity check failed for {path.name}: {output or 'no diagnostic'}"
        )
        return False
    authority = re.search(r"(?m)^Authority=(.+)$", output)
    team_identifier = re.search(r"(?m)^TeamIdentifier=([A-Z0-9]+)$", output)
    valid = True
    if authority is None or not authority.group(1).startswith("Developer ID Application:"):
        errors.append(f"unexpected signing Authority for {path.name}: {authority.group(1) if authority else 'missing'}")
        valid = False
    actual_team_id = team_identifier.group(1) if team_identifier else "missing"
    if actual_team_id != expected_team_id:
        errors.append(
            f"unexpected TeamIdentifier for {path.name}: {actual_team_id} "
            f"(expected {expected_team_id})"
        )
        valid = False
    return valid


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
        resources / "SBOM.spdx.json",
        resources / "SOURCE_AVAILABILITY.md",
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


def _load_canonical_inventory(inventory_path, errors):
    inventory_path = Path(inventory_path).absolute()
    if not _trusted_external_regular_file(inventory_path):
        errors.append(f"canonical inventory is not a trusted regular file: {inventory_path}")
        return {}
    try:
        if inventory_path.stat().st_size > 1024 * 1024:
            errors.append("canonical inventory exceeds the 1 MiB validation limit")
            return {}
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        errors.append(f"invalid canonical inventory: {error}")
        return {}
    if not isinstance(inventory, dict):
        errors.append("canonical inventory must contain one JSON object")
        return {}
    if inventory.get("schemaVersion") != 1 or inventory.get("platform") != "macos":
        errors.append("canonical inventory must use schemaVersion 1 and platform macos")
        return {}
    components = inventory.get("components")
    if not isinstance(components, list):
        errors.append("canonical inventory components must be an array")
        return {}

    source_helper_root = inventory_path.parent
    source_license_root = source_helper_root / "licenses"
    component_map = {}
    helper_map = {}
    license_map = {}
    for component in components:
        if not isinstance(component, dict) or not isinstance(component.get("name"), str):
            errors.append("canonical inventory contains an invalid component")
            continue
        name = component["name"]
        if name in component_map:
            errors.append(f"canonical inventory repeats component: {name}")
            continue
        if name not in SBOM_PACKAGE_DETAILS:
            errors.append(f"canonical inventory contains unexpected component: {name}")
            continue
        required_text = (
            "id",
            "version",
            "supplier",
            "downloadLocation",
            "sourceInfo",
            "licenseConcluded",
            "licenseDeclared",
        )
        for key in required_text:
            if not isinstance(component.get(key), str) or not component[key]:
                errors.append(f"canonical inventory component {name} is missing {key}")
        if component.get("licenseConcluded") != SBOM_PACKAGE_DETAILS[name]["license"]:
            errors.append(f"canonical inventory has unexpected licenseConcluded for {name}")
        if component.get("licenseDeclared") != SBOM_PACKAGE_DETAILS[name]["license"]:
            errors.append(f"canonical inventory has unexpected licenseDeclared for {name}")

        helpers = component.get("helpers")
        if not isinstance(helpers, list):
            errors.append(f"canonical inventory helpers must be an array for {name}")
            helpers = []
        for helper in helpers:
            if not isinstance(helper, dict):
                errors.append(f"canonical inventory has invalid helper for {name}")
                continue
            helper_name = helper.get("name")
            helper_sha256 = helper.get("sha256")
            architectures = helper.get("architectures")
            if helper_name not in EXPECTED_HELPERS or helper_name in helper_map:
                errors.append(f"canonical inventory has invalid or duplicate helper: {helper_name!r}")
                continue
            if not isinstance(helper_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", helper_sha256):
                errors.append(f"canonical inventory has invalid SHA-256 for {helper_name}")
                continue
            if not isinstance(architectures, list) or not architectures or any(
                value not in SUPPORTED_ARCHITECTURES for value in architectures
            ) or len(set(architectures)) != len(architectures):
                errors.append(f"canonical inventory has invalid architectures for {helper_name}")
                continue
            source_path = source_helper_root / helper_name
            if not _trusted_external_regular_file(source_path):
                errors.append(f"canonical source helper is missing: {helper_name}")
                continue
            actual_source_sha256 = hashlib.sha256(source_path.read_bytes()).hexdigest()
            if actual_source_sha256 != helper_sha256:
                errors.append(
                    f"canonical source helper SHA-256 mismatch for {helper_name}: "
                    f"{actual_source_sha256} != {helper_sha256}"
                )
            helper_map[helper_name] = {
                "component": name,
                "sha256": helper_sha256,
                "architectures": tuple(architectures),
            }

        license_files = component.get("licenseFiles")
        if not isinstance(license_files, list):
            errors.append(f"canonical inventory licenseFiles must be an array for {name}")
            license_files = []
        for license_file in license_files:
            if not isinstance(license_file, dict):
                errors.append(f"canonical inventory has invalid license file for {name}")
                continue
            license_name = license_file.get("name")
            license_sha256 = license_file.get("sha256")
            if license_name not in EXPECTED_LICENSES or license_name in license_map:
                errors.append(
                    f"canonical inventory has invalid or duplicate license file: {license_name!r}"
                )
                continue
            if not isinstance(license_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", license_sha256):
                errors.append(f"canonical inventory has invalid SHA-256 for {license_name}")
                continue
            source_path = source_license_root / license_name
            if not _trusted_external_regular_file(source_path):
                errors.append(f"canonical license file is missing: {license_name}")
                continue
            actual_source_sha256 = hashlib.sha256(source_path.read_bytes()).hexdigest()
            if actual_source_sha256 != license_sha256:
                errors.append(
                    f"canonical license SHA-256 mismatch for {license_name}: "
                    f"{actual_source_sha256} != {license_sha256}"
                )
            license_map[license_name] = {
                "component": name,
                "sha256": license_sha256,
            }
        component_map[name] = component

    if set(component_map) != set(SBOM_PACKAGE_DETAILS):
        errors.append(
            "canonical inventory component set is invalid: "
            f"{sorted(component_map)}"
        )
    if set(helper_map) != set(EXPECTED_HELPERS):
        errors.append(f"canonical inventory helper set is invalid: {sorted(helper_map)}")
    if set(license_map) != set(EXPECTED_LICENSES):
        errors.append(f"canonical inventory license set is invalid: {sorted(license_map)}")
    return {
        "components": component_map,
        "helpers": helper_map,
        "licenses": license_map,
    }


def _load_and_validate_sbom(bundle, expected_version, canonical_inventory, errors):
    sbom_path = bundle / "Contents" / "Resources" / "SBOM.spdx.json"
    if not _trusted_regular_file(sbom_path, bundle):
        return {}
    try:
        size = sbom_path.stat().st_size
        if size > 2 * 1024 * 1024:
            errors.append("SBOM.spdx.json exceeds the 2 MiB validation limit")
            return {}
        sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        errors.append(f"invalid SBOM.spdx.json: {error}")
        return {}
    if not isinstance(sbom, dict):
        errors.append("SBOM.spdx.json must contain one JSON object")
        return {}

    expected_metadata = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"YT Downloader Pro 2 {expected_version} macOS SBOM",
    }
    for key, expected in expected_metadata.items():
        if sbom.get(key) != expected:
            errors.append(f"unexpected SBOM {key}: {sbom.get(key)!r} (expected {expected!r})")
    namespace = sbom.get("documentNamespace")
    namespace_prefix = (
        "https://github.com/catstayathome-collab/YT-Downloader-Pro/"
        f"spdx/macos/{expected_version}/"
    )
    if not isinstance(namespace, str) or not namespace.startswith(namespace_prefix):
        errors.append(f"SBOM documentNamespace must start with {namespace_prefix}")
    creation_info = sbom.get("creationInfo")
    if not isinstance(creation_info, dict):
        errors.append("SBOM creationInfo must be an object")
    else:
        if not _valid_rfc3339_utc(creation_info.get("created")):
            errors.append("SBOM creationInfo.created must be an RFC3339 UTC timestamp")
        creators = creation_info.get("creators")
        if not isinstance(creators, list) or not creators or not all(
            isinstance(value, str) and value for value in creators
        ):
            errors.append("SBOM creationInfo.creators must be a non-empty string array")

    expected_file_names = {
        f"./Contents/Helpers/{helper}" for helper in EXPECTED_HELPERS
    }
    files = sbom.get("files")
    if not isinstance(files, list):
        errors.append("SBOM files must be an array")
        files = []
    sbom_files = {}
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("fileName"), str):
            errors.append("SBOM files contains an invalid entry")
            continue
        file_name = item["fileName"]
        if file_name in sbom_files:
            errors.append(f"SBOM repeats helper file: {file_name}")
            continue
        sbom_files[file_name] = item
    if set(sbom_files) != expected_file_names:
        missing = sorted(expected_file_names - set(sbom_files))
        extra = sorted(set(sbom_files) - expected_file_names)
        errors.append(f"SBOM helper file set is invalid; missing {missing}; extra {extra}")

    helpers_root = bundle / "Contents" / "Helpers"
    file_ids = set()
    for helper in EXPECTED_HELPERS:
        file_name = f"./Contents/Helpers/{helper}"
        item = sbom_files.get(file_name)
        helper_path = helpers_root / helper
        if item is None or not _trusted_regular_file(helper_path, bundle):
            continue
        expected_file_id = _sbom_helper_id(helper)
        if item.get("SPDXID") != expected_file_id:
            errors.append(
                f"unexpected SBOM SPDXID for {helper}: {item.get('SPDXID')!r}"
            )
        file_ids.add(item.get("SPDXID"))
        expected_file_license = SBOM_PACKAGE_DETAILS[SBOM_HELPER_PACKAGES[helper]]["license"]
        for key, expected in {
            "licenseConcluded": expected_file_license,
            "licenseInfoInFiles": ["NOASSERTION"],
            "copyrightText": "NOASSERTION",
        }.items():
            if item.get(key) != expected:
                errors.append(
                    f"unexpected SBOM {key} for {helper}: {item.get(key)!r} "
                    f"(expected {expected!r})"
                )
        comment = item.get("comment")
        comment_match = re.fullmatch(
            r"Architectures: ((?:arm64|x86_64)(?:, (?:arm64|x86_64))*); "
            r"Canonical source SHA-256: ([0-9a-f]{64})",
            comment if isinstance(comment, str) else "",
        )
        if comment_match is None:
            errors.append(f"SBOM canonical source comment is invalid for {helper}")
        else:
            canonical_helper = canonical_inventory.get("helpers", {}).get(helper, {})
            comment_architectures = tuple(comment_match.group(1).split(", "))
            if comment_architectures != canonical_helper.get("architectures"):
                errors.append(f"SBOM canonical architectures mismatch for {helper}")
            if comment_match.group(2) != canonical_helper.get("sha256"):
                errors.append(f"SBOM canonical inventory SHA-256 mismatch for {helper}")
        checksums = item.get("checksums")
        expected_checksum = None
        if isinstance(checksums, list):
            sha256_entries = [
                value
                for value in checksums
                if isinstance(value, dict) and value.get("algorithm") == "SHA256"
            ]
            if len(sha256_entries) == 1:
                expected_checksum = sha256_entries[0].get("checksumValue")
        if not isinstance(expected_checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_checksum):
            errors.append(f"SBOM has no valid SHA-256 for {helper}")
            continue
        actual_checksum = hashlib.sha256(helper_path.read_bytes()).hexdigest()
        if actual_checksum != expected_checksum:
            errors.append(
                f"SBOM SHA-256 mismatch for {helper}: {actual_checksum} != {expected_checksum}"
            )

    packages = sbom.get("packages")
    if not isinstance(packages, list):
        errors.append("SBOM packages must be an array")
        return {}
    package_versions = {}
    package_ids = set()
    expected_package_names = {"YT Downloader Pro 2", *SBOM_PACKAGE_TO_HELPERS}
    found_package_names = set()
    for package in packages:
        if not isinstance(package, dict):
            errors.append("SBOM packages contains an invalid entry")
            continue
        name = package.get("name")
        version = package.get("versionInfo")
        if name not in expected_package_names:
            errors.append(f"unexpected SBOM package: {name!r}")
            continue
        if name in found_package_names:
            errors.append(f"SBOM repeats package: {name}")
            continue
        found_package_names.add(name)
        expected_id = (
            "SPDXRef-Package-YTDownloaderPro2"
            if name == "YT Downloader Pro 2"
            else SBOM_PACKAGE_DETAILS[name]["id"]
        )
        package_id = package.get("SPDXID")
        if package_id != expected_id:
            errors.append(f"unexpected SBOM SPDXID for {name}: {package_id!r}")
        package_ids.add(package_id)
        expected_license = (
            "NOASSERTION" if name == "YT Downloader Pro 2" else SBOM_PACKAGE_DETAILS[name]["license"]
        )
        required_values = {
            "filesAnalyzed": False,
            "licenseConcluded": expected_license,
            "licenseDeclared": expected_license,
            "copyrightText": "NOASSERTION",
        }
        for key, expected in required_values.items():
            if package.get(key) != expected:
                errors.append(
                    f"unexpected SBOM {key} for {name}: {package.get(key)!r} "
                    f"(expected {expected!r})"
                )
        download_location = package.get("downloadLocation")
        valid_location = (
            download_location == "NOASSERTION"
            if name == "YT Downloader Pro 2"
            else isinstance(download_location, str) and download_location.startswith("https://")
        )
        if not valid_location:
            errors.append(f"unexpected SBOM downloadLocation for {name}: {download_location!r}")
        if name == "YT Downloader Pro 2":
            if version != expected_version:
                errors.append(
                    f"SBOM app package version mismatch: {version!r} != {expected_version!r}"
                )
        else:
            canonical_component = canonical_inventory.get("components", {}).get(name, {})
            if version != canonical_component.get("version"):
                errors.append(
                    f"SBOM package version differs from canonical inventory for {name}: "
                    f"{version!r} != {canonical_component.get('version')!r}"
                )
            for key in ("supplier", "downloadLocation", "sourceInfo"):
                if package.get(key) != canonical_component.get(key):
                    errors.append(f"SBOM package {key} differs from canonical inventory for {name}")
            expected_attribution = []
            for license_name in SBOM_PACKAGE_DETAILS[name]["licenses"]:
                license_path = bundle / "Contents" / "Resources" / "ThirdPartyLicenses" / license_name
                if not _trusted_regular_file(license_path, bundle):
                    continue
                license_sha256 = hashlib.sha256(license_path.read_bytes()).hexdigest()
                canonical_license_sha256 = canonical_inventory.get("licenses", {}).get(
                    license_name, {}
                ).get("sha256")
                if license_sha256 != canonical_license_sha256:
                    errors.append(
                        f"canonical inventory SHA-256 mismatch for {license_name}: "
                        f"{license_sha256} != {canonical_license_sha256}"
                    )
                expected_attribution.append(
                    "Bundled license: Contents/Resources/ThirdPartyLicenses/"
                    f"{license_name} (SHA-256 {license_sha256})"
                )
            if package.get("attributionTexts") != expected_attribution:
                errors.append(f"unexpected SBOM attributionTexts for {name}")
        if name in SBOM_PACKAGE_TO_HELPERS:
            if name in package_versions:
                errors.append(f"SBOM repeats package: {name}")
            elif not isinstance(version, str) or not version:
                errors.append(f"SBOM package has no versionInfo: {name}")
            else:
                package_versions[name] = version
    missing_packages = sorted(expected_package_names - found_package_names)
    if missing_packages:
        errors.append(f"SBOM is missing required packages: {missing_packages}")

    all_ids = ["SPDXRef-DOCUMENT", *package_ids, *file_ids]
    if None in all_ids or len(set(all_ids)) != len(all_ids):
        errors.append("SBOM SPDXID values must be present and unique")

    expected_relationships = {
        (
            "SPDXRef-DOCUMENT",
            "DESCRIBES",
            "SPDXRef-Package-YTDownloaderPro2",
        ),
        *(
            (
                "SPDXRef-Package-YTDownloaderPro2",
                "DEPENDS_ON",
                SBOM_PACKAGE_DETAILS[name]["id"],
            )
            for name in SBOM_PACKAGE_TO_HELPERS
        ),
        *(
            (
                _sbom_helper_id(helper),
                "GENERATED_FROM",
                SBOM_PACKAGE_DETAILS[component]["id"],
            )
            for helper, component in SBOM_HELPER_PACKAGES.items()
        ),
        (
            _sbom_helper_id("ffmpeg"),
            "STATIC_LINK",
            "SPDXRef-Package-lame",
        ),
        (
            _sbom_helper_id("ffprobe"),
            "STATIC_LINK",
            "SPDXRef-Package-lame",
        ),
    }
    relationships = sbom.get("relationships")
    actual_relationships = set()
    if not isinstance(relationships, list):
        errors.append("SBOM relationships must be an array")
    else:
        for relationship in relationships:
            if not isinstance(relationship, dict):
                errors.append("SBOM relationships contains an invalid entry")
                continue
            relationship_tuple = (
                relationship.get("spdxElementId"),
                relationship.get("relationshipType"),
                relationship.get("relatedSpdxElement"),
            )
            if relationship_tuple in actual_relationships:
                errors.append(f"SBOM repeats relationship: {relationship_tuple}")
            actual_relationships.add(relationship_tuple)
    if actual_relationships != expected_relationships:
        missing = sorted(expected_relationships - actual_relationships)
        extra = sorted(actual_relationships - expected_relationships)
        errors.append(f"SBOM relationships are invalid; missing {missing}; extra {extra}")
    return package_versions


def _validate_sbom_versions(package_versions, helper_versions, errors):
    for package_name, helpers in SBOM_PACKAGE_TO_HELPERS.items():
        sbom_version = package_versions.get(package_name)
        if not sbom_version:
            continue
        for helper in helpers:
            actual_version = helper_versions.get(helper)
            if actual_version and actual_version != sbom_version:
                errors.append(
                    f"SBOM version mismatch for {helper}: {actual_version} != {sbom_version}"
                )


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
    signing_mode="internal",
    expected_team_id=None,
    inventory_path=None,
):
    """Return deterministic diagnostics while executing only trusted bundle code."""
    bundle = Path(bundle).absolute()
    command_runner = command_runner or _default_command_runner
    architectures = _normalize_architectures(expected_architectures)
    if signing_mode not in {"internal", "developer-id"}:
        raise ValueError(f"unsupported signing mode: {signing_mode}")
    if signing_mode == "developer-id":
        if not isinstance(expected_team_id, str) or not re.fullmatch(r"[A-Z0-9]{10}", expected_team_id):
            raise ValueError("developer-id verification requires a 10-character expected_team_id")
    elif expected_team_id is not None:
        raise ValueError("expected_team_id is only valid in developer-id mode")
    if inventory_path is None:
        raise ValueError("canonical inventory_path is required")
    errors = []
    executable_architectures = {}
    helper_versions = {}

    entries = _bundle_entries(bundle)
    _validate_layout(bundle, entries, errors)
    _validate_info_plist(bundle, expected_version, errors)
    _validate_resources(bundle, errors)
    canonical_inventory = _load_canonical_inventory(inventory_path, errors)
    sbom_package_versions = _load_and_validate_sbom(
        bundle, expected_version, canonical_inventory, errors
    )

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

    signatures_valid = True
    for helper in EXPECTED_HELPERS:
        path = trusted_code.get(helper)
        if path is not None:
            signatures_valid = _check_signature(path, command_runner, errors) and signatures_valid
    if APP_EXECUTABLE_NAME in trusted_code:
        signatures_valid = _check_signature(app_executable, command_runner, errors) and signatures_valid
    if bundle.is_dir() and not bundle.is_symlink():
        signatures_valid = _check_signature(bundle, command_runner, errors, deep=True) and signatures_valid

    if signatures_valid and signing_mode == "developer-id":
        identity_paths = [trusted_code[name] for name, _ in code_paths if name in trusted_code]
        identity_paths.append(bundle)
        for path in identity_paths:
            signatures_valid = (
                _check_developer_identity(
                    path, expected_team_id, command_runner, errors
                )
                and signatures_valid
            )

    if signatures_valid:
        for helper in EXPECTED_HELPERS:
            path = trusted_code.get(helper)
            if path is None:
                continue
            helper_versions[helper] = _execute_helper(path, helper, command_runner, errors)
    else:
        errors.append("helper execution skipped because code signature validation failed")

    if (
        helper_versions.get("ffmpeg")
        and helper_versions.get("ffprobe")
        and helper_versions["ffmpeg"] != helper_versions["ffprobe"]
    ):
        errors.append(
            "FFmpeg and FFprobe versions do not match: "
            f"{helper_versions['ffmpeg']} != {helper_versions['ffprobe']}"
        )
    _validate_sbom_versions(sbom_package_versions, helper_versions, errors)

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
        "--signing-mode",
        choices=("internal", "developer-id"),
        default="internal",
    )
    parser.add_argument("--expected-team-id")
    parser.add_argument("--inventory", required=True, type=Path)
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
    try:
        report = verify_bundle(
            options.app,
            expected_version=options.expected_version,
            expected_architectures=architectures,
            signing_mode=options.signing_mode,
            expected_team_id=options.expected_team_id,
            inventory_path=options.inventory,
        )
    except ValueError as error:
        parser.error(str(error))
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
