#!/usr/bin/env python3
"""Report machine-verifiable blockers before building a public macOS candidate."""

import argparse
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import urlparse


SHA256 = re.compile(r"^[0-9a-f]{64}$")


def _run(arguments):
    try:
        return subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return subprocess.CompletedProcess(arguments, 1, "", "")


def _load_json(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _gate(gate_id, status, summary):
    return {"id": gate_id, "status": status, "summary": summary}


def _safe_https(value):
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    return (
        parsed.scheme == "https"
        and bool(parsed.netloc)
        and not parsed.username
        and not parsed.password
        and parsed.hostname != "example.invalid"
    )


def _manifest_gate(root, expected_version):
    manifest = _load_json(root / "updates" / "macos.json")
    if manifest is None:
        return _gate("update_manifest", "blocked", "macOS update manifest is missing or invalid.")
    valid = (
        manifest.get("schema_version") == 1
        and manifest.get("platform") == "macos"
        and manifest.get("latest_version") == expected_version
        and _safe_https(manifest.get("release_url"))
        and _safe_https(manifest.get("download_url"))
        and isinstance(manifest.get("sha256"), str)
        and SHA256.fullmatch(manifest["sha256"])
        and manifest["sha256"] != "0" * 64
    )
    if not valid:
        return _gate(
            "update_manifest",
            "blocked",
            "Manifest is still a placeholder or does not identify the exact release.",
        )
    return _gate("update_manifest", "pass", "Manifest identifies the expected release artifact.")


def _source_distribution_gate(root, expected_version):
    inventory = _load_json(root / "tools" / "macos-source-archives.json")
    if inventory is None:
        return _gate("source_distribution", "blocked", "Source archive inventory is missing or invalid.")
    approval_reference = inventory.get("approvalReference")
    if inventory.get("releaseVersion") != expected_version:
        return _gate("source_distribution", "blocked", "Source inventory version does not match the release.")
    components = inventory.get("components")
    if not isinstance(components, list) or not components or any(
        not isinstance(component, dict) for component in components
    ):
        return _gate(
            "source_distribution",
            "blocked",
            "Source distribution component inventory is empty or invalid.",
        )
    if not isinstance(approval_reference, str) or not approval_reference.strip():
        return _gate(
            "source_distribution",
            "blocked",
            "Source distribution has no dated approval reference.",
        )
    if inventory.get("publicDistributionReady") is not True or inventory.get("limitations") != []:
        return _gate(
            "source_distribution",
            "blocked",
            "Source delivery or relinking limitations remain unresolved.",
        )
    return _gate("source_distribution", "pass", "Source distribution has an approval reference.")


def _release_notes_gate(root, expected_version):
    path = root / "docs" / "swift-2.0" / f"RELEASE_NOTES_{expected_version}.md"
    try:
        contents = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return _gate("release_notes", "blocked", "Versioned release notes are missing.")
    if expected_version not in contents:
        return _gate("release_notes", "blocked", "Release notes do not name the expected version.")
    return _gate("release_notes", "pass", "Versioned release notes are present.")


def evaluate_repository(*, repository_root, expected_version, notary_profile, command_runner=_run):
    root = Path(repository_root)
    identity = command_runner(["security", "find-identity", "-v", "-p", "codesigning"])
    identity_output = identity.stdout or ""
    valid_identity_count = re.search(r"\b([1-9][0-9]*) valid identities found\b", identity_output)
    developer_id_ready = (
        identity.returncode == 0
        and "Developer ID Application:" in identity_output
        and valid_identity_count is not None
    )
    notary = command_runner(
        ["xcrun", "notarytool", "history", "--keychain-profile", notary_profile]
    )
    notary_ready = notary.returncode == 0

    gates = [
        _release_notes_gate(root, expected_version),
        _manifest_gate(root, expected_version),
        _source_distribution_gate(root, expected_version),
        _gate(
            "developer_id",
            "pass" if developer_id_ready else "blocked",
            "Developer ID Application identity is available."
            if developer_id_ready
            else "Developer ID Application identity is unavailable.",
        ),
        _gate(
            "notary_profile",
            "pass" if notary_ready else "blocked",
            f"Notary profile {notary_profile} is available."
            if notary_ready
            else f"Notary profile {notary_profile} is unavailable.",
        ),
    ]
    ready = all(gate["status"] == "pass" for gate in gates)
    return {
        "schemaVersion": 1,
        "platform": "macos",
        "expectedVersion": expected_version,
        "overallStatus": "ready_for_signed_candidate" if ready else "blocked",
        "scope": "machine-verifiable-preflight-only",
        "gates": gates,
    }


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--version", required=True)
    parser.add_argument("--notary-profile", default="YTDP_NOTARY")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main():
    options = parse_args()
    report = evaluate_repository(
        repository_root=options.repository_root,
        expected_version=options.version,
        notary_profile=options.notary_profile,
    )
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if options.output:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(payload, encoding="utf-8")
    print(payload, end="")
    raise SystemExit(0 if report["overallStatus"] == "ready_for_signed_candidate" else 2)


if __name__ == "__main__":
    main()
