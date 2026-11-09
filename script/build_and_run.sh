#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FluentSteam"
APP_BUNDLE="$ROOT_DIR/outputs/Fluent Steam Mac.app"
cd "$ROOT_DIR"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry|--build) ;;
  *) echo "Usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
if [[ "$MODE" != "--build" ]]; then pkill -x "$APP_NAME" >/dev/null 2>&1 || true; fi
swift build
BIN_DIR="$(swift build --show-bin-path)"
STAGING="$ROOT_DIR/work/app-staging"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$STAGING/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/FluentUpdater" "$STAGING/Contents/MacOS/FluentUpdater"
cp "$ROOT_DIR/Resources/UpdatePublicKey.txt" "$STAGING/Contents/Resources/UpdatePublicKey.txt"
cp "$BIN_DIR/FluentSteamWorker" "$STAGING/Contents/MacOS/FluentSteamWorker"
"$ROOT_DIR/script/build_engine.sh"
"$ROOT_DIR/script/build_cloud.sh"
"$ROOT_DIR/script/build_windows.sh"
"$ROOT_DIR/script/build_notproton.sh"
"$ROOT_DIR/script/build_pins.sh"
python3 "$ROOT_DIR/script/build_notproton_kernel.py"
mkdir -p "$STAGING/Contents/Resources/Helpers/NotProtonRepair"
cp "$ROOT_DIR/work/notproton-kernel-source/out/notproton.dylib" "$ROOT_DIR/work/notproton-kernel-source/out/fluent-notproton-repair.json" "$STAGING/Contents/Resources/Helpers/NotProtonRepair/"
# The receipt is resource data, not executable code. Never place JSON in Helpers,
# where deep signing gives it an xattr-only signature lost by ordinary ZIP extraction.
rm -f "$ROOT_DIR/work/notproton-publish/notproton.dylib" "$ROOT_DIR/work/notproton-publish/fluent-notproton-repair.json"
mkdir -p "$STAGING/Contents/Helpers/Manifest"
cp "$ROOT_DIR/work/pins-build/fluent_manifest.dylib" "$STAGING/Contents/Helpers/Manifest/"
mkdir -p "$STAGING/Contents/Helpers/Cloud"
cp "$ROOT_DIR/work/cloud-build/cloud_redirect.dylib" "$ROOT_DIR/work/cloud-build/FluentCloudCLI" "$STAGING/Contents/Helpers/Cloud/"
ditto "$ROOT_DIR/work/steamless-bridge-publish" "$STAGING/Contents/Resources/Helpers/SteamlessBridge"
ditto "$ROOT_DIR/work/engine-publish" "$STAGING/Contents/Resources/Helpers/SteamEngine"
ditto "$ROOT_DIR/work/notproton-publish" "$STAGING/Contents/Helpers/NotProton"
ditto "$ROOT_DIR/work/windows-publish" "$STAGING/Contents/Resources/Helpers/Windows"
chmod +x "$STAGING/Contents/MacOS/$APP_NAME"
for resource in "$BIN_DIR"/*.bundle; do
  if [[ -d "$resource" ]]; then cp -R "$resource" "$STAGING/Contents/Resources/"; fi
done
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then cp "$ROOT_DIR/Resources/AppIcon.icns" "$STAGING/Contents/Resources/AppIcon.icns"; fi
cp "$ROOT_DIR/LICENSE" "$STAGING/Contents/Resources/LICENSE.txt"
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$STAGING/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp -R "$ROOT_DIR/Licenses" "$STAGING/Contents/Resources/Licenses"
cat > "$STAGING/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FluentSteam</string>
<key>CFBundleIdentifier</key><string>dev.fluentsteam.mac</string>
<key>CFBundleName</key><string>Fluent Steam Mac</string>
<key>CFBundleDisplayName</key><string>Fluent Steam Mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.14</string>
<key>CFBundleVersion</key><string>16</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# PE/.NET payloads belong in Resources, where their integrity is sealed as data.
# In Contents/Helpers, codesign gives non-Mach-O DLLs xattr-only signatures that
# disappear when a normal ZIP extractor installs an update.
python3 - "$STAGING" <<'PY_SIGN'
from pathlib import Path
import subprocess, sys
root = Path(sys.argv[1]) / 'Contents/Resources/Helpers'
for attribute in ['com.apple.cs.CodeDirectory', 'com.apple.cs.CodeRequirements', 'com.apple.cs.CodeRequirements-1', 'com.apple.cs.CodeSignature', 'com.apple.cs.CodeResources']:
    subprocess.run(['/usr/bin/xattr', '-rd', attribute, str(root)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
for file in root.rglob('*'):
    if not file.is_file(): continue
    with file.open('rb') as stream: header = stream.read(4)
    if header in magic:
        subprocess.run(['codesign', '--force', '--sign', '-', str(file)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY_SIGN
codesign --force --deep --sign - "$STAGING"
if [[ -d "$APP_BUNDLE" ]]; then
  # Remove only this script's generated bundle, after the new build has succeeded.
  /bin/rm -rf "$APP_BUNDLE"
fi
mv "$STAGING" "$APP_BUNDLE"
case "$MODE" in
  --build) echo "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "FluentSteam"' ;;
  --telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.fluentsteam.mac"' ;;
  --verify) open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "Build and launch verified." ;;
  *) open -n "$APP_BUNDLE" ;;
esac
