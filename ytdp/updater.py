"""Shared update manifest parsing and platform asset selection."""

import base64
import json
import re
import ssl
from dataclasses import dataclass
from datetime import datetime
from urllib.parse import urlparse

import certifi


_SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
_LOWERCASE_SHA256 = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class UpdateManifestSelection:
    """Validated update metadata selected for one exact platform and architecture."""

    latest_version: str
    release_url: str | None
    download_url: str | None
    is_legacy: bool = False


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


def parse_platform_update_manifest(content, platform_name, architecture="x64"):
    """Select one platform manifest asset, while retaining legacy version sources.

    Structured manifests fail closed on a platform or architecture mismatch. Plain
    ``version.txt`` and pre-split JSON remain version-only compatibility inputs.
    """
    decoded = _decode_contents_api(content)
    if decoded is None:
        return None
    content = decoded.strip()
    if not content:
        return None

    try:
        manifest = json.loads(content)
    except json.JSONDecodeError:
        manifest = None

    if not isinstance(manifest, dict) or "platform" not in manifest:
        version = parse_update_manifest(content)
        if not version:
            return None
        return UpdateManifestSelection(version, None, None, is_legacy=True)

    requested_platform = _canonical_platform(platform_name)
    if requested_platform is None or manifest.get("platform") != requested_platform:
        return None
    if manifest.get("schema_version") != 1:
        return None

    version = str(manifest.get("latest_version") or "").strip()
    release_url = str(manifest.get("release_url") or "").strip()
    published_at = str(manifest.get("published_at") or "").strip()
    release_notes = str(manifest.get("release_notes") or "").strip()
    if not _SEMVER.fullmatch(version):
        return None
    if not _is_https_url(release_url):
        return None
    if not _is_utc_timestamp(published_at) or not release_notes:
        return None

    assets = manifest.get("assets")
    if not isinstance(assets, list):
        return None
    for asset in assets:
        if not isinstance(asset, dict):
            continue
        if asset.get("platform") != requested_platform:
            continue
        if str(asset.get("architecture") or "").lower() != str(architecture).lower():
            continue
        if not str(asset.get("name") or "").strip():
            continue
        download_url = str(asset.get("download_url") or "").strip()
        checksum = str(asset.get("sha256") or "").strip()
        if _is_https_url(download_url) and _LOWERCASE_SHA256.fullmatch(checksum):
            return UpdateManifestSelection(version, release_url, download_url)
    return None


def _decode_contents_api(content):
    content = (content or "").strip()
    if not content:
        return ""
    try:
        envelope = json.loads(content)
    except json.JSONDecodeError:
        return content
    if not isinstance(envelope, dict) or "content" not in envelope:
        return content
    if envelope.get("encoding") not in (None, "base64"):
        return None
    encoded = "".join(str(envelope.get("content") or "").split())
    try:
        return base64.b64decode(encoded, validate=True).decode("utf-8")
    except (ValueError, UnicodeError):
        return None


def _canonical_platform(platform_name):
    platform_name = str(platform_name).lower()
    if platform_name in {"windows", "win32"}:
        return "windows"
    if platform_name in {"macos", "darwin", "mac"}:
        return "macos"
    return None


def _is_https_url(value):
    parsed = urlparse(value)
    return parsed.scheme == "https" and bool(parsed.netloc) and not (
        parsed.username or parsed.password
    )


def _is_utc_timestamp(value):
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return False
    return True


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


def parse_release_asset_url(content, platform_name):
    """Return the selected release asset's HTTPS download URL, if available."""
    try:
        release = json.loads(content)
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
        return None

    for asset in release["assets"]:
        if select_release_asset([asset], platform_name) is None:
            continue
        if not isinstance(asset, dict):
            continue
        download_url = str(asset.get("browser_download_url") or "").strip()
        parsed = urlparse(download_url)
        if parsed.scheme == "https" and parsed.netloc:
            return download_url
    return None
