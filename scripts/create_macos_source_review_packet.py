#!/usr/bin/env python3
"""Build a deterministic, fail-closed macOS source review packet."""

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse


SHA256 = re.compile(r"^[0-9a-f]{64}$")
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
REQUIRED_REVIEW_FILES = (
    "LICENSE_REVIEW_BRIEF.md",
    "SOURCE_AVAILABILITY.md",
    "THIRD_PARTY_NOTICES.md",
    "docs/swift-2.0/SBOM_AND_LICENSES.md",
    "tools/macos-helper-inventory.json",
)


class PacketError(ValueError):
    """Raised when source review packet inputs are incomplete or unsafe."""


def _load_json(path, label):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PacketError(f"could not read {label}: {error}") from error
    if not isinstance(value, dict):
        raise PacketError(f"{label} must contain a JSON object")
    return value


def _trusted_relative_path(root, value, label):
    if not isinstance(value, str) or not value:
        raise PacketError(f"{label} must be a non-empty repository-relative path")
    relative = PurePosixPath(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise PacketError(f"{label} must stay inside the repository")
    path = root.joinpath(*relative.parts)
    try:
        resolved = path.resolve(strict=True)
        resolved.relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise PacketError(f"missing or unsafe evidence file: {value}") from error
    if not resolved.is_file():
        raise PacketError(f"evidence path is not a file: {value}")
    return resolved


def _credential_free_https(value, label):
    if not isinstance(value, str):
        raise PacketError(f"{label} must be a credential-free HTTPS URL")
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise PacketError(f"{label} must be a credential-free HTTPS URL")
    return value


def _archive_name(value):
    if not isinstance(value, str) or not value or Path(value).name != value:
        raise PacketError("source fileName must be a plain file name")
    return value


def _zip_info(name):
    info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    return info


def _json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")


def _validated_inventory(inventory):
    if inventory.get("schemaVersion") != 1:
        raise PacketError("source archive inventory schemaVersion must equal 1")
    if inventory.get("platform") != "macos":
        raise PacketError("source archive inventory platform must equal macos")
    release_version = inventory.get("releaseVersion")
    if not isinstance(release_version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", release_version):
        raise PacketError("source archive inventory releaseVersion must use three numeric components")
    if inventory.get("publicDistributionReady") is not False:
        raise PacketError("review packet inventory must remain publicDistributionReady=false")
    limitations = inventory.get("limitations")
    if not isinstance(limitations, list) or not limitations or any(
        not isinstance(item, str) or not item.strip() for item in limitations
    ):
        raise PacketError("review packet inventory must list its unresolved limitations")
    components = inventory.get("components")
    if not isinstance(components, list) or not components:
        raise PacketError("source archive inventory components must be a non-empty array")

    seen_ids = set()
    seen_archives = set()
    normalized_components = []
    for component in components:
        if not isinstance(component, dict):
            raise PacketError("each source archive component must be an object")
        component_id = component.get("id")
        name = component.get("name")
        version = component.get("version")
        if not all(isinstance(value, str) and value.strip() for value in (component_id, name, version)):
            raise PacketError("each component requires non-empty id, name, and version")
        if component_id in seen_ids:
            raise PacketError(f"duplicate source component id: {component_id}")
        seen_ids.add(component_id)
        source = component.get("source")
        if not isinstance(source, dict):
            raise PacketError(f"{component_id}.source must be an object")
        file_name = _archive_name(source.get("fileName"))
        if file_name in seen_archives:
            raise PacketError(f"duplicate source archive file name: {file_name}")
        seen_archives.add(file_name)
        url = _credential_free_https(source.get("url"), f"{component_id}.source.url")
        sha256 = source.get("sha256")
        if not isinstance(sha256, str) or not SHA256.fullmatch(sha256):
            raise PacketError(f"{component_id}.source.sha256 must be a lowercase SHA-256")
        evidence_files = component.get("evidenceFiles")
        if not isinstance(evidence_files, list) or not evidence_files:
            raise PacketError(f"{component_id}.evidenceFiles must be a non-empty array")
        if len(evidence_files) != len(set(evidence_files)):
            raise PacketError(f"{component_id}.evidenceFiles contains duplicates")
        normalized_components.append(
            {
                "id": component_id,
                "name": name,
                "version": version,
                "source": {"fileName": file_name, "url": url, "sha256": sha256},
                "evidenceFiles": sorted(evidence_files),
            }
        )
    return {
        "schemaVersion": 1,
        "platform": "macos",
        "releaseVersion": release_version,
        "publicDistributionReady": False,
        "limitations": list(limitations),
        "components": sorted(normalized_components, key=lambda item: item["id"]),
    }


def _validate_component_versions(source_inventory, helper_inventory):
    if helper_inventory.get("schemaVersion") != 1 or helper_inventory.get("platform") != "macos":
        raise PacketError("helper inventory schema or platform is invalid")
    helper_components = helper_inventory.get("components")
    if not isinstance(helper_components, list) or not helper_components:
        raise PacketError("helper inventory components must be a non-empty array")
    helper_versions = {}
    for component in helper_components:
        if not isinstance(component, dict):
            raise PacketError("helper inventory components must be objects")
        component_id = component.get("id")
        version = component.get("version")
        if not isinstance(component_id, str) or not isinstance(version, str):
            raise PacketError("helper inventory component id and version must be strings")
        if component_id in helper_versions:
            raise PacketError(f"helper inventory repeats component id: {component_id}")
        helper_versions[component_id] = version

    source_versions = {item["id"]: item["version"] for item in source_inventory["components"]}
    if set(source_versions) != set(helper_versions):
        raise PacketError("source components must exactly match helper inventory components")
    for component_id, version in source_versions.items():
        if version != helper_versions[component_id]:
            raise PacketError(
                f"{component_id} version {version} does not match helper inventory "
                f"version {helper_versions[component_id]}"
            )


def create_packet(*, repository_root, inventory_path, archive_root, output_path, metadata_only=False):
    repository_root = Path(repository_root).resolve(strict=True)
    inventory_path = Path(inventory_path)
    archive_root = Path(archive_root)
    output_path = Path(output_path)
    inventory = _validated_inventory(_load_json(inventory_path, "source archive inventory"))
    helper_inventory_path = repository_root / "tools" / "macos-helper-inventory.json"
    helper_inventory = _load_json(helper_inventory_path, "helper inventory")
    _validate_component_versions(inventory, helper_inventory)

    try:
        trusted_archive_root = archive_root.resolve(strict=True)
    except OSError as error:
        if metadata_only:
            trusted_archive_root = archive_root.resolve(strict=False)
        else:
            raise PacketError(f"archive root does not exist: {archive_root}") from error

    entries = {}
    for relative in REQUIRED_REVIEW_FILES:
        path = _trusted_relative_path(repository_root, relative, "required review file")
        entries[relative] = path.read_bytes()
    for component in inventory["components"]:
        for relative in component["evidenceFiles"]:
            path = _trusted_relative_path(repository_root, relative, "component evidence file")
            entries[relative] = path.read_bytes()
        source = component["source"]
        archive_path = archive_root / source["fileName"]
        if metadata_only:
            continue
        if not archive_path.is_file():
            raise PacketError(f"missing source archive: {source['fileName']}")
        try:
            trusted_archive_path = archive_path.resolve(strict=True)
            trusted_archive_path.relative_to(trusted_archive_root)
        except (OSError, ValueError) as error:
            raise PacketError(
                f"source archive must stay inside archive root: {source['fileName']}"
            ) from error
        payload = trusted_archive_path.read_bytes()
        actual_sha256 = hashlib.sha256(payload).hexdigest()
        if actual_sha256 != source["sha256"]:
            raise PacketError(
                f"{source['fileName']} SHA-256 mismatch: {actual_sha256} != {source['sha256']}"
            )
        entries[f"SourceArchives/{source['fileName']}"] = payload

    entries["SOURCE_ARCHIVE_INVENTORY.json"] = _json_bytes(inventory)
    status = {
        "schemaVersion": 1,
        "releaseVersion": inventory["releaseVersion"],
        "packetPurpose": "internal-license-and-source-review",
        "publicDistributionReady": False,
        "includesSourceArchives": not metadata_only,
        "limitations": inventory["limitations"],
    }
    entries["INTERNAL_REVIEW_ONLY.json"] = _json_bytes(status)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output_path, "w") as archive:
        for name in sorted(entries):
            archive.writestr(_zip_info(name), entries[name])
    return status


def parse_args():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=root)
    parser.add_argument(
        "--inventory",
        type=Path,
        default=root / "tools" / "macos-source-archives.json",
    )
    parser.add_argument("--archive-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metadata-only", action="store_true")
    return parser.parse_args()


def main():
    options = parse_args()
    try:
        status = create_packet(
            repository_root=options.repository_root,
            inventory_path=options.inventory,
            archive_root=options.archive_root,
            output_path=options.output,
            metadata_only=options.metadata_only,
        )
    except PacketError as error:
        raise SystemExit(f"ERROR: {error}") from error
    print(json.dumps(status, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
