"""Build the source release, preserving the two relative FreeRuntime links."""
import os
from pathlib import Path
import stat
import zipfile

from verify_release_paths import path_markers, verify


def write_source_zip(root: Path, destination: Path):
    include = ("Package.swift", "Package.resolved", "Sources", "Tests", "Engine", "Native",
               "script", "Resources", "README.md", "README.zh-CN.md", "LICENSE", "Licenses",
               "THIRD-PARTY-NOTICES.md", ".gitignore", ".codex/environments/environment.toml")
    excluded = {"__pycache__", "bin", "obj", ".build", ".swiftpm", ".git", "work", "outputs"}
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for entry in include:
            path = root / entry
            files = sorted(path.rglob("*")) if path.is_dir() else [path]
            for file in files:
                relative = file.relative_to(root)
                if file.is_symlink() or file.name == ".DS_Store" or excluded.intersection(relative.parts):
                    continue
                if file.is_file():
                    archive.write(file, "MacSteamTool/" + relative.as_posix())

        for name in ("compat-defaults.sh", "compat-prefix.sh"):
            link = Path("Resources/FreeRuntime") / name
            target = Path("Native/NotProtonCore/dylib/feats") / name
            target_text = os.readlink(root / link)
            if target_text != os.path.relpath(target, link.parent):
                raise ValueError(f"Unexpected source link target for {link}")
            archive.getinfo("MacSteamTool/" + target.as_posix())
            info = zipfile.ZipInfo("MacSteamTool/" + link.as_posix())
            info.create_system = 3  # Unix ZIP entries carry the file type in the high 16 bits.
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, os.fsencode(target_text))

    # Reading every uncompressed entry also checks its ZIP CRC.
    verify(destination, path_markers([root, Path.home()]))
