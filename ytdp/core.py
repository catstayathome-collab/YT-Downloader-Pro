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
        stem = re.sub(r'[<>:"/\\|?*]', "_", title).rstrip(". ")
        if not stem:
            stem = "download"
        if stem.split(".", 1)[0].upper() in WINDOWS_RESERVED_NAMES:
            stem = f"_{stem}"
        return stem[:180]
    return re.sub(r'[\\/*?:"<>|]', "", title)


def reserve_output_stem(directory, title, extension, platform_name):
    """Allocate a non-conflicting output stem without creating a file."""
    directory = Path(directory)
    stem = sanitize_filename_stem(title, platform_name)
    extension = extension if extension.startswith(".") else f".{extension}"
    candidate = f"{stem}{extension}"

    if platform_name.lower() == "windows":
        occupied = {path.name.casefold() for path in directory.iterdir()}
        if candidate.casefold() not in occupied:
            return stem
        counter = 1
        while True:
            candidate_stem = f"{stem} ({counter})"
            candidate = f"{candidate_stem}{extension}"
            if candidate.casefold() not in occupied:
                return candidate_stem
            counter += 1

    if not (directory / candidate).exists():
        return stem
    counter = 1
    while True:
        candidate_stem = f"{stem} ({counter})"
        if not (directory / f"{candidate_stem}{extension}").exists():
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
