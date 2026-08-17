#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIRECTORY="$PROJECT_DIRECTORY/dist"
OUTPUT_APP="$OUTPUT_DIRECTORY/Chordsmith.app"
DERIVED_DATA_DIRECTORY="$PROJECT_DIRECTORY/.build/xcode-package"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"

strip_signing_xattrs() {
    local target="$1"
    xattr -cr "$target"
    # File Provider-backed workspaces can immediately restore these directory
    # attributes after a bundle copy. codesign rejects them even when empty.
    xattr -dr 'com.apple.fileprovider.fpfs#P' "$target" 2>/dev/null || true
    xattr -dr com.apple.FinderInfo "$target" 2>/dev/null || true
    xattr -dr com.apple.ResourceFork "$target" 2>/dev/null || true
}

verify_signed_bundle() {
    local target="$1"
    local attempt
    for attempt in 1 2 3; do
        strip_signing_xattrs "$target"
        if codesign --verify --deep --strict --verbose=2 "$target"; then
            return 0
        fi
    done
    return 1
}

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}) .*/\1/p' | head -n 1)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
fi

if [[ "$CONFIGURATION" == "release" ]]; then
    XCODE_CONFIGURATION="Release"
else
    XCODE_CONFIGURATION="Debug"
fi

cd "$PROJECT_DIRECTORY"
xcodebuild \
    -scheme Chordsmith \
    -configuration "$XCODE_CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_DIRECTORY" \
    -destination "platform=macOS,arch=$(uname -m)" \
    CODE_SIGNING_ALLOWED=NO \
    build \
    -quiet
BIN_DIRECTORY="$DERIVED_DATA_DIRECTORY/Build/Products/$XCODE_CONFIGURATION"

STAGING_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
STAGING_APP="$STAGING_DIRECTORY/Chordsmith.app"

mkdir -p "$STAGING_APP/Contents/MacOS"
mkdir -p "$STAGING_APP/Contents/Resources"
install -m 755 "$BIN_DIRECTORY/Chordsmith" "$STAGING_APP/Contents/MacOS/Chordsmith"
install -m 644 "$PROJECT_DIRECTORY/Packaging/Info.plist" "$STAGING_APP/Contents/Info.plist"

# Xcode's SwiftPM integration generates resource accessors that understand the
# standard macOS Contents/Resources location.
for RESOURCE_BUNDLE in "$BIN_DIRECTORY"/*.bundle; do
    if [[ -d "$RESOURCE_BUNDLE" ]]; then
        ditto "$RESOURCE_BUNDLE" "$STAGING_APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
    fi
done

plutil -lint "$STAGING_APP/Contents/Info.plist"
strip_signing_xattrs "$STAGING_APP"
for RESOURCE_BUNDLE in "$STAGING_APP/Contents/Resources"/*.bundle; do
    if [[ -d "$RESOURCE_BUNDLE" ]]; then
        codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$RESOURCE_BUNDLE"
    fi
done
codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$STAGING_APP"
verify_signed_bundle "$STAGING_APP"

mkdir -p "$OUTPUT_DIRECTORY"
if [[ -e "$OUTPUT_APP" ]]; then
    rm -rf "$OUTPUT_APP"
fi
ditto "$STAGING_APP" "$OUTPUT_APP"
verify_signed_bundle "$OUTPUT_APP"

echo "Signed with: $SIGNING_IDENTITY"
echo "$OUTPUT_APP"
