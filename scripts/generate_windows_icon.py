#!/usr/bin/env python3
"""Generate and verify the tracked multi-resolution Windows application icon."""

import argparse
import io
import struct
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "assets" / "AppIcon-1024.png"
DEFAULT_OUTPUT = ROOT / "assets" / "AppIcon.ico"
# ICONDIRENTRY dimensions are one byte and encode 256 as zero. The tracked
# 1024 px PNG remains the source master; valid ICO frames stop at 256 px.
REQUIRED_SIZES = (16, 24, 32, 48, 64, 128, 256)


def _resample_filter():
    return getattr(Image, "Resampling", Image).LANCZOS


def _png_frame(source, size):
    resized = source.resize((size, size), _resample_filter())
    payload = io.BytesIO()
    resized.save(payload, format="PNG", optimize=True)
    return payload.getvalue()


def _write_ico(frames, output_path):
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    directory_size = 6 + (16 * len(frames))
    offset = directory_size
    entries = []
    payloads = []
    for size, payload in frames:
        dimension = 0 if size == 256 else size
        entries.append(
            struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(payload), offset)
        )
        payloads.append(payload)
        offset += len(payload)
    with output_path.open("wb") as output:
        output.write(struct.pack("<HHH", 0, 1, len(entries)))
        output.writelines(entries)
        output.writelines(payloads)


def read_ico_sizes(path):
    """Return image dimensions encoded by every ICO directory payload."""
    data = Path(path).read_bytes()
    if len(data) < 6:
        raise ValueError("ICO header is truncated")
    reserved, image_type, count = struct.unpack_from("<HHH", data)
    if reserved != 0 or image_type != 1 or count < 1 or len(data) < 6 + (16 * count):
        raise ValueError("invalid ICO directory")
    sizes = set()
    for index in range(count):
        entry = struct.unpack_from("<BBBBHHII", data, 6 + (16 * index))
        width_byte, height_byte, _colors, _reserved, _planes, _bits, length, offset = entry
        if offset + length > len(data):
            raise ValueError("ICO payload is truncated")
        payload = data[offset:offset + length]
        with Image.open(io.BytesIO(payload)) as frame:
            frame.load()
            size = frame.size
        declared = (width_byte or 256, height_byte or 256)
        if size != declared:
            raise ValueError(f"ICO directory size {declared} disagrees with payload {size}")
        if declared in sizes:
            raise ValueError(f"duplicate ICO directory size: {declared}")
        sizes.add(size)
    return sizes


def generate_icon(source_path=DEFAULT_SOURCE, output_path=DEFAULT_OUTPUT):
    """Generate all required PNG-compressed ICO frames from the 1024 px master."""
    source_path = Path(source_path)
    output_path = Path(output_path)
    with Image.open(source_path) as source:
        source.load()
        if source.size != (1024, 1024):
            raise ValueError(f"icon master must be exactly 1024x1024, got {source.size}")
        rgba = source.convert("RGBA")
        frames = [(size, _png_frame(rgba, size)) for size in REQUIRED_SIZES]
    _write_ico(frames, output_path)
    actual_sizes = read_ico_sizes(output_path)
    required_sizes = {(size, size) for size in REQUIRED_SIZES}
    if actual_sizes != required_sizes:
        output_path.unlink(missing_ok=True)
        raise ValueError(f"ICO frame sizes must be {sorted(required_sizes)}, got {sorted(actual_sizes)}")
    return output_path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    options = parser.parse_args(argv)
    print(generate_icon(options.source, options.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
