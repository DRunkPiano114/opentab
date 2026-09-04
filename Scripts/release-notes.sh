#!/bin/bash
# Prints the CHANGELOG.md section for one version on stdout.
#
#   Scripts/release-notes.sh <version>
#
# The section becomes the body of the GitHub release, so a missing or blank one
# has to fail: exit 1 when there is no non-empty section, exit 2 without an
# argument. `make tag` and the release workflow both call this, which is what
# makes them refuse the same versions.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: release-notes.sh <version>" >&2
  exit 2
fi

VERSION="$1"
CHANGELOG="$(dirname "$0")/../CHANGELOG.md"

# The bracketed heading is the match: `## [0.1.0] - 2026-09-04`. A prefix
# comparison rather than a regex keeps the version free of escaping rules, and
# the next `## [` ends the section.
HEADING="## [$VERSION]"
notes=$(awk -v h="$HEADING" '
  /^## \[/ { if (on) exit; on = (substr($0, 1, length(h)) == h); next }
  on { print }
' "$CHANGELOG")

case "$notes" in
  *[![:space:]]*)
    printf '%s\n' "$notes"
    ;;
  *)
    echo "CHANGELOG.md has no non-empty \"$HEADING\" section — write the release notes before tagging." >&2
    exit 1
    ;;
esac
