#!/usr/bin/env -S uv run --no-project --python 3.14 python
"""Verify all four platform archives and write their complete SHA256SUMS."""

import argparse
import hashlib
from pathlib import Path


def collect(directory, version):
    lines = []
    for platform in ("macos", "linux"):
        for arch in ("arm64", "x86_64"):
            name = f"aviary-{version.removeprefix('v')}-{platform}-{arch}.tar.gz"
            archive = directory / name
            expected = (directory / f"{name}.sha256").read_text().split()[0]
            with archive.open("rb") as data:
                actual = hashlib.file_digest(data, "sha256").hexdigest()
            if expected != actual:
                raise ValueError(f"Checksum mismatch for {name}")
            lines.append(f"{actual}  {name}\n")
    destination = directory / "SHA256SUMS"
    destination.write_text("".join(lines))
    print(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("version")
    args = parser.parse_args()
    collect(args.directory, args.version)
