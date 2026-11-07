#!/usr/bin/env bash
# Builds a universal, Developer ID–signed and notarized Slip.app and zips it as
# Slip-macOS.zip. Signing and notarization go through the Apple account signed in to
# Xcode (cloud-managed Developer ID certificate), so no local certificate or notarytool
# profile is needed.
#
#   apple/scripts/release-mac.sh [out-dir]
#   gh release create vX.Y.Z <out-dir>/Slip-macOS.zip <out-dir>/Slip-macOS.zip.sha256
set -euo pipefail

TEAM=4F2YLTHL8T
cd "$(dirname "$0")/.."
OUT="${1:-build/mac-release}"
rm -rf "$OUT" && mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

command -v xcodegen >/dev/null && xcodegen -q

echo "› Archiving"
xcodebuild -project Slip.xcodeproj -scheme Slip-macOS -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/Slip.xcarchive" \
  DEVELOPMENT_TEAM=$TEAM CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates archive -quiet

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict></plist>
PLIST

echo "› Signing with Developer ID and submitting for notarization"
xcodebuild -exportArchive -archivePath "$OUT/Slip.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates -quiet

echo "› Waiting for notarization"
for _ in $(seq 1 90); do
  if xcodebuild -exportNotarizedApp -archivePath "$OUT/Slip.xcarchive" -exportPath "$OUT/notarized" >"$OUT/notarize.log" 2>&1; then
    break
  fi
  sleep 20
done
APP="$OUT/notarized/Slip.app"
[ -d "$APP" ] || { echo "Notarization did not finish; see $OUT/notarize.log" >&2; exit 1; }

xcrun stapler validate "$APP"
spctl -a -t exec "$APP"

(cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent notarized/Slip.app Slip-macOS.zip \
  && shasum -a 256 Slip-macOS.zip > Slip-macOS.zip.sha256)
echo "✓ $OUT/Slip-macOS.zip"
