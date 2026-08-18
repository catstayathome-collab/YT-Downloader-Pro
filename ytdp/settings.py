"""Resilient, minimal application settings persistence."""

import json
import os
from pathlib import Path
import tempfile


SETTINGS_KEYS = ("download_path", "language")


def load_settings(path):
    """Load supported settings, treating unavailable or invalid files as empty."""
    try:
        values = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, TypeError, ValueError):
        return {}
    if not isinstance(values, dict):
        return {}
    return {
        key: values[key]
        for key in SETTINGS_KEYS
        if isinstance(values.get(key), str)
    }


def save_settings(path, values):
    """Atomically save supported settings without surfacing filesystem failures."""
    destination = Path(path)
    payload = {
        key: values[key]
        for key in SETTINGS_KEYS
        if isinstance(values.get(key), str)
    }
    temporary = None
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            json.dump(payload, handle, ensure_ascii=False)
            handle.flush()
        temporary.replace(destination)
    except (OSError, TypeError):
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
    return None


def valid_output_directory(saved, fallback):
    """Return an existing saved directory, or the supplied safe fallback."""
    try:
        saved_path = Path(saved)
        if saved_path.is_dir() and os.access(saved_path, os.W_OK):
            return saved_path
    except (OSError, TypeError, ValueError):
        saved_path = None
    return Path(fallback)
