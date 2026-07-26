#!/usr/bin/env bash
#
# Build, sign, notarize, package, and optionally publish CapMark locally.
#
# Usage:
#   scripts/release-local.sh 1.0.0
#   scripts/release-local.sh 1.0.0 --dmg
#   scripts/release-local.sh 1.0.0 --publish

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$ROOT_DIR/CapMark.xcodeproj"
SCHEME="CapMark"
APP_NAME="CapMark"
DIST_DIR="$ROOT_DIR/dist"
EXPORT_OPTIONS_SOURCE="$ROOT_DIR/Config/ExportOptions-DeveloperID.plist"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-CapMarkNotary}"

VERSION=""
PUBLISH=0
INCLUDE_DMG=0

usage() {
    cat <<EOF
Usage: $(basename "$0") <version> [options]

Builds a local Developer ID-signed and notarized CapMark ZIP.

Options:
  --publish  Create/push tag and upload artifacts to a GitHub Release.
  --dmg      Also create a notarized DMG.
  -h, --help Show this help.

Environment:
  NOTARY_KEYCHAIN_PROFILE  notarytool profile (default: CapMarkNotary)
  BUILD_NUMBER             CFBundleVersion override (default: 1)

--publish requires a clean Git worktree and an authenticated gh CLI.
EOF
}

die() { echo "error: $*" >&2; exit 1; }
require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}
read_build_setting() {
    local key="$1"
    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            value = $0
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
            print value
            exit
        }
    ' <<< "$BUILD_SETTINGS"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --publish) PUBLISH=1 ;;
        --dmg) INCLUDE_DMG=1 ;;
        -*) die "Unknown option: $1" ;;
        *)
            [[ -z "$VERSION" ]] || die "Only one version may be specified."
            VERSION="$1"
            ;;
    esac
    shift
done

[[ -n "$VERSION" ]] || { usage >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
    || die "Version must look like 1.2.3 or 1.2.3-beta.1: $VERSION"

if [[ "$PUBLISH" -eq 1 ]]; then
    require_command git
    require_command gh
    git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
        || die "--publish requires a Git repository."
    [[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] \
        || die "--publish requires a clean Git worktree."
fi

for command in xcodegen xcodebuild security codesign xcrun spctl ditto shasum; do
    require_command "$command"
done
[[ -f "$EXPORT_OPTIONS_SOURCE" ]] \
    || die "Export options not found: $EXPORT_OPTIONS_SOURCE"

echo "▸ Generating Xcode project..."
(cd "$ROOT_DIR" && xcodegen generate)

echo "▸ Reading effective release settings..."
BUILD_SETTINGS="$(
    xcodebuild \
        -project "$PROJECT" \
        -target "$APP_NAME" \
        -configuration Release \
        -showBuildSettings \
        2>/dev/null
)"
TEAM_ID="$(read_build_setting DEVELOPMENT_TEAM)"
BUNDLE_ID="$(read_build_setting PRODUCT_BUNDLE_IDENTIFIER)"

[[ -n "$TEAM_ID" && "$TEAM_ID" != "YOUR_TEAM_ID" ]] \
    || die "Set DEVELOPMENT_TEAM in Config/Shared.xcconfig or Config/Local.xcconfig."
[[ -n "$BUNDLE_ID" && "$BUNDLE_ID" != com.example.* && "$BUNDLE_ID" != com.yourname.* ]] \
    || die "Set a real PRODUCT_BUNDLE_IDENTIFIER."

BUILD_NUMBER="${BUILD_NUMBER:-1}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+)*$ ]] \
    || die "BUILD_NUMBER must contain only numbers and dots: $BUILD_NUMBER"

security find-identity -v -p codesigning 2>/dev/null \
    | grep -Fq 'Developer ID Application:' \
    || die "Developer ID Application certificate is unavailable in the keychain."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/capmark-release.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="$TMP_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$TMP_DIR/export"
NOTARIZE_ZIP="$TMP_DIR/$APP_NAME-$VERSION-notarize.zip"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
ZIP_SHA_PATH="$ZIP_PATH.sha256"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$ZIP_SHA_PATH"

echo "▸ Running tests..."
(cd "$ROOT_DIR" && xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -derivedDataPath "$TMP_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO)

echo "▸ Creating universal archive..."
(cd "$ROOT_DIR" && xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=YES)

EXPORT_OPTIONS="$TMP_DIR/ExportOptions-DeveloperID.plist"
cp "$EXPORT_OPTIONS_SOURCE" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$EXPORT_OPTIONS"

echo "▸ Exporting Developer ID-signed app..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || die "Exported app not found: $APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "▸ Notarizing app..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

echo "▸ Creating release ZIP..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_SHA_PATH")")

VERIFY_DIR="$TMP_DIR/verify"
mkdir -p "$VERIFY_DIR"
ditto -x -k --rsrc "$ZIP_PATH" "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/$APP_NAME.app"
xcrun stapler validate "$VERIFY_DIR/$APP_NAME.app"
spctl --assess --type execute --verbose=2 "$VERIFY_DIR/$APP_NAME.app"

DMG_PATH=""
DMG_SHA_PATH=""
if [[ "$INCLUDE_DMG" -eq 1 ]]; then
    require_command create-dmg
    AC_API_KEY_PROFILE="$NOTARY_KEYCHAIN_PROFILE" VERSION="$VERSION" \
        "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH"
    DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
    DMG_SHA_PATH="$DMG_PATH.sha256"
    (cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_SHA_PATH")")
fi

echo "✓ Local release artifacts created:"
echo "  $ZIP_PATH"
echo "  $ZIP_SHA_PATH"
[[ -n "$DMG_PATH" ]] && echo "  $DMG_PATH" && echo "  $DMG_SHA_PATH"

if [[ "$PUBLISH" -eq 1 ]]; then
    gh auth status >/dev/null 2>&1 || die "Authenticate gh first: gh auth login"
    TAG="v$VERSION"
    HEAD_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"

    if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/tags/$TAG"; then
        [[ "$(git -C "$ROOT_DIR" rev-list -n 1 "$TAG")" == "$HEAD_COMMIT" ]] \
            || die "Tag $TAG exists but does not point to HEAD."
    else
        git -C "$ROOT_DIR" tag -a "$TAG" -m "Release $TAG" "$HEAD_COMMIT"
    fi
    git -C "$ROOT_DIR" push origin "$TAG"

    RELEASE_ASSETS=("$ZIP_PATH" "$ZIP_SHA_PATH")
    [[ -n "$DMG_PATH" ]] && RELEASE_ASSETS+=("$DMG_PATH" "$DMG_SHA_PATH")
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" "${RELEASE_ASSETS[@]}" --clobber
    else
        gh release create "$TAG" "${RELEASE_ASSETS[@]}" \
            --verify-tag \
            --title "$APP_NAME $VERSION" \
            --generate-notes
    fi
    echo "✓ Published GitHub Release: $TAG"
fi
