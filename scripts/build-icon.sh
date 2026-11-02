#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ICON_SOURCE="$PWD/Assets/AppIcon.png"
ICON_SET="$PWD/build/AppIcon.iconset"
mkdir -p "$ICON_SET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICON_SET/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" --out "$ICON_SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o "$PWD/build/AppIcon.icns"
