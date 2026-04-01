#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/common-signing.sh"

readonly XCRUN_BIN="/usr/bin/xcrun"
readonly DITTO_BIN="/usr/bin/ditto"
readonly HDIUTIL_BIN="/usr/bin/hdiutil"
readonly CODESIGN_BIN="/usr/bin/codesign"
readonly SPCTL_BIN="/usr/sbin/spctl"
readonly LIPO_BIN="/usr/bin/lipo"
readonly RM_BIN="/bin/rm"
readonly CP_BIN="/bin/cp"
readonly LN_BIN="/bin/ln"
readonly MKDIR_BIN="/bin/mkdir"
readonly MKTEMP_BIN="/usr/bin/mktemp"
readonly DATE_BIN="/bin/date"

APP_NAME="${APP_NAME:-XDR Boost}"
BINARY_NAME="${BINARY_NAME:-xdr-boost}"
BUNDLE_ID="${BUNDLE_ID:-com.xdrboost.app}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$("$DATE_BIN" -u '+%Y%m%d%H%M%S')}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/release/direct}"
BUILD_DIR="$BUILD_ROOT/build"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_ROOT/export}"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
ZIP_PATH="$EXPORT_PATH/$APP_NAME.zip"
DMG_PATH="$EXPORT_PATH/xdr-boost-$VERSION-macos.dmg"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-$APP_NAME}"

SIGNING_IDENTITY_RESOLVED="$(choose_release_signing_identity)"

has_notary_profile=0
if [[ -n "$NOTARY_PROFILE" ]]; then
  has_notary_profile=1
fi

has_notary_apple_id=0
if [[ -n "${APPLE_NOTARY_APPLE_ID:-}" || -n "${APPLE_NOTARY_PASSWORD:-}" || -n "${APPLE_NOTARY_TEAM_ID:-}" ]]; then
  if [[ -z "${APPLE_NOTARY_APPLE_ID:-}" || -z "${APPLE_NOTARY_PASSWORD:-}" || -z "${APPLE_NOTARY_TEAM_ID:-}" ]]; then
    echo "APPLE_NOTARY_APPLE_ID, APPLE_NOTARY_PASSWORD, and APPLE_NOTARY_TEAM_ID must all be set together." >&2
    exit 1
  fi
  has_notary_apple_id=1
fi

notarize_artifact() {
  local artifact_path="$1"

  if [[ "$has_notary_profile" == "1" ]]; then
    "$XCRUN_BIN" notarytool submit "$artifact_path" --keychain-profile "$NOTARY_PROFILE" --wait
    return 0
  fi

  if [[ "$has_notary_apple_id" == "1" ]]; then
    "$XCRUN_BIN" notarytool submit "$artifact_path" \
      --apple-id "$APPLE_NOTARY_APPLE_ID" \
      --password "$APPLE_NOTARY_PASSWORD" \
      --team-id "$APPLE_NOTARY_TEAM_ID" \
      --wait
    return 0
  fi

  return 1
}

"$RM_BIN" -rf "$BUILD_ROOT"
"$MKDIR_BIN" -p "$BUILD_DIR" "$EXPORT_PATH"

BINARY_PATH="$(
  BUILD_DIR="$BUILD_DIR" \
  BINARY_NAME="$BINARY_NAME" \
  ARCHS="$ARCHS" \
  "$ROOT_DIR/scripts/build-local"
)"

SKIP_BUILD=1 \
BINARY_SOURCE_PATH="$BINARY_PATH" \
DIST_DIR="$EXPORT_PATH" \
APP_NAME="$APP_NAME" \
APP_PATH="$APP_PATH" \
BINARY_NAME="$BINARY_NAME" \
BUNDLE_ID="$BUNDLE_ID" \
VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
"$ROOT_DIR/scripts/package-app" >/dev/null

CODESIGN_IDENTITY="$SIGNING_IDENTITY_RESOLVED" \
APP_PATH="$APP_PATH" \
"$ROOT_DIR/scripts/sign-app" "$APP_PATH" >/dev/null

"$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$APP_PATH"
"$LIPO_BIN" -archs "$APP_PATH/Contents/MacOS/$BINARY_NAME"

"$RM_BIN" -f "$ZIP_PATH"
"$DITTO_BIN" -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  notarize_artifact "$ZIP_PATH"
  "$XCRUN_BIN" stapler staple "$APP_PATH"
  "$XCRUN_BIN" stapler validate "$APP_PATH"
  "$SPCTL_BIN" -a -vv "$APP_PATH"

  "$RM_BIN" -f "$ZIP_PATH"
  "$DITTO_BIN" -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
elif [[ "$has_notary_apple_id" == "1" ]]; then
  notarize_artifact "$ZIP_PATH"
  "$XCRUN_BIN" stapler staple "$APP_PATH"
  "$XCRUN_BIN" stapler validate "$APP_PATH"
  "$SPCTL_BIN" -a -vv "$APP_PATH"

  "$RM_BIN" -f "$ZIP_PATH"
  "$DITTO_BIN" -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
fi

DMG_STAGING_DIR="$("$MKTEMP_BIN" -d "${TMPDIR:-/tmp}/xdr-boost-release.XXXXXX")"
cleanup() {
  "$RM_BIN" -rf "$DMG_STAGING_DIR"
}
trap cleanup EXIT

"$CP_BIN" -R "$APP_PATH" "$DMG_STAGING_DIR/$APP_NAME.app"
"$LN_BIN" -s /Applications "$DMG_STAGING_DIR/Applications"

"$RM_BIN" -f "$DMG_PATH"
"$HDIUTIL_BIN" create \
  -volname "$DMG_VOLUME_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

"$CODESIGN_BIN" --force --timestamp --sign "$SIGNING_IDENTITY_RESOLVED" "$DMG_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  notarize_artifact "$DMG_PATH"
  "$XCRUN_BIN" stapler staple "$DMG_PATH"
  "$XCRUN_BIN" stapler validate "$DMG_PATH"
  "$SPCTL_BIN" -a -t open --context context:primary-signature -vv "$DMG_PATH"
elif [[ "$has_notary_apple_id" == "1" ]]; then
  notarize_artifact "$DMG_PATH"
  "$XCRUN_BIN" stapler staple "$DMG_PATH"
  "$XCRUN_BIN" stapler validate "$DMG_PATH"
  "$SPCTL_BIN" -a -t open --context context:primary-signature -vv "$DMG_PATH"
fi

echo "Release artifacts:"
echo "  signing identity: $SIGNING_IDENTITY_RESOLVED"
echo "  app: $APP_PATH"
echo "  zip: $ZIP_PATH"
echo "  dmg: $DMG_PATH"
if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "  notary profile: $NOTARY_PROFILE"
fi
