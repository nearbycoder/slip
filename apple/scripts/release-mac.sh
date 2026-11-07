#!/usr/bin/env bash
# Builds a universal (Apple silicon + Intel), Developer ID–signed and notarized Slip.app and
# packages it as a styled installer DMG plus a zip.
#
#   apple/scripts/release-mac.sh            archive, notarize and package into build/mac-release
#   apple/scripts/release-mac.sh publish    ...then tag v<version> and publish a GitHub release
#
# Signing and notarization go through the Apple account signed in to Xcode (Xcode › Settings ›
# Accounts), using a cloud-managed Developer ID certificate, so no local certificate or
# notarytool profile is needed. Bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in
# project.yml before each release. RELEASE_NOTES=file.md sets the release notes.
set -euo pipefail

cd "$(dirname "$0")/.."
ACTION="${1:-build}"
TEAM_ID="${TEAM_ID:-4F2YLTHL8T}"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
TAG="v$VERSION"
OUT="build/mac-release"
ARCHIVE="$OUT/Slip.xcarchive"
NOTARIZED="$OUT/notarized"
PKG="$OUT/dist"

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen"; exit 1; }
if [[ "$ACTION" == "publish" ]] && git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists. Bump MARKETING_VERSION in project.yml first."
  exit 1
fi

echo "→ Generating Xcode project"
xcodegen generate --quiet

echo "→ Running SlipKit tests"
swift test --package-path SlipKit --quiet

echo "→ Archiving Slip $VERSION"
rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild archive \
  -project Slip.xcodeproj -scheme Slip-macOS -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates -quiet

echo "→ Signing with Developer ID and uploading for notarization"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates -quiet

echo "→ Waiting for Apple's notary service"
for attempt in $(seq 1 80); do
  rm -rf "$NOTARIZED"
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$NOTARIZED" >"$OUT/notarize.log" 2>&1; then
    break
  fi
  if [[ "$attempt" == 80 ]]; then
    echo "Notarization did not finish in time; see $OUT/notarize.log"
    exit 1
  fi
  sleep 15
done

APP="$NOTARIZED/Slip.app"
echo "→ Verifying"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP" >/dev/null
spctl --assess --type exec "$APP"

echo "→ Packaging"
mkdir -p "$PKG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PKG/Slip-$VERSION.zip"

# Styled installer DMG (background, icon layout, volume icon) via dmgbuild.
if [[ ! -x build/.venv/bin/dmgbuild ]]; then
  python3 -m venv build/.venv
  build/.venv/bin/pip install --quiet dmgbuild
fi
build/.venv/bin/dmgbuild -s Resources/dmg/settings.py -D app="$APP" "Slip" "$PKG/Slip-$VERSION.dmg" >/dev/null
# Version-less copy so …/releases/latest/download/Slip.dmg always points at the newest build.
cp "$PKG/Slip-$VERSION.dmg" "$PKG/Slip.dmg"
(cd "$PKG" && shasum -a 256 "Slip-$VERSION.dmg" "Slip.dmg" "Slip-$VERSION.zip" > SHA256SUMS.txt)

echo "✓ Slip $VERSION is signed, notarized and packaged in $PKG"

if [[ "$ACTION" == "publish" ]]; then
  echo "→ Publishing GitHub release $TAG"
  git tag -a "$TAG" -m "Slip $VERSION"
  git push origin "$TAG"
  NOTES_ARGS=(--generate-notes)
  [[ -n "${RELEASE_NOTES:-}" ]] && NOTES_ARGS=(--notes-file "$RELEASE_NOTES")
  gh release create "$TAG" \
    "$PKG/Slip-$VERSION.dmg" "$PKG/Slip.dmg" "$PKG/Slip-$VERSION.zip" "$PKG/SHA256SUMS.txt" \
    --title "Slip $VERSION" --latest "${NOTES_ARGS[@]}"
fi
