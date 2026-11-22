"""Check uncompressed release contents for paths from the build machine."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import quote
import zipfile


def path_markers(roots):
    strings = set()
    for root in roots:
        path = str(root)
        if path != root.anchor:
            strings.update((path, path.replace("/", "\\"), quote(path)))
    return {value.encode(encoding).lower() for value in strings
            for encoding in ("utf-8", "utf-16le", "utf-16be")}


def check(data, member, markers):
    folded = data.lower()
    if any(marker in folded for marker in markers):
        raise ValueError(f"Build-machine path found in {member}")


def check_directory(directory, markers):
    for path in directory.rglob("*"):
        name = str(path.relative_to(directory))
        check(os.fsencode(name), name, markers)
        if path.is_symlink():
            check(os.fsencode(os.readlink(path)), name, markers)
        elif path.is_file():
            check(path.read_bytes(), name, markers)


def verify(path, markers):
    if path.is_dir():
        check_directory(path, markers)
    elif path.suffix == ".zip":
        with zipfile.ZipFile(path) as archive:
            check(archive.comment, "ZIP comment", markers)
            for item in archive.infolist():
                check(os.fsencode(item.filename) + item.comment + item.extra, item.filename, markers)
                if not item.is_dir():
                    check(archive.read(item), item.filename, markers)
    elif path.suffix == ".dmg":
        with tempfile.TemporaryDirectory() as mount:
            subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                            "-quiet", "-mountpoint", mount, path], check=True)
            try:
                check_directory(Path(mount), markers)
            finally:
                subprocess.run(["hdiutil", "detach", "-quiet", mount], check=True)
    else:
        raise ValueError(f"Unsupported release artifact: {path.name}")
    print(f"Verified build paths: {path.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", type=Path)
    args = parser.parse_args()
    markers = path_markers([Path.home(), Path(__file__).resolve().parents[1]])
    for artifact in args.artifacts:
        verify(artifact, markers)
