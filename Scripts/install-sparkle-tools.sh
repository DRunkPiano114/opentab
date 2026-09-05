#!/bin/bash
# Installs the command-line tools of one pinned Sparkle release and prints
# their bin directory on stdout.
#
#   Scripts/install-sparkle-tools.sh [target-directory]
#
# The single stdout line is meant to be captured by the caller, so every
# diagnostic goes to stderr. The zip is pinned by version and by SHA-256.
set -euo pipefail

# The version and the hash change in the same edit. The version must agree
# with `exactVersion` in project.yml, so the tools that sign the appcast come
# from the release the app links. The hash is the sha256 of
# Sparkle-for-Swift-Package-Manager.zip, the same zip SwiftPM downloads for
# the framework: it is the `checksum` in Sparkle's Package.swift at that tag
# and the asset's `digest` in the release API
# (https://api.github.com/repos/sparkle-project/Sparkle/releases/tags/<version>).
SPARKLE_VERSION=2.9.6
SPARKLE_SHA256=8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606

TARGET="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"

echo "Installing Sparkle tools $SPARKLE_VERSION into $TARGET" >&2
curl -fsSL "$URL" -o "$TARGET/sparkle.zip"
actual="$(shasum -a 256 "$TARGET/sparkle.zip" | awk '{print $1}')"
if [ "$actual" != "$SPARKLE_SHA256" ]; then
  rm -f "$TARGET/sparkle.zip"
  echo "sparkle.zip sha256 $actual, expected $SPARKLE_SHA256" >&2
  exit 1
fi
# The archive has no top-level directory: bin/, Sparkle.xcframework/ and the
# text files sit at its root, so it is unpacked into a directory of its own.
# `-o` keeps a re-run from stopping at an overwrite prompt with no tty to
# answer it.
unzip -q -o "$TARGET/sparkle.zip" -d "$TARGET/sparkle"
BIN="$TARGET/sparkle/bin"

"$BIN/generate_appcast" --help >/dev/null
# generate_appcast runs BinaryDelta when older archives are present, and
# sign_update verifies what generate_appcast signed; a bin directory without
# either is a broken layout that only fails later, next to the signing key.
for tool in sign_update BinaryDelta; do
  if [ ! -x "$BIN/$tool" ]; then
    echo "$BIN/$tool is missing or not executable" >&2
    exit 1
  fi
done

echo "$BIN"
