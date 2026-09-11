#!/usr/bin/env python3
"""Generate a deterministic SPDX 2.3 SBOM from the pinned macOS helper inventory."""

import argparse
import hashlib
import json
import re
import stat
from datetime import datetime
from pathlib import Path


EXPECTED_HELPERS = {"yt-dlp_macos", "ffmpeg", "ffprobe", "qjs"}
SUPPORTED_ARCHITECTURES = {"arm64", "x86_64"}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
RFC3339_UTC_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")


class InventoryError(ValueError):
    """Raised when pinned inventory does not match trusted local inputs."""


def _valid_rfc3339_utc(value):
    if not isinstance(value, str) or not RFC3339_UTC_PATTERN.fullmatch(value):
        return False
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == value


def _load_json(path, label):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InventoryError(f"could not read {label} {path}: {error}") from error
    if not isinstance(data, dict):
        raise InventoryError(f"{label} must contain one JSON object")
    return data


def _trusted_file(root, relative_name, label):
    if Path(relative_name).name != relative_name or relative_name in {".", ".."}:
        raise InventoryError(f"{label} must be one filename: {relative_name!r}")
    path = root / relative_name
    try:
        mode = path.lstat().st_mode
        resolved_root = root.resolve(strict=True)
        resolved_path = path.resolve(strict=True)
        resolved_path.relative_to(resolved_root)
    except (OSError, ValueError) as error:
        raise InventoryError(f"{label} is missing or escapes its root: {relative_name}: {error}") from error
    if not stat.S_ISREG(mode) or path.is_symlink():
        raise InventoryError(f"{label} must be a trusted regular file: {relative_name}")
    if path.stat().st_size == 0:
        raise InventoryError(f"{label} must not be empty: {relative_name}")
    return path


def _require_text(mapping, key, label):
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise InventoryError(f"{label}.{key} must be a non-empty string")
    return value.strip()


def _spdx_id(value):
    cleaned = re.sub(r"[^A-Za-z0-9.-]+", "-", value).strip("-.")
    if not cleaned:
        raise InventoryError(f"cannot create SPDX identifier from {value!r}")
    return cleaned


def _validate_inventory(inventory, source_helper_root, license_root):
    if inventory.get("schemaVersion") != 1:
        raise InventoryError("schemaVersion must equal 1")
    if inventory.get("platform") != "macos":
        raise InventoryError("platform must equal 'macos'")
    components = inventory.get("components")
    if not isinstance(components, list) or not components:
        raise InventoryError("components must be a non-empty array")

    seen_component_ids = set()
    helper_owners = {}
    validated_components = []
    for component in components:
        if not isinstance(component, dict):
            raise InventoryError("each component must be an object")
        component_id = _require_text(component, "id", "component")
        if component_id in seen_component_ids:
            raise InventoryError(f"component id appears more than once: {component_id}")
        seen_component_ids.add(component_id)
        name = _require_text(component, "name", component_id)
        version = _require_text(component, "version", component_id)
        supplier = _require_text(component, "supplier", component_id)
        download_location = _require_text(component, "downloadLocation", component_id)
        source_info = _require_text(component, "sourceInfo", component_id)
        license_concluded = _require_text(component, "licenseConcluded", component_id)
        license_declared = _require_text(component, "licenseDeclared", component_id)
        if not download_location.startswith("https://"):
            raise InventoryError(f"{component_id}.downloadLocation must use HTTPS")

        license_files = component.get("licenseFiles")
        if not isinstance(license_files, list) or not license_files:
            raise InventoryError(f"{component_id}.licenseFiles must be a non-empty array")
        normalized_license_files = []
        for license_entry in license_files:
            if not isinstance(license_entry, dict):
                raise InventoryError(f"{component_id}.licenseFiles entries must be objects")
            license_name = _require_text(
                license_entry, "name", f"{component_id}.licenseFile"
            )
            expected_license_sha256 = _require_text(
                license_entry, "sha256", f"{component_id}.{license_name}"
            )
            if not SHA256_PATTERN.fullmatch(expected_license_sha256):
                raise InventoryError(
                    f"{license_name} SHA-256 must be 64 lowercase hexadecimal characters"
                )
            license_path = _trusted_file(license_root, license_name, "declared license file")
            actual_license_sha256 = hashlib.sha256(license_path.read_bytes()).hexdigest()
            if actual_license_sha256 != expected_license_sha256:
                raise InventoryError(
                    f"{license_name} SHA-256 mismatch: "
                    f"{actual_license_sha256} != {expected_license_sha256}"
                )
            if any(item["name"] == license_name for item in normalized_license_files):
                raise InventoryError(f"{component_id} repeats license file: {license_name}")
            normalized_license_files.append(
                {"name": license_name, "sha256": actual_license_sha256}
            )

        helpers = component.get("helpers", [])
        embedded_in_helpers = component.get("embeddedInHelpers", [])
        if not isinstance(helpers, list):
            raise InventoryError(f"{component_id}.helpers must be an array")
        if not isinstance(embedded_in_helpers, list):
            raise InventoryError(f"{component_id}.embeddedInHelpers must be an array")
        if not helpers and not embedded_in_helpers:
            raise InventoryError(
                f"{component_id} must own a helper or declare an embeddedInHelpers relationship"
            )
        normalized_embedded_helpers = []
        for helper_name in embedded_in_helpers:
            if not isinstance(helper_name, str) or helper_name not in EXPECTED_HELPERS:
                raise InventoryError(f"{component_id}.embeddedInHelpers contains an unexpected helper")
            if helper_name in normalized_embedded_helpers:
                raise InventoryError(f"{component_id}.embeddedInHelpers repeats {helper_name}")
            normalized_embedded_helpers.append(helper_name)
        validated_helpers = []
        for helper in helpers:
            if not isinstance(helper, dict):
                raise InventoryError(f"{component_id}.helpers entries must be objects")
            helper_name = _require_text(helper, "name", f"{component_id}.helper")
            if helper_name not in EXPECTED_HELPERS:
                raise InventoryError(f"unexpected macOS helper in inventory: {helper_name}")
            if helper_name in helper_owners:
                raise InventoryError(
                    f"helper {helper_name} appears more than once: "
                    f"{helper_owners[helper_name]} and {component_id}"
                )
            expected_sha256 = _require_text(helper, "sha256", f"{component_id}.{helper_name}")
            if not SHA256_PATTERN.fullmatch(expected_sha256):
                raise InventoryError(f"{helper_name} SHA-256 must be 64 lowercase hexadecimal characters")
            architectures = helper.get("architectures")
            if not isinstance(architectures, list) or not architectures:
                raise InventoryError(f"{helper_name}.architectures must be a non-empty array")
            if any(value not in SUPPORTED_ARCHITECTURES for value in architectures):
                raise InventoryError(f"{helper_name}.architectures contains an unsupported value")
            if len(set(architectures)) != len(architectures):
                raise InventoryError(f"{helper_name}.architectures contains a duplicate")

            helper_path = _trusted_file(source_helper_root, helper_name, "canonical source helper")
            actual_sha256 = hashlib.sha256(helper_path.read_bytes()).hexdigest()
            if actual_sha256 != expected_sha256:
                raise InventoryError(
                    f"{helper_name} SHA-256 mismatch: {actual_sha256} != {expected_sha256}"
                )
            helper_owners[helper_name] = component_id
            validated_helpers.append(
                {
                    "name": helper_name,
                    "sha256": actual_sha256,
                    "architectures": tuple(architectures),
                }
            )

        validated_components.append(
            {
                "id": component_id,
                "name": name,
                "version": version,
                "supplier": supplier,
                "downloadLocation": download_location,
                "sourceInfo": source_info,
                "licenseConcluded": license_concluded,
                "licenseDeclared": license_declared,
                "licenseFiles": tuple(normalized_license_files),
                "helpers": tuple(validated_helpers),
                "embeddedInHelpers": tuple(normalized_embedded_helpers),
            }
        )

    missing = sorted(EXPECTED_HELPERS - helper_owners.keys())
    if missing:
        raise InventoryError(f"inventory does not own every required helper; missing: {missing}")
    return tuple(validated_components)


def _bundle_helper_checksums(helper_root):
    try:
        actual_helper_names = {
            path.name
            for path in helper_root.iterdir()
            if path.is_file() or path.is_symlink()
        }
    except OSError as error:
        raise InventoryError(f"could not inspect bundle helper directory {helper_root}: {error}") from error
    if actual_helper_names != EXPECTED_HELPERS:
        raise InventoryError(
            "bundle helper directory must contain exactly "
            f"{sorted(EXPECTED_HELPERS)}; found {sorted(actual_helper_names)}"
        )
    return {
        helper_name: hashlib.sha256(
            _trusted_file(helper_root, helper_name, "bundle helper").read_bytes()
        ).hexdigest()
        for helper_name in sorted(EXPECTED_HELPERS)
    }


def generate_sbom(
    *,
    inventory_path,
    helper_root,
    license_root,
    app_version,
    created=None,
    source_helper_root=None,
):
    inventory_path = Path(inventory_path)
    helper_root = Path(helper_root)
    source_helper_root = Path(source_helper_root) if source_helper_root else helper_root
    license_root = Path(license_root)
    if not VERSION_PATTERN.fullmatch(app_version):
        raise InventoryError("app_version must contain three numeric components")
    inventory = _load_json(inventory_path, "helper inventory")
    created = created or inventory.get("created")
    if not _valid_rfc3339_utc(created):
        raise InventoryError("created must be an RFC3339 UTC timestamp such as 2026-08-27T00:00:00Z")
    components = _validate_inventory(inventory, source_helper_root, license_root)
    bundle_helper_checksums = _bundle_helper_checksums(helper_root)

    app_spdx_id = "SPDXRef-Package-YTDownloaderPro2"
    packages = [
        {
            "SPDXID": app_spdx_id,
            "name": "YT Downloader Pro 2",
            "versionInfo": app_version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "supplier": "Organization: YT Downloader Pro",
        }
    ]
    files = []
    relationships = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": app_spdx_id,
        }
    ]
    for component in sorted(components, key=lambda item: item["name"].casefold()):
        package_spdx_id = f"SPDXRef-Package-{_spdx_id(component['id'])}"
        packages.append(
            {
                "SPDXID": package_spdx_id,
                "name": component["name"],
                "versionInfo": component["version"],
                "downloadLocation": component["downloadLocation"],
                "filesAnalyzed": False,
                "licenseConcluded": component["licenseConcluded"],
                "licenseDeclared": component["licenseDeclared"],
                "copyrightText": "NOASSERTION",
                "supplier": component["supplier"],
                "sourceInfo": component["sourceInfo"],
                "attributionTexts": [
                    "Bundled license: Contents/Resources/ThirdPartyLicenses/"
                    + license_file["name"]
                    + f" (SHA-256 {license_file['sha256']})"
                    for license_file in component["licenseFiles"]
                ],
            }
        )
        relationships.append(
            {
                "spdxElementId": app_spdx_id,
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": package_spdx_id,
            }
        )
        for helper_name in component["embeddedInHelpers"]:
            relationships.append(
                {
                    "spdxElementId": f"SPDXRef-File-{_spdx_id(helper_name)}",
                    "relationshipType": "STATIC_LINK",
                    "relatedSpdxElement": package_spdx_id,
                }
            )
        for helper in sorted(component["helpers"], key=lambda item: item["name"]):
            file_spdx_id = f"SPDXRef-File-{_spdx_id(helper['name'])}"
            files.append(
                {
                    "SPDXID": file_spdx_id,
                    "fileName": f"./Contents/Helpers/{helper['name']}",
                    "checksums": [
                        {
                            "algorithm": "SHA256",
                            "checksumValue": bundle_helper_checksums[helper["name"]],
                        }
                    ],
                    "licenseConcluded": component["licenseConcluded"],
                    "licenseInfoInFiles": ["NOASSERTION"],
                    "copyrightText": "NOASSERTION",
                    "comment": (
                        "Architectures: "
                        + ", ".join(helper["architectures"])
                        + f"; Canonical source SHA-256: {helper['sha256']}"
                    ),
                }
            )
            relationships.append(
                {
                    "spdxElementId": file_spdx_id,
                    "relationshipType": "GENERATED_FROM",
                    "relatedSpdxElement": package_spdx_id,
                }
            )

    namespace_material = {
        "appVersion": app_version,
        "bundleHelperChecksums": bundle_helper_checksums,
        "components": components,
        "created": created,
    }
    namespace_hash = hashlib.sha256(
        json.dumps(namespace_material, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"YT Downloader Pro 2 {app_version} macOS SBOM",
        "documentNamespace": (
            "https://github.com/catstayathome-collab/YT-Downloader-Pro/"
            f"spdx/macos/{app_version}/{namespace_hash}"
        ),
        "creationInfo": {
            "created": created,
            "creators": ["Tool: YT Downloader Pro generate_swift_sbom.py"],
        },
        "packages": packages,
        "files": sorted(files, key=lambda item: item["fileName"]),
        "relationships": sorted(
            relationships,
            key=lambda item: (
                item["spdxElementId"],
                item["relationshipType"],
                item["relatedSpdxElement"],
            ),
        ),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--helper-root", required=True, type=Path)
    parser.add_argument("--source-helper-root", type=Path)
    parser.add_argument("--license-root", required=True, type=Path)
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--created")
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        sbom = generate_sbom(
            inventory_path=arguments.inventory,
            source_helper_root=arguments.source_helper_root,
            helper_root=arguments.helper_root,
            license_root=arguments.license_root,
            app_version=arguments.app_version,
            created=arguments.created,
        )
        payload = json.dumps(sbom, indent=2, sort_keys=True) + "\n"
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(payload, encoding="utf-8")
    except (InventoryError, OSError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
