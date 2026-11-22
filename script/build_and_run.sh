#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacSteamTool"
APP_BUNDLE="$ROOT_DIR/outputs/$APP_NAME.app"
cd "$ROOT_DIR"
if [[ "$MODE" == "--build-host-tools" ]]; then
  mkdir -p "$ROOT_DIR/work" "$ROOT_DIR/outputs/host-tools"
  stage="$(mktemp -d "$ROOT_DIR/outputs/.host-tools.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  for cpu in arm64 x86_64; do
    triple="$cpu-apple-macosx14.0"
    flags=(--scratch-path "${MACSTEAMTOOL_SWIFT_SCRATCH:-$ROOT_DIR/.build}" -c release
           --triple "$triple" -Xswiftc -target -Xswiftc "$triple")
    bin="$(swift build "${flags[@]}" --show-bin-path)"
    mkdir "$stage/$cpu"
    for product in MacSteamToolUpdater MacSteamToolWorker; do
      swift build "${flags[@]}" --product "$product"
      cp "$bin/$product" "$stage/$cpu/$product"
    done
  done
  for product in MacSteamToolUpdater MacSteamToolWorker; do
    lipo -create "$stage/arm64/$product" "$stage/x86_64/$product" -output "$stage/$product"
  done
  native="$ROOT_DIR/work/original-host-tools"
  make -C "$ROOT_DIR/Native/NotProtonCore" -j4 iconmaker appinfo OUT_DIR="$native"
  cp "$native/iconmaker" "$native/appinfo" "$stage/"
  products=(MacSteamToolUpdater MacSteamToolWorker iconmaker appinfo)
  for product in "${products[@]}"; do
    for cpu in arm64 x86_64; do lipo "$stage/$product" -verify_arch "$cpu"; done
    strip -S "$stage/$product"
    codesign --force --sign - "$stage/$product"
    codesign --verify --strict --all-architectures "$stage/$product"
  done
  for product in "${products[@]}"; do mv -f "$stage/$product" "$ROOT_DIR/outputs/host-tools/$product"; done
  echo "Built universal macOS helpers in $ROOT_DIR/outputs/host-tools"
  exit 0
fi
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry|--build) ;;
  *) echo "Usage: $0 [--build|--build-host-tools|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
if [[ "$MODE" != "--build" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x FluentSteam >/dev/null 2>&1 || true
fi
configuration=debug
if [[ "$MODE" == "--build" ]]; then configuration=release; fi
swift build -c "$configuration"
BIN_DIR="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$ROOT_DIR/work" "$ROOT_DIR/outputs"
# Independent staging prevents simultaneous builds from modifying each other.
STAGING="$(mktemp -d "$ROOT_DIR/work/app-staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$STAGING/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/MacSteamToolUpdater" "$STAGING/Contents/MacOS/MacSteamToolUpdater"
cp "$BIN_DIR/MacSteamToolRuntime" "$STAGING/Contents/MacOS/MacSteamToolRuntime"
python3 "$ROOT_DIR/script/bundle_connecttool.py" "$STAGING/Contents/Resources/Helpers/ConnectTool"
cp "$ROOT_DIR/Resources/UpdatePublicKey.txt" "$STAGING/Contents/Resources/UpdatePublicKey.txt"
cp -RL "$ROOT_DIR/Resources/FreeRuntime" "$STAGING/Contents/Resources/"
cp "$BIN_DIR/MacSteamToolWorker" "$STAGING/Contents/MacOS/MacSteamToolWorker"
"$ROOT_DIR/script/build_patch_probe.sh"
"$ROOT_DIR/script/build_cloud.sh"
"$ROOT_DIR/script/build_notproton.sh"
"$ROOT_DIR/script/build_pins.sh"
# The official Steam bootstrap is Intel-only even on Apple silicon. Its launch
# environment must accept both architectures before handing off to native Steam.
for architecture in x86_64 arm64; do
  lipo "$ROOT_DIR/work/cloud-build/cloud_redirect.dylib" -verify_arch "$architecture"
  lipo "$ROOT_DIR/work/pins-build/fluent_manifest.dylib" -verify_arch "$architecture"
done
python3 "$ROOT_DIR/script/build_native_integration.py"
python3 "$ROOT_DIR/script/build_crossover_bridge.py"
python3 "$ROOT_DIR/script/bundle_native_integration.py" "$STAGING/Contents/Resources"
mkdir -p "$STAGING/Contents/Resources/Helpers/NotProtonRepair"
cp "$ROOT_DIR/work/native-integration/notproton.dylib" "$ROOT_DIR/work/native-integration/repair-receipt.json" "$STAGING/Contents/Resources/Helpers/NotProtonRepair/"
# The receipt is resource data, not executable code. Never place JSON in Helpers,
# where deep signing gives it an xattr-only signature lost by ordinary ZIP extraction.
rm -f "$ROOT_DIR/work/macsteamtool-notproton-publish/notproton.dylib" "$ROOT_DIR/work/macsteamtool-notproton-publish/repair-receipt.json"
mkdir -p "$STAGING/Contents/Helpers/Manifest"
cp "$ROOT_DIR/work/pins-build/fluent_manifest.dylib" "$STAGING/Contents/Helpers/Manifest/manifest.dylib"
mkdir -p "$STAGING/Contents/Helpers/Cloud"
cp "$ROOT_DIR/work/cloud-build/cloud_redirect.dylib" "$STAGING/Contents/Helpers/Cloud/"
mkdir -p "$STAGING/Contents/Resources/Helpers/PatchProbe"
cp "$ROOT_DIR/work/patch-probe-publish/PatchProbe.exe" "$STAGING/Contents/Resources/Helpers/PatchProbe/"
ditto "$ROOT_DIR/work/macsteamtool-notproton-publish" "$STAGING/Contents/Helpers/NotProton"
if [[ "$configuration" == release ]]; then
  # The Apple linker records absolute object paths in Mach-O debug symbols.
  strip -S "$STAGING"/Contents/MacOS/* "$STAGING/Contents/Helpers/NotProton/MacSteamToolNotProton"
fi
chmod +x "$STAGING/Contents/MacOS/$APP_NAME"
for resource in "$BIN_DIR"/*.bundle; do
  if [[ -d "$resource" ]]; then cp -R "$resource" "$STAGING/Contents/Resources/"; fi
done
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then cp "$ROOT_DIR/Resources/AppIcon.icns" "$STAGING/Contents/Resources/AppIcon.icns"; fi
cp "$ROOT_DIR/LICENSE" "$STAGING/Contents/Resources/LICENSE.txt"
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$STAGING/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp -R "$ROOT_DIR/Licenses" "$STAGING/Contents/Resources/Licenses"
cat > "$STAGING/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>dev.macsteamtool.app</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.35</string>
<key>CFBundleVersion</key><string>44</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Windows PE payloads belong in Resources, where their integrity is sealed as data.
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
python3 "$ROOT_DIR/script/verify_bundled_cores.py" "$STAGING"
if [[ "$configuration" == release ]]; then
  python3 "$ROOT_DIR/script/verify_release_paths.py" "$STAGING"
fi
if [[ -d "$APP_BUNDLE" ]]; then
  # Remove only this script's generated bundle, after the new build has succeeded.
  /bin/rm -rf "$APP_BUNDLE"
fi
mv "$STAGING" "$APP_BUNDLE"
case "$MODE" in
  --build) echo "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.macsteamtool.app"' ;;
  --verify) open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "Build and launch verified." ;;
  *) open -n "$APP_BUNDLE" ;;
esac
