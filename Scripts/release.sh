#!/bin/bash
# Builds, signs, notarizes, staples and packages a release of OpenTab.
#
#   Scripts/release.sh <subcommand>...      subcommands run in the order given
#   Scripts/release.sh all                  build verify-signature notarize staple package
#   Scripts/release.sh appcast              sign dist/OpenTab-$VERSION.zip with the
#                                           Sparkle key and write dist/appcast.xml
#                                           (release workflow only; not part of all)
#
# Environment:
#   VERSION   required; becomes MARKETING_VERSION (CFBundleShortVersionString)
#             and names the zip, e.g. VERSION=0.1.0 -> dist/OpenTab-0.1.0.zip
#   BUILD     CURRENT_PROJECT_VERSION (CFBundleVersion); defaults to the commit
#             count of HEAD so it increases monotonically along main
#
# appcast only:
#   SPARKLE_BIN             directory holding generate_appcast and sign_update
#   SPARKLE_ED_PRIVATE_KEY  the EdDSA private key (base64 seed); it reaches the
#                           tools on stdin and is never written to a file
#   RELEASE_NOTES_FILE      Markdown embedded into the appcast item; defaults
#                           to release-notes.md at the repository root
#
# Expects OpenTab.xcodeproj to exist already (run `make project` first).
#
# Notarization credentials, one of:
#   CI:     ASC_KEY_PATH (path to the .p8), ASC_KEY_ID, ASC_ISSUER_ID
#   local:  a notarytool keychain profile named "opentab-notary", created once
#           with `xcrun notarytool store-credentials opentab-notary ...`
# The CI variables win when all three are set.
#
# Signing uses the "Developer ID Application" identity from the Release
# configuration in project.yml; it has to be in an unlocked keychain that
# codesign can reach. The script never installs or launches the app.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OpenTab"
TEAM_ID="5RV9PT7PK4"
# Baked into every shipped build (project.yml, Release configuration).
FEED_URL="https://github.com/DRunkPiano114/opentab/releases/latest/download/appcast.xml"
NOTARY_PROFILE="opentab-notary"
DERIVED="$HERE/build/DerivedData-release"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DIST="$HERE/dist"
BUILD_LOG="$HERE/build/xcodebuild-release.log"
NOTARY_TMP=""
trap '[[ -n "$NOTARY_TMP" ]] && rm -rf "$NOTARY_TMP"' EXIT

die() { echo "release.sh: $*" >&2; exit 1; }

# A refused feed must not survive for a later step to upload.
refuse_appcast() { rm -f "$DIST/appcast.xml"; die "$@"; }

require_version() {
  [[ -n "${VERSION:-}" ]] || die "VERSION is required (e.g. VERSION=0.1.0)"
}

require_app() {
  [[ -d "$APP" ]] || die "no Release build at $APP; run 'build' first"
}

require_project() {
  [[ -d "$HERE/$APP_NAME.xcodeproj" ]] || die "no generated project at $HERE/$APP_NAME.xcodeproj; run 'make project' first"
}

cmd_build() {
  require_version
  require_project
  local build="${BUILD:-$(git -C "$HERE" rev-list --count HEAD)}"
  mkdir -p "$HERE/build"
  echo "building $APP_NAME $VERSION ($build) into $DERIVED"
  if ! (cd "$HERE" && xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
      -configuration Release -derivedDataPath "$DERIVED" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$build" \
      build > "$BUILD_LOG" 2>&1); then
    grep -E "error:" "$BUILD_LOG" || tail -20 "$BUILD_LOG"
    die "build failed; full log in $BUILD_LOG"
  fi
  grep -E "warning:|\*\* BUILD" "$BUILD_LOG" | grep -v "Metadata extraction skipped" || true
  local short bundle
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  [[ "$short" == "$VERSION" && "$bundle" == "$build" ]] \
    || die "Info.plist has version $short ($bundle), expected $VERSION ($build)"
}

cmd_verify_signature() {
  require_app
  codesign --verify --deep --strict --verbose=2 "$APP"

  local entitlements
  entitlements="$(codesign -d --entitlements - "$APP" 2>&1)"
  for forbidden in com.apple.security.get-task-allow com.apple.security.cs.disable-library-validation; do
    if grep -q "$forbidden" <<<"$entitlements"; then
      die "release build carries $forbidden; it must not"
    fi
  done
  grep -q com.apple.security.automation.apple-events <<<"$entitlements" \
    || die "release build lost com.apple.security.automation.apple-events"

  local signature
  signature="$(codesign -d -vv "$APP" 2>&1)"
  grep -q 'flags=.*runtime' <<<"$signature" \
    || die "hardened runtime is not enabled"

  local dr
  dr="$(codesign -d -r- "$APP" 2>&1 | grep '^designated => ')"
  echo "$dr"
  grep -q "subject.OU\] = \"$TEAM_ID\"" <<<"$dr" \
    || die "designated requirement is not anchored to team $TEAM_ID"

  # The deep verify above validates every nested signature but does not say
  # who signed it, so it passes on the ad-hoc helpers Sparkle ships, which
  # notarization then rejects.
  local frameworks="$APP/Contents/Frameworks/Sparkle.framework"
  for nested in "$frameworks" "$frameworks/Versions/B/Autoupdate" "$frameworks/Versions/B/Updater.app"; do
    codesign -d -vv "$nested" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" \
      || die "$nested is not signed by team $TEAM_ID"
  done
  [[ ! -e "$frameworks/Versions/B/XPCServices" ]] \
    || die "Sparkle XPC services are still in the bundle"

  local feed key
  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")"
  [[ "$feed" == "$FEED_URL" ]] \
    || die "SUFeedURL is '$feed'"
  key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
  [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || die "SUPublicEDKey is not a base64 EdDSA public key (got '${key:-empty}')"
}

notarytool_credentials() {
  if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    printf '%s\n' --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
  else
    printf '%s\n' --keychain-profile "$NOTARY_PROFILE"
  fi
}

cmd_notarize() {
  require_app
  local creds=()
  while IFS= read -r line; do creds+=("$line"); done < <(notarytool_credentials)

  NOTARY_TMP="$(mktemp -d)"
  local zip="$NOTARY_TMP/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$zip"

  echo "submitting $zip for notarization"
  local output status id
  output="$(xcrun notarytool submit "$zip" "${creds[@]}" --wait 2>&1)" || true
  echo "$output"
  id="$(grep -m1 -E '^[[:space:]]*id: ' <<<"$output" | awk '{print $2}')"
  status="$(grep -E '^[[:space:]]*status: ' <<<"$output" | tail -1 | awk '{print $2}')"
  if [[ "$status" != "Accepted" ]]; then
    if [[ -n "$id" ]]; then
      echo "notarization log for $id:"
      xcrun notarytool log "$id" "${creds[@]}" || true
    fi
    die "notarization did not succeed (status: ${status:-none})"
  fi
}

cmd_staple() {
  require_app
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
}

cmd_package() {
  require_version
  require_app
  mkdir -p "$DIST"
  local zip="$DIST/$APP_NAME-$VERSION.zip"
  rm -f "$zip" "$zip.sha256"
  ditto -c -k --keepParent --sequesterRsrc "$APP" "$zip"
  (cd "$DIST" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
  cat "$zip.sha256"

  local assessment
  assessment="$(spctl --assess --type execute -vv "$APP" 2>&1)"
  echo "$assessment"
  grep -q 'source=Notarized Developer ID' <<<"$assessment" \
    || die "Gatekeeper does not see a notarized Developer ID app"
}

cmd_appcast() {
  require_version
  [[ -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/sign_update" ]] \
    || die "SPARKLE_BIN must name a directory holding generate_appcast and sign_update"
  [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || die "SPARKLE_ED_PRIVATE_KEY is empty"
  local notes="${RELEASE_NOTES_FILE:-$HERE/release-notes.md}"
  [[ -f "$notes" ]] || die "no release notes at $notes"
  local zip="$DIST/$APP_NAME-$VERSION.zip"
  [[ -f "$zip" ]] || die "no release archive at $zip; run 'package' first"

  # generate_appcast reads a whole directory, re-uses any appcast it finds
  # there and moves superseded archives aside, so it gets a directory holding
  # exactly the one zip and its notes. The notes are matched to the archive
  # by basename; with any other name the item ships without notes and
  # nothing warns.
  local appcast="$DIST/appcast.xml"
  local work="$DIST/appcast"
  rm -rf "$work" "$appcast" && mkdir -p "$work"
  cp "$zip" "$work/"
  cp "$notes" "$work/$APP_NAME-$VERSION.md"

  local output
  output="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/DRunkPiano114/opentab/releases/download/v$VERSION/" \
    --link "https://github.com/DRunkPiano114/opentab" \
    --full-release-notes-url "https://github.com/DRunkPiano114/opentab/releases/tag/v$VERSION" \
    --embed-release-notes \
    -o "$appcast" \
    "$work" 2>&1)" || { echo "$output"; refuse_appcast "generate_appcast failed"; }
  echo "$output"
  # A private key that does not match the bundle's SUPublicEDKey is only a
  # warning to generate_appcast, and a feed signed by the wrong key is one
  # every installed copy rejects for good.
  ! grep -q '^Warning:' <<<"$output" || refuse_appcast "generate_appcast warned; refusing to publish"

  grep -q 'sparkle:edSignature="' "$appcast" || refuse_appcast "appcast carries no EdDSA signature"
  grep -q "releases/download/v$VERSION/$APP_NAME-$VERSION.zip" "$appcast" \
    || refuse_appcast "appcast enclosure does not point at the release asset"
  # SURequireSignedFeed in the bundle makes generate_appcast sign the feed
  # itself, as a comment after </rss>; every installed copy demands it.
  grep -q '<!-- sparkle-signatures:' "$appcast" || refuse_appcast "appcast feed is not signed"

  # sign_update verifies with the key it is given, so these prove the feed
  # describes this archive's bytes under the key that signed it; that the key
  # matches the bundle's SUPublicEDKey is the warning check above.
  local signature
  signature="$(sed -n '/sparkle:edSignature=/{s/.*sparkle:edSignature="\([^"]*\)".*/\1/p;q;}' "$appcast")"
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --verify --ed-key-file - "$zip" "$signature" \
    || refuse_appcast "sign_update cannot verify $zip against the appcast signature"
  echo "verified $zip against the appcast signature"
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --verify --ed-key-file - "$appcast" \
    || refuse_appcast "sign_update cannot verify the feed signature of $appcast"
  echo "verified the feed signature of $appcast"
  cat "$appcast"
}

[[ $# -gt 0 ]] || die "usage: $0 build|verify-signature|notarize|staple|package|appcast|all ..."

steps=()
for arg in "$@"; do
  case "$arg" in
    all) steps+=(build verify-signature notarize staple package) ;;
    build|verify-signature|notarize|staple|package|appcast) steps+=("$arg") ;;
    *) die "unknown subcommand: $arg" ;;
  esac
done

for step in "${steps[@]}"; do
  echo "==> $step"
  "cmd_${step//-/_}"
done
