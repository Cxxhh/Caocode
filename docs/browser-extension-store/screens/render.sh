#!/usr/bin/env bash
# Shoots shot.html into the Chrome Web Store's pictures, beside this file:
# screenshot-<n>-<lang>.png (1280×800), marquee-<lang>.png (1400×560) and
# promo-small-440x280.png,
# 24-bit PNG (no alpha), as the store takes them.
#
#   CHROME="/path/to/Google Chrome for Testing" docs/browser-extension-store/screens/render.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=$(dirname "$here")
chrome=${CHROME:?the path of a Chrome to shoot with}
profile=$(mktemp -d)
trap 'rm -rf "$profile"' EXIT

shoot() {
  local query=$1 size=$2 file=$3
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --user-data-dir="$profile" --window-size="$size" --virtual-time-budget=2000 \
    --screenshot="$file" "file://$here/shot.html?$query" 2>/dev/null
  # No alpha: the store takes 24-bit PNG alone.
  python3 -c "import sys; from PIL import Image; Image.open(sys.argv[1]).convert('RGB').save(sys.argv[1], optimize=True)" "$file"
}

for lang in en zh; do
  for n in 1 2 3; do
    shoot "n=$n&lang=$lang" 1280,800 "$out/screenshot-$n-$lang.png"
  done
  shoot "n=marquee&lang=$lang" 1400,560 "$out/marquee-$lang.png"
done
# The store's tiles are not by language: English.
shoot "n=tile&lang=en" 440,280 "$out/promo-small-440x280.png"
ls "$out"/*.png
