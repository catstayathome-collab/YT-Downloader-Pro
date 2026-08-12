"""Deterministic packaged checks for the Windows onedir application."""

import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import certifi

from ytdp.core import sanitize_filename_stem
from ytdp.diagnostics import sanitize_diagnostic
from ytdp.toolchain import Toolchain


SCHEMA_VERSION = 1


def _check_imports():
    imported = []
    for name in ("certifi", "yt_dlp", "yt_dlp_ejs", "ytdp"):
        importlib.import_module(name)
        imported.append(name)
    return {"modules": imported}


def _check_certificate():
    path = Path(certifi.where())
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f"certificate bundle is unavailable: {path}")
    return {"path": str(path), "bytes": path.stat().st_size}


def _check_writable_directory(path):
    directory = Path(path)
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=directory, prefix="ytdp-self-test-", delete=True):
        pass
    return {"path": str(directory.resolve())}


def _check_filename_rules():
    cases = {
        "CON": "_CON",
        "bad<>:\"/\\|?*name. ": "bad_________name",
        "\x00\x01": "__",
    }
    results = {
        source: sanitize_filename_stem(source, "windows")
        for source in cases
    }
    if results != cases:
        raise RuntimeError(f"Windows filename rules failed: {results}")
    return {"cases": len(cases)}


def _run_checked(adapter, command):
    result = subprocess.run(
        [str(value) for value in command],
        capture_output=True,
        text=True,
        timeout=8,
        **adapter.subprocess_kwargs(),
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or f"exit code {result.returncode}").strip()
        raise RuntimeError(f"local media command failed: {detail}")
    return result.stdout or ""


def _run_ffmpeg_cycle(adapter, toolchain_report):
    """Generate, merge, probe, and convert local media without GPL codecs."""
    ffmpeg = toolchain_report.paths["ffmpeg"]
    ffprobe = toolchain_report.paths["ffprobe"]
    with tempfile.TemporaryDirectory(prefix="ytdp-ffmpeg-self-test-") as tmpdir:
        root = Path(tmpdir)
        video = root / "video.mp4"
        audio = root / "audio.wav"
        merged = root / "merged.mp4"
        mp3 = root / "converted.mp3"
        common = [ffmpeg, "-y", "-hide_banner", "-loglevel", "error"]
        _run_checked(adapter, [
            *common,
            "-f", "lavfi",
            "-i", "testsrc2=size=160x90:rate=10",
            "-t", "1",
            "-c:v", "mpeg4",
            "-an",
            video,
        ])
        _run_checked(adapter, [
            *common,
            "-f", "lavfi",
            "-i", "sine=frequency=1000:sample_rate=44100",
            "-t", "1",
            "-c:a", "pcm_s16le",
            audio,
        ])
        _run_checked(adapter, [
            *common,
            "-i", video,
            "-i", audio,
            "-c:v", "copy",
            "-c:a", "aac",
            "-shortest",
            merged,
        ])
        probe_output = _run_checked(adapter, [
            ffprobe,
            "-v", "error",
            "-show_entries", "stream=codec_type",
            "-of", "json",
            merged,
        ])
        probe = json.loads(probe_output)
        streams = [stream.get("codec_type") for stream in probe.get("streams", [])]
        if streams != ["video", "audio"]:
            raise RuntimeError(f"unexpected merged streams: {streams}")
        _run_checked(adapter, [
            *common,
            "-i", merged,
            "-vn",
            "-c:a", "libmp3lame",
            "-b:a", "128k",
            mp3,
        ])
        for path in (video, audio, merged, mp3):
            if not path.is_file() or path.stat().st_size == 0:
                raise RuntimeError(f"local media output is missing: {path.name}")
        return {"streams": streams, "mp3_bytes": mp3.stat().st_size}


def _run_check(checks, name, function):
    try:
        details = function()
        checks.append({"name": name, "status": "ok", "details": details})
        return details
    except Exception as error:
        checks.append({
            "name": name,
            "status": "failed",
            "error": sanitize_diagnostic(error),
        })
        return None


def _write_report(path, payload):
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(payload + "\n", encoding="utf-8")


def run_self_test(adapter, report_path=None):
    """Run packaged checks, emit one JSON report, and return a process code."""
    checks = []
    _run_check(checks, "imports", _check_imports)
    _run_check(checks, "certificate", _check_certificate)
    _run_check(
        checks,
        "settings_writable",
        lambda: _check_writable_directory(adapter.settings_dir()),
    )
    _run_check(
        checks,
        "logs_writable",
        lambda: _check_writable_directory(adapter.log_dir()),
    )
    _run_check(checks, "filename_rules", _check_filename_rules)

    validated = None
    try:
        validated = Toolchain(adapter).validate()
        checks.append({
            "name": "toolchain",
            "status": "ok",
            "details": validated.as_dict(),
        })
    except Exception as error:
        checks.append({
            "name": "toolchain",
            "status": "failed",
            "error": sanitize_diagnostic(error),
        })
    if validated is None:
        _run_check(
            checks,
            "ffmpeg_cycle",
            lambda: (_ for _ in ()).throw(RuntimeError("toolchain validation failed")),
        )
    else:
        _run_check(
            checks,
            "ffmpeg_cycle",
            lambda: _run_ffmpeg_cycle(adapter, validated),
        )

    report = {
        "schema_version": SCHEMA_VERSION,
        "status": "ok" if all(check["status"] == "ok" for check in checks) else "failed",
        "checks": checks,
    }
    payload = json.dumps(report, ensure_ascii=False, sort_keys=True)
    if report_path is not None:
        try:
            _write_report(report_path, payload)
        except OSError as error:
            checks.append({
                "name": "report_writable",
                "status": "failed",
                "error": sanitize_diagnostic(error),
            })
            report["status"] = "failed"
            payload = json.dumps(report, ensure_ascii=False, sort_keys=True)
    if sys.stdout is not None:
        print(payload)
    return 0 if report["status"] == "ok" else 1


__all__ = ["run_self_test"]
