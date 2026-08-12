"""Sanitized JSON-lines diagnostics for packaged helper failures."""

from datetime import datetime, timezone
import json
from pathlib import Path
import re

from ytdp.localization import _redact_diagnostic_details


_SENSITIVE_OPTION = re.compile(
    r"^(?:cookies?|authorization|access[-_]?token|api[-_]?key|signature|sig|"
    r"credential|secret|session[-_]?token|token|password)$",
    re.IGNORECASE,
)


def sanitize_command(command):
    """Return command arguments with authentication values removed."""
    sanitized = []
    redact_next = False
    for value in command or ():
        argument = str(value)
        if redact_next:
            sanitized.append("[REDACTED]")
            redact_next = False
            continue
        option = argument.lstrip("-")
        key, separator, _value = option.partition("=")
        if _SENSITIVE_OPTION.fullmatch(key):
            if separator:
                prefix = argument[: len(argument) - len(option)]
                sanitized.append(f"{prefix}{key}=[REDACTED]")
            else:
                sanitized.append(argument)
                redact_next = True
            continue
        sanitized.append(_redact_diagnostic_details(argument))
    return sanitized


class DiagnosticLogger:
    """Append timestamped, sanitized diagnostic events as JSON lines."""

    def __init__(self, adapter=None, path=None):
        if path is None:
            if adapter is None:
                raise ValueError("adapter or path is required")
            path = adapter.log_dir() / "diagnostics.jsonl"
        self.path = Path(path)

    def log(self, message, stage="application", command=None, **fields):
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "stage": str(stage),
            "message": _redact_diagnostic_details(message),
        }
        if command is not None:
            entry["command"] = sanitize_command(command)
        for key, value in fields.items():
            entry[str(key)] = _redact_diagnostic_details(value)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry, ensure_ascii=False, sort_keys=True))
                handle.write("\n")
        except OSError:
            pass
        return self.path


def sanitize_diagnostic(value):
    """Expose the Task 3 redaction policy to structured reports."""
    return _redact_diagnostic_details(value)


__all__ = ["DiagnosticLogger", "sanitize_command", "sanitize_diagnostic"]
