#!/bin/sh
# Regenerates every platform's icon files from the master SVGs in assets/.
# Requires rsvg-convert and ImageMagick (`brew install librsvg imagemagick`).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
A="$ROOT/assets"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

png() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

# macOS: Apple's icon grid puts the 824pt body on a 1024 canvas with a soft shadow.
BODY=$(sed -e '1d' -e '$d' "$A/icon.svg")
cat > "$TMP/macos.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <filter id="drop" x="-10%" y="-10%" width="120%" height="125%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14"/>
      <feOffset dy="10"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.3"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <g filter="url(#drop)"><svg x="100" y="100" width="824" height="824" viewBox="0 0 1024 1024">
$BODY
  </svg></g>
</svg>
EOF
MAC="$ROOT/apple/App/macOS/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 128 256 512; do
  png "$TMP/macos.svg" $s "$MAC/icon_${s}x${s}@1x.png"
  png "$TMP/macos.svg" $((s * 2)) "$MAC/icon_${s}x${s}@2x.png"
done

# iOS: full-bleed and opaque; the system applies the corner mask.
png "$A/icon-full-bleed.svg" 1024 "$TMP/ios.png"
magick "$TMP/ios.png" -background "#17a74c" -alpha remove -alpha off \
  "$ROOT/apple/App/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

# Windows: PNG assets plus a multi-resolution .ico.
WIN="$ROOT/windows/src/Slip.App/Assets"
for s in 32 48 256; do png "$A/icon.svg" $s "$WIN/Slip-$s.png"; done
for s in 16 20 24 32 40 48 64 256; do png "$A/icon.svg" $s "$TMP/ico-$s.png"; done
magick "$TMP"/ico-16.png "$TMP"/ico-20.png "$TMP"/ico-24.png "$TMP"/ico-32.png \
  "$TMP"/ico-40.png "$TMP"/ico-48.png "$TMP"/ico-64.png "$TMP"/ico-256.png "$WIN/Slip.ico"

# Linux: hicolor scalable icon.
cp "$A/icon.svg" "$ROOT/linux/data/icons/hicolor/scalable/apps/io.github.nearbycoder.Slip.svg"

# Website.
cp "$A/icon.svg" "$ROOT/site/icon.svg"
cp "$A/mark.svg" "$ROOT/site/mark.svg"
png "$A/icon-full-bleed.svg" 180 "$ROOT/site/apple-touch-icon.png"
png "$A/icon.svg" 512 "$ROOT/site/icon-512.png"

echo "Icons regenerated."
