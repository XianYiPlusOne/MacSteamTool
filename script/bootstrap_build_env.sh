#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="check"

usage() {
  cat <<'EOF'
Usage: ./script/bootstrap_build_env.sh [--check|--install]

  --check    Check the local macOS toolchain without changing the machine.
  --install  Install missing Homebrew formulae, then run the same checks.

Homebrew itself is intentionally not installed by this script. Install it from
https://brew.sh first if `brew` is not available.
EOF
}

case "${1:---check}" in
  --check) MODE="check" ;;
  --install) MODE="install" ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "MacSteamTool's release build requires macOS." >&2
  exit 1
fi

macos_version="$(sw_vers -productVersion)"
IFS=. read -r macos_major _ <<< "$macos_version"
if [[ "${macos_major:-0}" -lt 14 ]]; then
  echo "macOS $macos_version is not supported; macOS 14 or later is required." >&2
  exit 1
fi

# Make formulae visible even when this script is called from a non-login shell.
if command -v brew >/dev/null 2>&1; then
  brew_prefix="$(brew --prefix)"
  export PATH="$brew_prefix/bin:$brew_prefix/opt/bison/bin:$brew_prefix/opt/autoconf/bin:$PATH"
fi

if [[ "$MODE" == "install" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required for --install. Install it from https://brew.sh, then rerun this command." >&2
    exit 1
  fi
  echo "==> Installing/updating build formulae"
  brew install cmake bison flex mingw-w64 autoconf python
  brew_prefix="$(brew --prefix)"
  export PATH="$brew_prefix/bin:$brew_prefix/opt/bison/bin:$brew_prefix/opt/autoconf/bin:$PATH"
fi

required_tools=(
  brew git curl python3 swift clang make cmake bison flex autoconf rsync
  lipo codesign hdiutil osascript ditto
  i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc
)
missing=()
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if ! command -v xcrun >/dev/null 2>&1; then
  missing+=(xcrun)
else
  for sdk_tool in swift clang codesign; do
    if ! xcrun --find "$sdk_tool" >/dev/null 2>&1; then
      missing+=("xcrun:$sdk_tool")
    fi
  done
  if ! xcrun --show-sdk-path >/dev/null 2>&1; then
    missing+=(macOS-SDK)
  fi
fi

if ((${#missing[@]})); then
  echo "Missing required build tools: ${missing[*]}" >&2
  if [[ "$MODE" == "check" ]]; then
    echo "Run ./script/bootstrap_build_env.sh --install after installing Homebrew." >&2
  else
    echo "The Homebrew install completed, but the toolchain is still incomplete." >&2
    echo "Install Xcode Command Line Tools with: xcode-select --install" >&2
  fi
  exit 1
fi

echo "Build environment is ready on macOS $macos_version ($(uname -m))."
echo "The first full build still downloads pinned upstream sources and SwiftPM dependencies."
echo "Run: ./script/build_and_run.sh --build"
