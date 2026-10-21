#!/bin/zsh
# Builds "build/Mission Plus.app". Usage: ./build.sh [--run]
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Mission Plus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MissionPlus "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# Sign with a stable identity so macOS remembers the Accessibility / Screen Recording grants across rebuilds.
IDENTITY=$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
if [[ "$1" == "--run" ]]; then
  pkill -x MissionPlus || true
  open "$APP"
fi
