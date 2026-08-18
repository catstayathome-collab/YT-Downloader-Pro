"""Validation for canonical packaged media helpers."""

from dataclasses import asdict, dataclass
import os
from pathlib import Path
import re
import subprocess

from ytdp.models import ToolchainError


@dataclass(frozen=True)
class ToolchainReport:
    paths: dict[str, str]
    versions: dict[str, str]
    architectures: dict[str, str]
    duplicate_counts: dict[str, int]
    lgpl_configuration: dict[str, object]

    def as_dict(self):
        return asdict(self)


class Toolchain:
    """Validate the packaged FFmpeg, FFprobe, and JavaScript runtime."""

    def __init__(self, adapter, logger=None):
        self.adapter = adapter
        self.logger = logger

    def _required_helpers(self):
        runtime = self.adapter.js_runtime_tool()
        return (
            ("ffmpeg", self.adapter.helper_name("ffmpeg"), ("-version",)),
            ("ffprobe", self.adapter.helper_name("ffprobe"), ("-version",)),
            (
                self.adapter.js_runtime_name(),
                self.adapter.helper_name(runtime),
                tuple(self.adapter.js_runtime_check_args()),
            ),
        )

    def _duplicate_counts(self, canonical_names):
        helper_dir = Path(self.adapter.helper_dir())
        search_root = Path(self.adapter.frozen_dir) if self.adapter.frozen else helper_dir
        names = {name.lower(): name for name in canonical_names}
        counts = {name: 0 for name in canonical_names}
        if not search_root.is_dir():
            return counts
        candidates = search_root.rglob("*") if self.adapter.frozen else search_root.iterdir()
        for path in candidates:
            canonical = names.get(path.name.lower())
            try:
                is_file = path.is_file()
            except OSError:
                is_file = False
            if canonical is not None and is_file:
                counts[canonical] += 1
        return counts

    def _parse_version(self, tool, output):
        if tool in {"ffmpeg", "ffprobe"}:
            match = re.search(
                rf"(?im)^{re.escape(tool)}\s+version\s+(\S+)", output
            )
        else:
            marker = self.adapter.js_runtime_output_marker()
            match = re.search(rf"(?im)^{re.escape(marker)}\s+(\S+)", output)
        if not match:
            raise ToolchainError(f"unable to parse {tool} version")
        return match.group(1)

    def _run(self, tool, path, arguments):
        command = [str(path), *arguments]
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=8,
                **self.adapter.subprocess_kwargs(),
            )
        except Exception as error:
            if self.logger:
                self.logger.log(error, stage=f"{tool}_version", command=command)
            raise ToolchainError(f"{tool} execution failed: {error}") from error
        output = f"{result.stdout or ''}\n{result.stderr or ''}".strip()
        quickjs_exit_one = (
            tool == "quickjs"
            and self.adapter.filename_platform() == "macos"
            and result.returncode == 1
            and self.adapter.js_runtime_output_marker() in output
        )
        if result.returncode != 0 and not quickjs_exit_one:
            detail = output or f"exit code {result.returncode}"
            if self.logger:
                self.logger.log(detail, stage=f"{tool}_version", command=command)
            raise ToolchainError(f"{tool} execution failed: {detail}")
        return output

    def validate(self):
        helpers = self._required_helpers()
        counts = self._duplicate_counts([item[1] for item in helpers])
        for filename, count in counts.items():
            if count == 0:
                raise ToolchainError(f"required helper is missing: {filename}")
            if count > 1:
                raise ToolchainError(
                    f"duplicate helper validation failed for {filename}: found {count} copies"
                )

        paths = {}
        architectures = {}
        outputs = {}
        versions = {}
        for tool, filename, arguments in helpers:
            path = (Path(self.adapter.helper_dir()) / filename).resolve()
            if not path.is_file() or not os.access(path, os.X_OK):
                raise ToolchainError(f"required helper is missing or blocked: {path}")
            self.adapter.validate_architecture(path)
            paths[tool] = str(path)
            architectures[tool] = (
                "AMD64"
                if self.adapter.filename_platform() == "windows"
                else "native"
            )
            outputs[tool] = self._run(tool, path, arguments)
            versions[tool] = self._parse_version(tool, outputs[tool])

        if versions["ffmpeg"] != versions["ffprobe"]:
            raise ToolchainError(
                "ffmpeg and ffprobe version mismatch: "
                f"{versions['ffmpeg']} != {versions['ffprobe']}"
            )

        match = re.search(r"(?im)^configuration:\s*(.*)$", outputs["ffmpeg"])
        configuration = match.group(1).strip() if match else ""
        if not configuration:
            raise ToolchainError("FFmpeg configuration evidence is missing")
        forbidden = re.search(
            r"(?:^|\s)--enable-(?:gpl|nonfree)(?:\s|$)", configuration
        )
        if forbidden:
            raise ToolchainError(
                f"FFmpeg build is not LGPL-compatible: {forbidden.group(0).strip()}"
            )
        lgpl = {
            "compatible": True,
            "configuration": configuration,
            "forbidden_flags": [],
        }
        report = ToolchainReport(
            paths=paths,
            versions=versions,
            architectures=architectures,
            duplicate_counts=counts,
            lgpl_configuration=lgpl,
        )
        if self.logger:
            self.logger.log(
                "toolchain validation passed",
                stage="toolchain",
                versions=versions,
            )
        return report


__all__ = ["Toolchain", "ToolchainReport"]
