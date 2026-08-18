"""Cross-platform filename allocation and display helpers."""

from pathlib import Path
import re


WINDOWS_RESERVED_NAMES = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}


def sanitize_filename_stem(title, platform_name):
    """Return a filesystem-safe title stem for the requested platform."""
    if platform_name.lower() == "windows":
        stem = re.sub(r'[\x00-\x1f<>:"/\\|?*]', "_", title).rstrip(". ")
        if not stem:
            stem = "download"
        if stem.split(".", 1)[0].upper() in WINDOWS_RESERVED_NAMES:
            stem = f"_{stem}"
        return stem[:180]
    return re.sub(r'[\\/*?:"<>|]', "", title)


def reserve_output_stem(directory, title, extension, platform_name):
    """Allocate a stem unused by final, intermediate, or sidecar files."""
    directory = Path(directory)
    stem = sanitize_filename_stem(title, platform_name)
    extension = extension if extension.startswith(".") else f".{extension}"
    case_insensitive = platform_name.lower() == "windows"
    occupied = [path.name.casefold() if case_insensitive else path.name for path in directory.iterdir()]

    def stem_is_occupied(candidate_stem):
        normalized = candidate_stem.casefold() if case_insensitive else candidate_stem
        prefix = f"{normalized}."
        return any(name == normalized or name.startswith(prefix) for name in occupied)

    if case_insensitive:
        if not stem_is_occupied(stem):
            return stem
        counter = 1
        while True:
            suffix = f" ({counter})"
            candidate_stem = f"{stem[:180 - len(suffix)]}{suffix}"
            if not stem_is_occupied(candidate_stem):
                return candidate_stem
            counter += 1

    if not stem_is_occupied(stem):
        return stem
    counter = 1
    while True:
        candidate_stem = f"{stem} ({counter})"
        if not stem_is_occupied(candidate_stem):
            return candidate_stem
        counter += 1


def format_bytes(value):
    """Format a byte count for download progress."""
    if not value:
        return "--"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if value < 1024.0:
            return f"{value:.2f} {unit}"
        value /= 1024.0
    return "--"
