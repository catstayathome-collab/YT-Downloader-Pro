"""Shared update manifest parsing and platform asset selection."""

import base64
import json
import re
import ssl

import certifi


def make_update_ssl_context():
    """Create an SSL context backed by certifi's certificate bundle."""
    return ssl.create_default_context(cafile=certifi.where())


def parse_update_manifest(content):
    """Extract a version string from plain, JSON, or Contents API manifests."""
    content = (content or "").strip()
    if not content:
        return ""
    try:
        data = json.loads(content)
    except json.JSONDecodeError:
        data = None
    if isinstance(data, dict):
        encoded = data.get("content")
        if encoded:
            try:
                decoded = base64.b64decode(str(encoded).encode()).decode(
                    "utf-8", errors="replace"
                )
            except (ValueError, UnicodeError):
                return ""
            return parse_update_manifest(decoded)
        return str(
            data.get("latest_version")
            or data.get("version")
            or data.get("tag_name")
            or ""
        ).strip().lstrip("v")
    return content.splitlines()[0].strip().lstrip("v")


def is_newer_version(latest, current):
    """Compare version components with the existing numeric release semantics."""
    parts = lambda value: [int(item) for item in re.findall(r"\d+", value)]
    return parts(latest) > parts(current)


def _asset_name(asset):
    if isinstance(asset, dict):
        return str(asset.get("name") or "")
    return str(asset)


def _asset_tokens(asset):
    return set(re.findall(r"[a-z0-9]+", _asset_name(asset).lower()))


def _is_windows_x64_asset(asset):
    tokens = _asset_tokens(asset)
    is_windows = bool(tokens & {"windows", "win", "win64"})
    is_supported_architecture = bool(tokens & {"x64", "amd64", "win64"})
    is_rejected = bool(tokens & {
        "mac", "macos", "darwin", "osx", "x86", "x32", "win32", "32",
        "arm", "arm64", "aarch64", "i386", "i686",
    })
    return is_windows and is_supported_architecture and not is_rejected


def select_release_asset(assets, platform_name):
    """Return the first release asset appropriate for the requested platform."""
    platform_name = str(platform_name).lower()
    if platform_name in {"windows", "win32"}:
        for asset in assets:
            if _is_windows_x64_asset(asset):
                return asset
        return None
    elif platform_name in {"macos", "darwin", "mac"}:
        required, excluded = ("macos", "darwin", "osx"), ("windows", "win32")
    else:
        return None
    for asset in assets:
        name = _asset_name(asset).lower()
        if any(marker in name for marker in required) and not any(
            marker in name for marker in excluded
        ):
            return asset
    return None
