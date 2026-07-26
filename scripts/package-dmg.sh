#!/usr/bin/env bash
#
# Package a Developer ID-signed CapMark.app into a notarized, stapled DMG.
#
# Usage:
#   AC_API_KEY_PROFILE=CapMarkNotary scripts/package-dmg.sh path/to/CapMark.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_XCCONFIG="$ROOT_DIR/Config/Shared.xcconfig"
DIST_DIR="$ROOT_DIR/dist"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <path/to/CapMark.app>

Notarization credentials:
  AC_API_KEY_PROFILE  notarytool keychain profile (recommended)

Legacy file-based credentials:
  AC_API_KEY_ID       App Store Connect API Key ID
  AC_API_KEY_ISSUER   App Store Connect Issuer ID
  AC_API_KEY_PATH     Path to AuthKey_<KEYID>.p8

Prerequisite:
  create-dmg: brew install create-dmg
EOF
    exit 1
}

die() { echo "error: $*" >&2; exit 1; }

APP="${1:-}"
[[ -n "$APP" ]] || usage
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[[ -d "$APP" ]] || die "App not found: $APP"
[[ "$(basename "$APP")" == "CapMark.app" ]] || die "Expected CapMark.app: $APP"

if [[ -n "${AC_API_KEY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$AC_API_KEY_PROFILE")
else
    : "${AC_API_KEY_ID:?AC_API_KEY_ID or AC_API_KEY_PROFILE is required}"
    : "${AC_API_KEY_ISSUER:?AC_API_KEY_ISSUER is required}"
    : "${AC_API_KEY_PATH:?AC_API_KEY_PATH is required}"
    [[ -f "$AC_API_KEY_PATH" ]] || die "API key file not found: $AC_API_KEY_PATH"
    NOTARY_ARGS=(
        --key "$AC_API_KEY_PATH"
        --key-id "$AC_API_KEY_ID"
        --issuer "$AC_API_KEY_ISSUER"
    )
fi

command -v create-dmg >/dev/null 2>&1 \
    || die "create-dmg not found. Install it with: brew install create-dmg"

read_version() {
    local version
    version="$(
        awk '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            print
            exit
        }' "$SHARED_XCCONFIG"
    )"
    [[ -n "$version" ]] || die "Could not read MARKETING_VERSION."
    echo "$version"
}

VERSION="${VERSION:-$(read_version)}"
DMG="$DIST_DIR/CapMark-${VERSION}.dmg"

echo "▸ Verifying signature..."
codesign --verify --deep --strict "$APP"
spctl --assess -t execute "$APP"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/capmark-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"

mkdir -p "$DIST_DIR"
rm -f "$DMG"

echo "▸ Creating DMG..."
set +e
create-dmg \
    --volname "CapMark" \
    --window-size 600 400 \
    --icon-size 100 \
    --app-drop-link 425 200 \
    "$DMG" \
    "$STAGING"
create_rc=$?
set -e
if [[ $create_rc -ne 0 ]]; then
    [[ -f "$DMG" ]] || die "create-dmg failed (exit $create_rc)."
    echo "  create-dmg reported warnings; continuing with the produced DMG."
fi

echo "▸ Notarizing DMG..."
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess -t open --context context:primary-signature "$DMG"

echo "✓ Done: $DMG"
