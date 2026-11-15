#!/usr/bin/env bash
# Builds an UNSIGNED OpenParsec.ipa for iPhone / iPad (needs macOS + Xcode).
#
# The result is not signed with any certificate. Sign / install it with AltStore, SideStore,
# Sideloadly, LiveContainer or a similar tool. TrollStore users should use the fake-signed .ipa
# from the main "Xcode - Build" workflow instead.
#
# Usage:   ./scripts/build-unsigned-ipa.sh
# Options (environment variables):
#   CONFIGURATION  Release (default) or Debug
#   OUT_DIR        output folder, default ./build
#   BUILD_NUMBER   if set, written to CFBundleVersion before building (CI uses the run number)
set -euo pipefail

SCHEME="OpenParsec"
CONFIGURATION="${CONFIGURATION:-Release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
ARCHIVE="$OUT_DIR/$SCHEME.xcarchive"
IPA="$OUT_DIR/$SCHEME-unsigned.ipa"

cd "$ROOT"

if [ ! -d "Frameworks/ParsecSDK.framework/Headers" ]; then
	echo "error: the Parsec SDK submodule is missing. Run: git submodule update --init --recursive" >&2
	exit 1
fi

pretty() {
	if command -v xcpretty >/dev/null 2>&1; then xcpretty; else cat; fi
}

echo "==> Toolchain"
xcodebuild -version
xcodebuild -showsdks | grep -i "iphoneos" || true

if [ -n "${BUILD_NUMBER:-}" ]; then
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$SCHEME/Info.plist"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
# absolute, so packaging from inside the staging folder still finds it
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
ARCHIVE="$OUT_DIR/$SCHEME.xcarchive"
IPA="$OUT_DIR/$SCHEME-unsigned.ipa"

echo "==> Archiving $SCHEME ($CONFIGURATION, unsigned)"
xcodebuild archive \
	-project "$SCHEME.xcodeproj" \
	-scheme "$SCHEME" \
	-configuration "$CONFIGURATION" \
	-sdk iphoneos \
	-destination "generic/platform=iOS" \
	-archivePath "$ARCHIVE" \
	CODE_SIGN_IDENTITY="" \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGNING_ALLOWED=NO \
	DEVELOPMENT_TEAM="" \
	| pretty

APP="$ARCHIVE/Products/Applications/$SCHEME.app"
if [ ! -d "$APP" ]; then
	echo "error: $APP was not produced" >&2
	exit 1
fi

# leftovers from the prebuilt SDK framework would make the bundle half-signed; strip them so
# sideloading tools see one consistently unsigned app and sign everything themselves
find "$APP" -type d -name "_CodeSignature" -prune -exec rm -rf {} +
rm -f "$APP/embedded.mobileprovision"

echo "==> Packaging $IPA"
STAGE="$OUT_DIR/ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry -X "$IPA" Payload -x "*/.DS_Store" -x "*/._*")
rm -rf "$STAGE"

PLIST="$APP/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo "?"; }
echo
echo "Built:       $IPA ($(du -h "$IPA" | cut -f1))"
echo "Version:     $(read_plist CFBundleShortVersionString) ($(read_plist CFBundleVersion))"
echo "Built with:  $(read_plist DTSDKName) / Xcode $(read_plist DTXcode)"
echo "Minimum iOS: $(read_plist MinimumOSVersion)"
