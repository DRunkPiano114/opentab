#!/bin/bash
# Installs one pinned xcodegen release and prints its bin directory on stdout.
#
#   Scripts/install-xcodegen.sh [target-directory]
#
# The single stdout line is meant to be appended to GITHUB_PATH, so every
# diagnostic goes to stderr. Upstream publishes no checksum for xcodegen.zip
# (the sha256 Homebrew records is for the source tarball), so this pins the
# version without verifying integrity.
set -euo pipefail

# Whatever `brew install xcodegen` put on the developer machine. xcodegen
# generates the project that gets signed, so the runner has to use the same
# version the change was tested with — bump both together.
XCODEGEN_VERSION=2.46.0

TARGET="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"

echo "Installing xcodegen $XCODEGEN_VERSION into $TARGET" >&2
curl -fsSL "$URL" -o "$TARGET/xcodegen.zip"
# The archive already has an `xcodegen/` root holding bin/ and share/ as
# siblings; unpacking it one level deeper would separate them. `-o` keeps a
# re-run from stopping at an overwrite prompt with no tty to answer it.
unzip -q -o "$TARGET/xcodegen.zip" -d "$TARGET"

version_output="$("$TARGET/xcodegen/bin/xcodegen" --version)"
case "$version_output" in
  *"$XCODEGEN_VERSION"*) ;;
  *)
    echo "xcodegen reports \"$version_output\", expected $XCODEGEN_VERSION" >&2
    exit 1
    ;;
esac

# xcodegen finds its setting presets at ../share/xcodegen relative to the
# binary. Without them it still generates a project, silently missing every
# preset, and --version stays happy.
if [ ! -d "$TARGET/xcodegen/share/xcodegen/SettingPresets" ]; then
  echo "xcodegen setting presets missing under $TARGET/xcodegen/share" >&2
  exit 1
fi

echo "$TARGET/xcodegen/bin"
