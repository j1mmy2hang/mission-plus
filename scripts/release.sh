#!/usr/bin/env bash
#
# release.sh — ship a version of Mission Plus.
#
#   scripts/release.sh build 1.1.0     Local and undoable: set the version, commit and tag, build,
#                                      notarise, package a DMG and an update ZIP, sign the update for
#                                      Sparkle, and add it to appcast.xml.
#   scripts/release.sh publish 1.1.0   The part that can't be taken back: push the tag, create the
#                                      GitHub release with the DMG and ZIP, then push main, which
#                                      puts the new appcast live for every installed copy.
#
# Before `build`, write the version's notes under "## 1.1.0" in CHANGELOG.md.
#
# One-time setup (see README › Releasing):
#   - Developer ID Application certificate in the login Keychain.
#   - Notarisation credentials:  xcrun notarytool store-credentials MissionPlusNotary \
#         --apple-id <apple-id> --team-id F65N98WT62     (prompts for an app-specific password)
#   - Sparkle signing key in the Keychain under the account "MissionPlus" (already created;
#     back it up — losing it strands every installed copy).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="j1mmy2hang/mission-plus"
NOTARY_PROFILE="MissionPlusNotary"
KEY_ACCOUNT="MissionPlus"
APP="$ROOT/build/Mission Plus.app"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

MODE="${1:-}"
VERSION="${2:-}"
[[ "$MODE" =~ ^(build|publish)$ && "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

DMG="$ROOT/build/MissionPlus-$VERSION.dmg"
ZIP="$ROOT/build/MissionPlus-$VERSION.zip"
NOTES="$ROOT/build/notes-$VERSION.md"

# The "## <version>" section of CHANGELOG.md, without its heading.
changelog_notes() {
  python3 - "$ROOT/CHANGELOG.md" "$VERSION" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^## ' + re.escape(sys.argv[2]) + r'\s*\n(.*?)(?=^## |\Z)', text, re.M | re.S)
sys.exit(0) if m is None else print(m.group(1).strip())
PY
}

notarise() {
  # notarytool takes a .zip, .dmg or .pkg; an .app is a directory, so wrap it (ditto keeps the
  # framework's symlinks). A .dmg goes as it is. Stapling writes the ticket into the item itself.
  local target="$1"
  local upload="$target"
  if [[ "$target" == *.app ]]; then
    upload="$ROOT/build/notarise.zip"
    ditto -c -k --keepParent "$target" "$upload"
  fi
  xcrun notarytool submit "$upload" --keychain-profile "$NOTARY_PROFILE" --wait
  [[ "$upload" == "$target" ]] || rm -f "$upload"
  xcrun stapler staple "$target"
}

build() {
  step "Checking"
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "working tree is dirty — commit first"
  [[ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" == main ]] || die "not on main"
  ! git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION already exists"
  [[ -n "$(changelog_notes)" ]] || die "no \"## $VERSION\" section in CHANGELOG.md — write the release notes first"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool profile '$NOTARY_PROFILE' is missing or rejected — see this script's header"
  "$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p >/dev/null 2>&1 \
    || die "no Sparkle key for '$KEY_ACCOUNT' in the Keychain"

  step "Versioning $VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$ROOT/Resources/Info.plist"
  git -C "$ROOT" commit -q -am "Release $VERSION"
  git -C "$ROOT" tag "v$VERSION"

  step "Building"
  "$ROOT/build.sh" --release

  step "Notarising the app"
  notarise "$APP"

  step "Packaging"
  # The update ZIP is made after stapling, so it carries the ticket.
  rm -f "$ZIP" "$DMG"
  ditto -c -k --keepParent "$APP" "$ZIP"
  # The DMG's Applications alias makes dragging the obvious move. That matters: an app run from
  # the disk image or Downloads is translocated to a read-only path where Sparkle can't update it.
  local stage="$ROOT/build/dmg"
  rm -rf "$stage"; mkdir -p "$stage"
  ditto "$APP" "$stage/Mission Plus.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "Mission Plus" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$stage"
  codesign --force --sign "$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application/ {print $2; exit}')" --timestamp "$DMG"

  step "Notarising the DMG"
  notarise "$DMG"

  step "Adding $VERSION to appcast.xml"
  changelog_notes > "$NOTES"
  local signature
  signature="$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$ZIP")"   # sparkle:edSignature="…" length="…"
  python3 "$ROOT/scripts/appcast.py" "$ROOT/appcast.xml" \
    --version "$VERSION" \
    --build "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" \
    --url "https://github.com/$REPO/releases/download/v$VERSION/$(basename "$ZIP")" \
    --signature "$signature" \
    --notes "$NOTES"
  git -C "$ROOT" commit -q -am "Appcast $VERSION"

  printf '\n\033[1;32m✓ %s is built, notarised and ready.\033[0m Nothing has left this Mac.\n' "$VERSION"
  printf '  Try build/%s, then: scripts/release.sh publish %s\n' "$(basename "$DMG")" "$VERSION"
  printf '  To throw it away: git reset --hard v%s~1 && git tag -d v%s\n' "$VERSION" "$VERSION"
}

publish() {
  [[ -f "$DMG" && -f "$ZIP" ]] || die "build/$(basename "$DMG") not found — run: scripts/release.sh build $VERSION"
  git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION does not exist"

  step "Pushing tag v$VERSION"
  git -C "$ROOT" push origin "v$VERSION"

  step "Creating the GitHub release"
  # The DMG also goes up under a fixed name, so /releases/latest/download/MissionPlus.dmg is a
  # download link that never changes.
  local stable="$ROOT/build/MissionPlus.dmg"
  cp "$DMG" "$stable"
  gh release create "v$VERSION" "$stable" "$ZIP" --repo "$REPO" \
    --title "Mission Plus $VERSION" --notes-file "$NOTES"

  # Last, so the appcast never points at files that aren't uploaded yet.
  step "Pushing main (puts the appcast live)"
  git -C "$ROOT" push origin main

  printf '\n\033[1;32m✓ %s is live.\033[0m Installed copies are offered it within a day.\n' "$VERSION"
}

"$MODE"
