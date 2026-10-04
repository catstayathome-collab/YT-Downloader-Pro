#!/usr/bin/env python3
"""Validate a public-material-only Supabase staging configuration."""

import argparse
import base64
import binascii
import json
import re
import stat
import sys
from pathlib import Path
from urllib.parse import urlsplit


EXPECTED_KEYS = {
    "schemaVersion",
    "projectURL",
    "publishableKey",
    "redirectURL",
    "entitlementURL",
    "entitlementIssuer",
    "entitlementAudience",
    "publicKeys",
}
PRODUCT_IDENTIFIER = "com.tachouweng.ytdownloaderpro2"
MAXIMUM_CONFIGURATION_BYTES = 128 * 1024
P256_PRIME = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
FORBIDDEN_FIELD_NAMES = {
    "servicerolekey",
    "servicerole",
    "privatekey",
    "googleclientsecret",
    "clientsecret",
    "jwtsecret",
    "hashkey",
    "hashiv",
}
FORBIDDEN_RESOURCE_PATTERNS = (
    (re.compile(br"-----BEGIN (?:EC |RSA )?PRIVATE KEY-----", re.IGNORECASE), "private-key PEM"),
    (re.compile(br"\bsb_secret_[A-Za-z0-9_-]+", re.IGNORECASE), "Supabase secret key"),
    (re.compile(br"\bservice[_-]?role\b", re.IGNORECASE), "service-role material"),
    (re.compile(br"\bGOCSPX-[A-Za-z0-9_-]+", re.IGNORECASE), "Google client secret"),
    (
        re.compile(
            br"(?:serviceRoleKey|privateKey|googleClientSecret|clientSecret|jwtSecret|HashKey|HashIV)\s*[\"':=]",
            re.IGNORECASE,
        ),
        "forbidden secret field",
    ),
)


def _normalized_field_name(value):
    return re.sub(r"[^a-z0-9]", "", value.lower())


def _contains_forbidden_field(value):
    if isinstance(value, dict):
        for key, nested in value.items():
            if isinstance(key, str) and _normalized_field_name(key) in FORBIDDEN_FIELD_NAMES:
                return True
            if _contains_forbidden_field(nested):
                return True
    elif isinstance(value, list):
        return any(_contains_forbidden_field(item) for item in value)
    return False


def _trusted_https_url(value, *, exact_path=None, require_supabase_host=False):
    if not isinstance(value, str) or not value or value != value.strip():
        return None
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        return None
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
        or parsed.query
        or parsed.fragment
    ):
        return None
    if require_supabase_host:
        host = parsed.hostname.lower()
        if not host.endswith(".supabase.co") or host == ".supabase.co":
            return None
    if exact_path is not None:
        normalized = "" if parsed.path == "/" else parsed.path
        if normalized != exact_path:
            return None
    return parsed


def _trusted_redirect_url(value):
    if not isinstance(value, str) or value != value.strip():
        return False
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        return False
    return (
        parsed.scheme == PRODUCT_IDENTIFIER
        and parsed.hostname == "auth"
        and parsed.path == "/callback"
        and parsed.username is None
        and parsed.password is None
        and port is None
        and not parsed.query
        and not parsed.fragment
    )


def _strict_base64url(value):
    if (
        not isinstance(value, str)
        or not value
        or "=" in value
        or len(value) % 4 == 1
        or re.fullmatch(r"[A-Za-z0-9_-]+", value) is None
    ):
        return None
    padded = value.replace("-", "+").replace("_", "/")
    padded += "=" * ((4 - len(padded) % 4) % 4)
    try:
        decoded = base64.b64decode(padded, validate=True)
    except (ValueError, binascii.Error):
        return None
    encoded = base64.urlsafe_b64encode(decoded).rstrip(b"=").decode("ascii")
    return decoded if encoded == value else None


def _valid_p256_public_key(value):
    decoded = _strict_base64url(value)
    if decoded is None or len(decoded) != 65 or decoded[0] != 0x04:
        return False
    x = int.from_bytes(decoded[1:33], "big")
    y = int.from_bytes(decoded[33:], "big")
    if x >= P256_PRIME or y >= P256_PRIME:
        return False
    return (pow(y, 2, P256_PRIME) - (pow(x, 3, P256_PRIME) - 3 * x + P256_B)) % P256_PRIME == 0


def validate_configuration_object(payload):
    errors = []
    if not isinstance(payload, dict):
        return ["configuration must contain one JSON object"]
    if _contains_forbidden_field(payload):
        errors.append("configuration contains a forbidden secret field")
    if set(payload) != EXPECTED_KEYS:
        errors.append("configuration fields do not match the approved public schema")
    if payload.get("schemaVersion") != 1:
        errors.append("configuration schemaVersion must be 1")

    project = _trusted_https_url(
        payload.get("projectURL"), exact_path="", require_supabase_host=True
    )
    if project is None:
        errors.append("projectURL is not an approved Supabase HTTPS origin")
    entitlement = _trusted_https_url(
        payload.get("entitlementURL"),
        exact_path="/functions/v1/entitlement",
        require_supabase_host=True,
    )
    if entitlement is None or project is None or entitlement.hostname.lower() != project.hostname.lower():
        errors.append("entitlementURL must use the configured Supabase origin and exact function path")
    if not _trusted_redirect_url(payload.get("redirectURL")):
        errors.append("redirectURL does not match the approved app callback")
    if _trusted_https_url(payload.get("entitlementIssuer")) is None:
        errors.append("entitlementIssuer must be a trusted HTTPS URL")
    if payload.get("entitlementAudience") != PRODUCT_IDENTIFIER:
        errors.append("entitlementAudience does not match the app identifier")

    publishable_key = payload.get("publishableKey")
    if not isinstance(publishable_key, str) or re.fullmatch(r"sb_publishable_[A-Za-z0-9_-]+", publishable_key) is None:
        errors.append("publishableKey must contain publishable material only")

    public_keys = payload.get("publicKeys")
    if not isinstance(public_keys, dict) or not public_keys:
        errors.append("publicKeys must contain at least one key")
    else:
        for key_id, key_value in public_keys.items():
            if not isinstance(key_id, str) or re.fullmatch(r"[A-Za-z0-9._-]{1,64}", key_id) is None:
                errors.append("publicKeys contains an invalid key identifier")
                continue
            if not _valid_p256_public_key(key_value):
                errors.append(f"publicKeys contains an invalid P-256 key for approved id {key_id}")
    return errors


def validate_configuration_path(path):
    path = Path(path)
    try:
        metadata = path.lstat()
    except OSError:
        return ["configuration is missing or unreadable"]
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        return ["configuration must be a regular non-symlink file"]
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        return ["configuration must not be group- or world-writable"]
    if metadata.st_size == 0 or metadata.st_size > MAXIMUM_CONFIGURATION_BYTES:
        return ["configuration size is outside the approved limit"]
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return ["configuration is not valid UTF-8 JSON"]
    return validate_configuration_object(payload)


def scan_resource_tree(resources):
    resources = Path(resources)
    findings = []
    if not resources.is_dir() or resources.is_symlink():
        return findings
    for path in sorted(resources.rglob("*")):
        try:
            if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
                continue
            payload = path.read_bytes()
        except OSError:
            findings.append((path, "unreadable resource"))
            continue
        for pattern, label in FORBIDDEN_RESOURCE_PATTERNS:
            if pattern.search(payload):
                findings.append((path, label))
                break
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("configuration", type=Path)
    options = parser.parse_args(argv)
    errors = validate_configuration_path(options.configuration)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Supabase staging configuration is valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
