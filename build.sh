#!/bin/zsh
# Builds "build/Mission Plus.app".
#
#   ./build.sh            Build for this Mac, signed with your Apple Development identity (daily use).
#   ./build.sh --run      …and launch it.
#   ./build.sh --release  Universal build signed with Developer ID and the hardened runtime, ready to notarise.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Mission Plus.app"
RELEASE=false
RUN=false
for arg in "$@"; do
  case $arg in
    --release) RELEASE=true ;;
    --run) RUN=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if $RELEASE; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MissionPlus"
  IDENTITY=$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/MissionPlus"
  # A stable identity, so macOS keeps the Accessibility and Screen Recording grants across rebuilds.
  # Without one (e.g. a contributor with no Apple certificate), sign ad hoc.
  IDENTITY=$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')
  IDENTITY=${IDENTITY:--}
  SIGN=(codesign --force --sign "$IDENTITY")
fi
[[ -n "$IDENTITY" ]] || { echo "no signing identity found" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sparkle compares CFBundleVersion to decide an update exists; the commit count only ever rises.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
# ditto, not cp: the framework's internal symlinks must survive.
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
  "$APP/Contents/Frameworks/Sparkle.framework"

# Inside out, as Sparkle's docs prescribe: helpers, then the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP"

echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"), build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
if $RUN; then
  pkill -x MissionPlus || true
  sleep 0.5
  open "$APP"
fi
