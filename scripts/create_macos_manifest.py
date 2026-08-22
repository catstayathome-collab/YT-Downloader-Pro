#!/usr/bin/env python3
"""Create the deterministic macOS update manifest from explicit release inputs."""

import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse


SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "updates" / "macos.json"


def https_url(value):
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise argparse.ArgumentTypeError("must be an HTTPS URL without embedded credentials")
    return value


def semantic_version(value):
    if not SEMVER.fullmatch(value):
        raise argparse.ArgumentTypeError("must be a valid SemVer 2.0 version")
    return value


def lowercase_sha256(value):
    if not SHA256.fullmatch(value):
        raise argparse.ArgumentTypeError("must be a 64-character lowercase SHA-256")
    return value


def utc_timestamp(value):
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise argparse.ArgumentTypeError("must use UTC YYYY-MM-DDTHH:MM:SSZ") from error
    return value


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, type=semantic_version)
    parser.add_argument("--minimum-macos", required=True, type=semantic_version)
    parser.add_argument("--release-url", required=True, type=https_url)
    parser.add_argument("--download-url", required=True, type=https_url)
    parser.add_argument("--sha256", required=True, type=lowercase_sha256)
    parser.add_argument("--published-at", required=True, type=utc_timestamp)
    parser.add_argument("--release-notes", required=True)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main():
    options = parse_args()
    release_notes = options.release_notes.strip()
    if not release_notes:
        raise SystemExit("--release-notes must not be empty")
    manifest = {
        "schema_version": 1,
        "platform": "macos",
        "latest_version": options.version,
        "minimum_macos": options.minimum_macos,
        "release_url": options.release_url,
        "download_url": options.download_url,
        "sha256": options.sha256,
        "published_at": options.published_at,
        "release_notes": release_notes,
    }
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
