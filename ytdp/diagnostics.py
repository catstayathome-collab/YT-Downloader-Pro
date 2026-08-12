"""Sanitized JSON-lines diagnostics for packaged helper failures."""

from datetime import datetime, timezone
import json
from pathlib import Path
import re

from ytdp.localization import _redact_diagnostic_details


_SENSITIVE_PARTS = {
    "authorization",
    "cookie",
    "cookies",
    "credential",
    "password",
    "secret",
    "sig",
    "signature",
    "token",
}
_SENSITIVE_COMPOUNDS = {"access-token", "api-key", "session-token"}
_SENSITIVE_COMPACT_PREFIXES = {
    "accesstoken",
    "apikey",
    "authorization",
    "cookie",
    "cookies",
    "credential",
    "password",
    "secret",
    "sessiontoken",
    "signature",
    "token",
}


def _normalize_key(value):
    return re.sub(r"[^a-z0-9]+", "-", str(value).lower()).strip("-")


def _is_sensitive_key(value):
    normalized = _normalize_key(value)
    compact = normalized.replace("-", "")
    if any(compact.startswith(prefix) for prefix in _SENSITIVE_COMPACT_PREFIXES):
        return True
    if any(
        normalized == compound or normalized.startswith(f"{compound}-")
        for compound in _SENSITIVE_COMPOUNDS
    ):
        return True
    return bool(set(normalized.split("-")) & _SENSITIVE_PARTS)


def _redact_structured(value, key=None):
    if key is not None and _is_sensitive_key(key):
        return "[REDACTED]"
    if isinstance(value, dict):
        return {
            str(nested_key): _redact_structured(nested_value, nested_key)
            for nested_key, nested_value in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [_redact_structured(item) for item in value]
    if isinstance(value, str):
        return _redact_diagnostic_details(value)
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return _redact_diagnostic_details(value)


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
        if _is_sensitive_key(key):
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
            "stage": _redact_diagnostic_details(stage),
            "message": _redact_diagnostic_details(message),
        }
        if command is not None:
            entry["command"] = sanitize_command(command)
        for key, value in fields.items():
            entry[str(key)] = _redact_structured(value, key)
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
