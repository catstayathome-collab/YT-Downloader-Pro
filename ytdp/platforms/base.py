"""Base types shared by platform-specific application adapters."""

from abc import ABC, abstractmethod
from pathlib import Path
import sys


APP_NAME = "YT Downloader Pro"


class PlatformAdapter(ABC):
    """Provide filesystem and process behavior for one supported platform."""

    def __init__(self, frozen_dir=None, frozen=None):
        self.frozen = bool(getattr(sys, "frozen", False)) if frozen is None else frozen
        self.frozen_dir = (
            Path(frozen_dir)
            if frozen_dir is not None
            else Path(__file__).resolve().parents[2]
        )

    @abstractmethod
    def settings_dir(self) -> Path:
        """Return the directory holding user settings."""

    @abstractmethod
    def log_dir(self) -> Path:
        """Return the directory holding diagnostic logs."""

    @abstractmethod
    def default_download_dir(self) -> Path:
        """Return the preferred default download directory."""

    @abstractmethod
    def helper_dir(self) -> Path:
        """Return the canonical bundled helper directory."""

    @abstractmethod
    def helper_name(self, tool) -> str:
        """Return a platform-specific helper filename."""

    @abstractmethod
    def language(self) -> str:
        """Return the supported UI language code."""

    @abstractmethod
    def subprocess_kwargs(self) -> dict:
        """Return process options appropriate for helper execution."""

    @abstractmethod
    def validate_architecture(self, path) -> None:
        """Raise ToolchainError when a bundled helper is incompatible."""

    @abstractmethod
    def filename_platform(self) -> str:
        """Return the filename-allocation platform identifier."""

    @abstractmethod
    def js_runtime_name(self) -> str:
        """Return the yt-dlp JavaScript runtime name."""

    @abstractmethod
    def js_runtime_tool(self) -> str:
        """Return the bundled helper name for the JavaScript runtime."""

    @abstractmethod
    def js_runtime_check_args(self) -> tuple[str, ...]:
        """Return arguments used to validate the bundled runtime."""

    @abstractmethod
    def js_runtime_output_marker(self) -> str:
        """Return a marker expected in the runtime validation output."""
