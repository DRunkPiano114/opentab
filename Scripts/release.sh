#!/bin/bash
# Builds, signs, notarizes, staples and packages a release of OpenTab.
#
#   Scripts/release.sh <subcommand>...      subcommands run in the order given
#   Scripts/release.sh all                  build verify-signature notarize staple package
#
# Environment:
#   VERSION   required; becomes MARKETING_VERSION (CFBundleShortVersionString)
#             and names the zip, e.g. VERSION=0.1.0 -> dist/OpenTab-0.1.0.zip
#   BUILD     CURRENT_PROJECT_VERSION (CFBundleVersion); defaults to the commit
#             count of HEAD so it increases monotonically along main
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
NOTARY_PROFILE="opentab-notary"
DERIVED="$HERE/build/DerivedData-release"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DIST="$HERE/dist"
BUILD_LOG="$HERE/build/xcodebuild-release.log"
NOTARY_TMP=""
trap '[[ -n "$NOTARY_TMP" ]] && rm -rf "$NOTARY_TMP"' EXIT

die() { echo "release.sh: $*" >&2; exit 1; }

require_version() {
  [[ -n "${VERSION:-}" ]] || die "VERSION is required (e.g. VERSION=0.1.0)"
}

require_app() {
  [[ -d "$APP" ]] || die "no Release build at $APP; run 'build' first"
}

cmd_build() {
  require_version
  local build="${BUILD:-$(git -C "$HERE" rev-list --count HEAD)}"
  mkdir -p "$HERE/build"
  (cd "$HERE" && xcodegen generate --quiet)
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
  ditto -c -k --keepParent "$APP" "$zip"
  (cd "$DIST" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
  cat "$zip.sha256"

  local assessment
  assessment="$(spctl --assess --type execute -vv "$APP" 2>&1)"
  echo "$assessment"
  grep -q 'source=Notarized Developer ID' <<<"$assessment" \
    || die "Gatekeeper does not see a notarized Developer ID app"
}

[[ $# -gt 0 ]] || die "usage: $0 build|verify-signature|notarize|staple|package|all ..."

steps=()
for arg in "$@"; do
  case "$arg" in
    all) steps+=(build verify-signature notarize staple package) ;;
    build|verify-signature|notarize|staple|package) steps+=("$arg") ;;
    *) die "unknown subcommand: $arg" ;;
  esac
done

for step in "${steps[@]}"; do
  echo "==> $step"
  "cmd_${step//-/_}"
done
