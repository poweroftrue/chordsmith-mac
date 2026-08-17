#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
INSTALLED_DIRECTORY="${HOME}/Applications"
INSTALLED_APP="$INSTALLED_DIRECTORY/Chordsmith.app"
PACKAGED_APP="$PROJECT_DIRECTORY/dist/Chordsmith.app"

"$SCRIPT_DIRECTORY/package_app.sh"

mkdir -p "$INSTALLED_DIRECTORY"
if [[ -e "$INSTALLED_APP" ]]; then
    osascript -e 'tell application id "com.poweroftrue.chordsmith" to quit' >/dev/null 2>&1 || true
    rm -rf "$INSTALLED_APP"
fi
ditto "$PACKAGED_APP" "$INSTALLED_APP"
xattr -cr "$INSTALLED_APP"
xattr -dr com.apple.FinderInfo "$INSTALLED_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$INSTALLED_APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
open "$INSTALLED_APP"

echo "Installed and launched $INSTALLED_APP"
