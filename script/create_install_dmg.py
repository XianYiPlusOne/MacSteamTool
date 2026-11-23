#!/usr/bin/env python3
"""Create a drag-to-install DMG with a persistent Finder layout."""

from pathlib import Path
import shutil
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def install_background(source):
    """Create the Finder background used by the installer volume.

    Finder expects the image in a hidden ``.background`` folder.  The artwork
    is kept as SVG in this script and converted by macOS's built-in ``sips``;
    packaging therefore does not depend on Pillow or another image library.
    """
    background = source / ".background"
    if background.exists():
        shutil.rmtree(background)
    background.mkdir()
    svg = background / "dmg-background.svg"
    png = background / "dmg-background.png"
    svg.write_text(
        """<svg xmlns="http://www.w3.org/2000/svg" width="760" height="490" viewBox="0 0 760 490">
  <defs>
    <linearGradient id="wash" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f8fbff"/>
      <stop offset="1" stop-color="#e8efff"/>
    </linearGradient>
  </defs>
  <rect width="760" height="490" rx="22" fill="url(#wash)"/>
  <text x="380" y="54" text-anchor="middle" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="27" font-weight="600" fill="#182230">MacSteamTool</text>
  <text x="380" y="86" text-anchor="middle" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="16" fill="#4d5f78">Drag the app to Applications to install</text>
  <path d="M 270 255 H 490" fill="none" stroke="#4f78ff" stroke-width="7" stroke-linecap="round"/>
  <path d="M 490 255 L 458 232 L 458 278 Z" fill="#4f78ff"/>
  <text x="380" y="458" text-anchor="middle" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="13" fill="#6b7b94">You can eject this disk image after installation.</text>
</svg>
""",
        encoding="utf-8",
    )
    run("sips", "-s", "format", "png", svg, "--out", png,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    svg.unlink()
    # Keep the guide out of the icon grid.  The flag is preserved in the HFS+
    # image and does not affect the app or Applications shortcut.
    run("chflags", "hidden", background)


def create_install_dmg(source, destination, volume_name, app_name):
    source = Path(source)
    (source / "Applications").symlink_to("/Applications", target_is_directory=True)
    install_background(source)
    with tempfile.TemporaryDirectory(prefix="install-dmg-") as temporary:
        writable = Path(temporary) / "layout.dmg"
        mount = Path(temporary) / "volume"
        mount.mkdir()
        run(
            "hdiutil",
            "create",
            "-quiet",
            "-fs",
            "HFS+",
            "-format",
            "UDRW",
            "-volname",
            volume_name,
            "-srcfolder",
            source,
            writable,
        )
        run(
            "hdiutil",
            "attach",
            "-quiet",
            "-noautoopen",
            "-owners",
            "on",
            "-mountpoint",
            mount,
            writable,
        )
        try:
            # Pass paths as arguments, rather than interpolating AppleScript.
            run(
                "osascript",
                "-",
                volume_name,
                app_name,
                str(mount),
                input="""
on run argv
    set applicationName to item 2 of argv
    set volumePath to item 3 of argv
    set volumeAlias to (POSIX file volumePath) as alias
    set backgroundFile to ((volumePath & "/.background/dmg-background.png") as POSIX file) as alias
    tell application "Finder"
        set installerWindow to make new Finder window to volumeAlias
        delay 1
        set current view of installerWindow to icon view
        delay 1
        set toolbar visible of installerWindow to false
        set statusbar visible of installerWindow to false
                set bounds of installerWindow to {240, 160, 1000, 680}
        set viewOptions to icon view options of installerWindow
        set background picture of viewOptions to backgroundFile
                set icon size of viewOptions to 128
                set text size of viewOptions to 15
        tell installerWindow
            set position of item applicationName to {170, 285}
            set position of item "Applications" to {590, 285}
            close
        end tell
        update volumeAlias without registering applications
        delay 2
    end tell
end run
""",
                text=True,
                timeout=60,
            )
            if not (mount / ".DS_Store").is_file():
                raise RuntimeError("Finder did not save the installer window layout")
            run("sync")
        finally:
            run("hdiutil", "detach", "-quiet", mount)
        run("hdiutil", "convert", "-quiet", writable, "-format", "ULMO", "-o", destination)
    run("hdiutil", "verify", "-quiet", destination)
