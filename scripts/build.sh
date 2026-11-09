#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -m)" != arm64 ]]; then
  echo 'Agent Desktop requires Apple silicon.' >&2
  exit 1
fi

bash scripts/build-session-library.sh
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -qF '"Agent Desktop Local"'; then
    identity='Agent Desktop Local'
  else
    identity=-
    echo 'Signing ad hoc. Create the Agent Desktop Local identity to preserve Keychain access across builds.' >&2
  fi
fi

mkdir -p dist
stage="$(mktemp -d "$PWD/dist/.build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/AgentDesktop.app"
mkdir -p "$app/Contents/"{MacOS,Frameworks,Resources/licenses}
cp "$binary_dir/agent-desktop" "$app/Contents/MacOS/"
cp .build/session-libs/*.dylib "$app/Contents/Frameworks/"
cp resources/Info.plist "$app/Contents/"
cp LICENSE THIRD_PARTY_NOTICES.md licenses/*.txt "$app/Contents/Resources/licenses/"
for library in "$app"/Contents/Frameworks/*.dylib; do
  codesign --force --sign "$identity" --timestamp=none "$library"
done
codesign --force --sign "$identity" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/agent-desktop" doctor | grep -q '"sessionLibraryAvailable" : "true"'
# Replace the bundle as a unit so existing processes can retain their mapped files.
if [[ -d dist/AgentDesktop.app ]]; then
  mv dist/AgentDesktop.app "$stage/previous.app"
fi
if ! mv "$app" dist/AgentDesktop.app; then
  if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" dist/AgentDesktop.app; fi
  exit 1
fi
ln -sfn AgentDesktop.app/Contents/MacOS/agent-desktop dist/agent-desktop
echo "Built: $PWD/dist/agent-desktop"
