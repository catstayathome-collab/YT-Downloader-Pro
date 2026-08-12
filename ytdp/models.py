"""Data models and download artifact lifecycle tracking."""

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class DownloadRequest:
    url: str
    video_format_id: str | None
    audio_format_id: str | None
    audio_only: bool
    output_directory: str
    title: str


class DownloadArtifactTracker:
    """Track download artifacts created in one output directory."""

    def __init__(self, directory, output_filename):
        self.directory = Path(directory).resolve()
        self.output_path = (self.directory / output_filename).absolute()
        self.preexisting = {path.absolute() for path in self.directory.iterdir()}
        self.preexisting_resolved = {
            path.resolve(strict=False) for path in self.preexisting
        }
        self.tracked = set()
        self.track(str(self.output_path))

    def track(self, path):
        if not path:
            return
        candidate = Path(path)
        if not candidate.is_absolute():
            candidate = self.directory / candidate
        candidate = candidate.absolute()
        resolved = candidate.resolve(strict=False)
        if resolved != self.directory and self.directory not in resolved.parents:
            return
        if candidate not in self.preexisting and resolved not in self.preexisting_resolved:
            self.tracked.add(candidate)

    def cleanup(self):
        removed = []
        for path in sorted(self.tracked, key=lambda item: len(str(item)), reverse=True):
            resolved = path.resolve(strict=False)
            if path in self.preexisting or resolved in self.preexisting_resolved:
                continue
            if resolved != self.directory and self.directory not in resolved.parents:
                continue
            if path.is_file() or path.is_symlink():
                path.unlink()
                removed.append(str(path))
        return sorted(removed)
