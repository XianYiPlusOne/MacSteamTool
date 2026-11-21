#!/bin/bash
# Prepare an isolated release directory. Registration is committed by FluentCore.
set -euo pipefail
archive="$1"; stage="$2"; cache="$3"
resources="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$stage" "$cache/valve" "$stage/mount"
mounted=0
cleanup() { if [[ "$mounted" == 1 ]]; then /usr/bin/hdiutil detach "$stage/mount" >/dev/null; fi; }
trap cleanup EXIT
echo 'Checking pinned steamplay-mac release…'
echo "4d2446faa89f8c72838ca419df5b76d76a8d9ac52bea11cb47dd731ea83f85a8  $archive" | /usr/bin/shasum -a 256 -c - >/dev/null
/usr/bin/arch -x86_64 /usr/bin/true || { echo 'Rosetta 2 is required.'; exit 1; }
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$stage/mount" "$archive" >/dev/null
mounted=1
payload="$stage/mount/Install steamplay-mac.app/Contents/Resources/payload"
/usr/bin/ditto "$payload/dist/runners/selfbuilt-cx26.3-r2" "$stage/runner"
for helper in overlay-shim.dylib iconmaker appinfo; do
    cp "$payload/notproton/out/$helper" "$stage/$helper"
done
cp "$payload/build/helpers/pe-d3d" "$stage/pe-d3d"
cleanup; mounted=0
rmdir "$stage/mount"
mkdir -p "$stage/bridge" "$stage/wine-config"
echo 'Preparing pinned Valve bridge…'
while read -r kind id file sha; do
    [[ "$kind" == package ]] || continue
    zip="$cache/valve/$file"
    if ! echo "$sha  $zip" | /usr/bin/shasum -a 256 -c - >/dev/null 2>&1; then
        fetched=0
        while read -r _ base; do
            if /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 600 --retry 2 "$base/$file" -o "$zip.part" && echo "$sha  $zip.part" | /usr/bin/shasum -a 256 -c - >/dev/null; then
                mv "$zip.part" "$zip"; fetched=1; break
            fi
        done < <(awk '$1 == "base" { print $0 }' "$resources/valve-packages.manifest")
        [[ "$fetched" == 1 ]] || { echo "Valve package download failed: $id"; exit 1; }
    fi
    mkdir -p "$stage/package-$id"
    /usr/bin/unzip -q -o "$zip" -d "$stage/package-$id"
done < "$resources/valve-packages.manifest"
while read -r kind output package inner sha; do
    [[ "$kind" == file ]] || continue
    source="$stage/package-$package/$inner"
    echo "$sha  $source" | /usr/bin/shasum -a 256 -c - >/dev/null
    mkdir -p "$(dirname "$stage/bridge/$output")"
    cp "$source" "$stage/bridge/$output"
done < "$resources/valve-packages.manifest"
rm -rf "$stage/package-linux" "$stage/package-win64" "$stage/package-win32"
cp "$stage/runner/share/steamplay/steam.exe" "$stage/bridge/steam.exe"
cp "$stage/runner/lib/wine/x86_64-windows/lsteamclient.dll" "$stage/bridge/lsteamclient.dll"
for arch in x86_64-unix i386-windows; do
    mkdir -p "$stage/bridge/$arch"
    cp "$stage/runner/lib/wine/$arch"/lsteamclient.* "$stage/bridge/$arch/"
done
test -x "$stage/runner/lib/wine/x86_64-unix/wine"
test -f "$stage/runner/lib/renderers/dxmt/x86_64-windows/d3d11.dll"
"$stage/runner/bin/wine" --version
echo 'Prepared Wine 11 + DXMT. No commercial CrossOver installation is used.'
