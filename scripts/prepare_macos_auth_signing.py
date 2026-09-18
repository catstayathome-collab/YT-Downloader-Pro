#!/usr/bin/env python3
"""Validate a macOS provisioning profile and emit minimal auth entitlements."""

import argparse
import plistlib
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


class ProfileValidationError(ValueError):
    pass


def _utc(value):
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _profile_authorizes_identifier(authorization, identifier, team_id):
    if authorization == identifier:
        return True
    if not isinstance(authorization, str):
        return False
    prefix = f"{team_id}."
    return (
        authorization.startswith(prefix)
        and authorization.endswith(".*")
        and identifier.startswith(authorization[:-1])
    )


def build_auth_entitlements(profile, *, team_id, bundle_identifier, now=None):
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ProfileValidationError("team ID must contain 10 uppercase letters or digits")
    if not isinstance(bundle_identifier, str) or not re.fullmatch(
        r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+",
        bundle_identifier,
    ):
        raise ProfileValidationError("bundle identifier is invalid")
    if not isinstance(profile, dict):
        raise ProfileValidationError("profile must contain one property-list dictionary")

    team_identifiers = profile.get("TeamIdentifier")
    if not isinstance(team_identifiers, list) or team_id not in team_identifiers:
        raise ProfileValidationError("profile TeamIdentifier does not authorize the requested team")

    prefixes = profile.get("ApplicationIdentifierPrefix")
    if not isinstance(prefixes, list) or team_id not in prefixes:
        raise ProfileValidationError(
            "profile ApplicationIdentifierPrefix does not authorize the requested team"
        )

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        raise ProfileValidationError("profile expiration date is missing")
    current = _utc(now or datetime.now(timezone.utc))
    if _utc(expiration) <= current:
        raise ProfileValidationError("provisioning profile is expired")

    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        raise ProfileValidationError("profile entitlements are missing")

    app_identifier = f"{team_id}.{bundle_identifier}"
    if not _profile_authorizes_identifier(
        profile_entitlements.get("com.apple.application-identifier"),
        app_identifier,
        team_id,
    ):
        raise ProfileValidationError(
            "profile application identifier does not match the requested bundle"
        )
    if profile_entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise ProfileValidationError(
            "profile developer team identifier does not match the requested team"
        )
    access_groups = profile_entitlements.get("keychain-access-groups")
    if not isinstance(access_groups, list) or not any(
        _profile_authorizes_identifier(value, app_identifier, team_id)
        for value in access_groups
    ):
        raise ProfileValidationError(
            "profile does not authorize the app's default keychain access group"
        )

    return {
        "com.apple.application-identifier": app_identifier,
        "com.apple.developer.team-identifier": team_id,
        "keychain-access-groups": [app_identifier],
    }


def decode_profile(path):
    path = Path(path).absolute()
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ProfileValidationError(f"provisioning profile is unreadable: {error}") from error
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise ProfileValidationError("provisioning profile must be a regular file")
    if metadata.st_size == 0 or metadata.st_size > 4 * 1024 * 1024:
        raise ProfileValidationError("provisioning profile has an invalid size")

    try:
        result = subprocess.run(
            ["/usr/bin/security", "cms", "-D", "-i", str(path)],
            capture_output=True,
            check=False,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ProfileValidationError(f"could not decode provisioning profile: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ProfileValidationError(
            f"could not decode provisioning profile: {detail or 'security cms failed'}"
        )
    try:
        profile = plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise ProfileValidationError(f"decoded provisioning profile is invalid: {error}") from error
    if not isinstance(profile, dict):
        raise ProfileValidationError("decoded provisioning profile must be a dictionary")
    return profile


def write_entitlements(path, entitlements):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=True)
    path.write_bytes(payload)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args(argv)
    try:
        entitlements = build_auth_entitlements(
            decode_profile(options.profile),
            team_id=options.team_id,
            bundle_identifier=options.bundle_id,
        )
        write_entitlements(options.output, entitlements)
    except ProfileValidationError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
