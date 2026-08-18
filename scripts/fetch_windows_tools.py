#!/usr/bin/env python3
"""Download and install immutable Windows helper executables."""

import argparse
import hashlib
import json
import shutil
import ssl
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

import certifi


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "tools" / "windows-tools.json"
DEFAULT_OUTPUT = ROOT / "build" / "windows-tools" / "Helpers"
EXPECTED_OUTPUTS = {"ffmpeg.exe", "ffprobe.exe", "deno.exe"}


def tls_context():
    """Create a server-authenticated TLS context using certifi's CA bundle."""
    return ssl.create_default_context(cafile=certifi.where())


class HttpsOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject redirect targets before urllib can issue a non-HTTPS request."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlsplit(newurl)
        if target.scheme != "https" or not target.netloc:
            raise ValueError(f"helper download refused non-HTTPS redirect: {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def build_https_opener(*handlers):
    """Build the helper-download opener with TLS and redirect policy fixed."""
    return urllib.request.build_opener(
        HttpsOnlyRedirectHandler(),
        urllib.request.HTTPSHandler(context=tls_context()),
        *handlers,
    )


def download_archive(url, destination):
    """Download one HTTPS archive with certificate and hostname verification."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(f"helper URL must use HTTPS: {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "YT-Downloader-Pro-build/1.8.8"})
    destination = Path(destination)
    with build_https_opener().open(request, timeout=120) as response:
        final_url = urllib.parse.urlsplit(response.geturl())
        if final_url.scheme != "https" or not final_url.netloc:
            raise ValueError(f"helper download redirected to non-HTTPS URL: {response.geturl()}")
        with destination.open("wb") as output:
            shutil.copyfileobj(response, output)
    return destination


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_amd64_pe(path):
    """Reject corrupt, non-PE, and non-AMD64 Windows executables."""
    path = Path(path)
    try:
        with path.open("rb") as executable:
            dos_header = executable.read(64)
            if len(dos_header) != 64 or dos_header[:2] != b"MZ":
                raise ValueError("missing DOS header")
            pe_offset = int.from_bytes(dos_header[0x3C:0x40], "little")
            executable.seek(pe_offset)
            pe_header = executable.read(6)
        if len(pe_header) != 6 or pe_header[:4] != b"PE\0\0":
            raise ValueError("missing PE header")
        machine = int.from_bytes(pe_header[4:6], "little")
    except (OSError, ValueError) as error:
        raise ValueError(f"invalid Windows PE executable: {path}") from error
    if machine != 0x8664:
        raise ValueError(f"Windows executable is not AMD64: {path}")


def _safe_zip_member(name):
    normalized = name.replace("\\", "/")
    member = PurePosixPath(normalized)
    if (
        not normalized
        or normalized.startswith("/")
        or member.is_absolute()
        or any(part in {"", ".", ".."} for part in member.parts)
        or any(":" in part for part in member.parts)
    ):
        raise ValueError(f"unsafe ZIP member: {name}")
    return member


def _declared_members(spec):
    members = spec.get("archive_members")
    if not isinstance(members, list) or not members:
        raise ValueError("manifest must declare archive_members")
    outputs = set()
    declared = []
    for item in members:
        archive_path = item.get("path")
        output_name = item.get("output_name")
        if not isinstance(archive_path, str):
            raise ValueError("manifest archive member path must be a string")
        _safe_zip_member(archive_path)
        if (
            not isinstance(output_name, str)
            or Path(output_name).name != output_name
            or output_name.casefold() in outputs
        ):
            raise ValueError(f"unsafe or duplicate helper output name: {output_name}")
        outputs.add(output_name.casefold())
        declared.append((archive_path, output_name))
    return declared


def install_archive(spec, archive_path, output_dir):
    """Verify an archive and copy only its declared AMD64 PE members."""
    archive_path = Path(archive_path)
    expected_digest = str(spec.get("sha256", "")).lower()
    actual_digest = sha256_file(archive_path)
    if len(expected_digest) != 64 or actual_digest != expected_digest:
        raise ValueError(
            f"SHA-256 mismatch for {archive_path.name}: expected {expected_digest}, got {actual_digest}"
        )

    declared = _declared_members(spec)
    output_dir = Path(output_dir)
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path) as archive:
        archive_files = {}
        for info in archive.infolist():
            safe_name = _safe_zip_member(info.filename).as_posix()
            if safe_name.casefold() in archive_files:
                raise ValueError(f"duplicate ZIP member: {info.filename}")
            archive_files[safe_name.casefold()] = info

        with tempfile.TemporaryDirectory(prefix="windows-helper-", dir=output_dir.parent) as tmpdir:
            staging = Path(tmpdir)
            staged_outputs = []
            for archive_name, output_name in declared:
                info = archive_files.get(_safe_zip_member(archive_name).as_posix().casefold())
                if info is None or info.is_dir():
                    raise ValueError(f"declared ZIP member is missing: {archive_name}")
                staged_path = staging / output_name
                with archive.open(info, "r") as source, staged_path.open("wb") as output:
                    shutil.copyfileobj(source, output)
                validate_amd64_pe(staged_path)
                staged_outputs.append(staged_path)

            output_dir.mkdir(parents=True, exist_ok=True)
            installed = []
            for staged_path in staged_outputs:
                destination = output_dir / staged_path.name
                shutil.copy2(staged_path, destination)
                installed.append(destination)
    return installed


def fetch_tools(manifest_path=DEFAULT_MANIFEST, output_dir=DEFAULT_OUTPUT):
    """Download all pinned helper archives into a clean canonical directory."""
    manifest_path = Path(manifest_path)
    output_dir = Path(output_dir)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if set(manifest) != {"ffmpeg", "deno"}:
        raise ValueError("Windows manifest must contain exactly ffmpeg and deno")

    declared_outputs = {
        member["output_name"]
        for spec in manifest.values()
        for member in spec.get("archive_members", [])
    }
    if declared_outputs != EXPECTED_OUTPUTS:
        raise ValueError(f"manifest outputs must be exactly {sorted(EXPECTED_OUTPUTS)}")

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    installed = []
    with tempfile.TemporaryDirectory(prefix="windows-download-", dir=output_dir.parent) as tmpdir:
        for name, spec in manifest.items():
            archive_path = Path(tmpdir) / f"{name}.zip"
            download_archive(spec["url"], archive_path)
            installed.extend(install_archive(spec, archive_path, output_dir))
    return installed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    options = parser.parse_args(argv)
    installed = fetch_tools(options.manifest, options.output)
    for path in installed:
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
