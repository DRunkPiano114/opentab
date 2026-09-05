#!/bin/bash
# Installs one pinned xcodegen release and prints its bin directory on stdout.
#
#   Scripts/install-xcodegen.sh [target-directory]
#
# The single stdout line is meant to be appended to GITHUB_PATH or captured
# by the caller, so every diagnostic goes to stderr. The zip is pinned by
# version and by SHA-256. The recorded hash is trust-on-first-use: GitHub
# computes the asset digest over whatever is stored under that filename, so
# it catches a re-upload but is not an upstream signature.
set -euo pipefail

# Whatever `brew install xcodegen` put on the developer machine. xcodegen
# generates the project that gets signed, so the runner has to use the same
# version the change was tested with — bump both together. The version and
# the hash change in the same edit: the hash is the sha256 of xcodegen.zip,
# and the release API reports it as the asset's `digest` field
# (https://api.github.com/repos/yonaskolb/XcodeGen/releases/tags/<version>),
# so it can be re-derived without downloading the zip.
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

TARGET="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"

echo "Installing xcodegen $XCODEGEN_VERSION into $TARGET" >&2
curl -fsSL "$URL" -o "$TARGET/xcodegen.zip"
actual="$(shasum -a 256 "$TARGET/xcodegen.zip" | awk '{print $1}')"
if [ "$actual" != "$XCODEGEN_SHA256" ]; then
  rm -f "$TARGET/xcodegen.zip"
  echo "xcodegen.zip sha256 $actual, expected $XCODEGEN_SHA256" >&2
  exit 1
fi
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
