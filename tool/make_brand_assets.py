# Writes site/brand/: Caocode's mark and app icon, for upstreams' "Import to
# Caocode" buttons (site/upstreams.html), as images only, no vector.
#
#   python3 -m venv /tmp/brand && /tmp/brand/bin/pip install pillow
#   /tmp/brand/bin/python tool/make_brand_assets.py site/brand
#
# The mark in black and in white, lossless WebP, by height: 12, 18 and 24px
# shown (4:3, so 16, 24 and 32 wide), at 1x, 2x and 3x. The app icon, PNG,
# square, from 16 to 512.
#
#   /tmp/brand/bin/python tool/make_brand_assets.py --extension
#
# writes the browser extension's instead: its icons (browser_extension/icons,
# the 128 one with the margin the Chrome Web Store asks for) and the store's
# small promo tile (docs/browser-extension-store/).
import os
import sys

from PIL import Image, ImageDraw

# The mark on a 56×42 grid (assets' Union.svg), as rectangles x0, y0, x1, y1.
RECTS = [
    (14, 0, 42, 7), (7, 7, 14, 14), (42, 7, 49, 14), (0, 14, 7, 35),
    (49, 14, 56, 35), (14, 21, 22, 28), (35, 21, 43, 28), (7, 35, 49, 42),
]
COLORS = {'black': (0x1B, 0x1A, 0x17), 'white': (0xFF, 0xFF, 0xFF)}
GOLD, ICON_BG = (0xFF, 0xDA, 0x7A), (0x0D, 0x0D, 0x0D)
MARK_HEIGHTS = [12, 18, 24, 36, 48, 54, 72]
ICON_SIZES = [16, 24, 32, 48, 64, 96, 128, 256, 512]

# Drawn this many times larger, then scaled down: edges that fall between
# pixels are blended, not jagged.
SS = 60


def mark(color, height):
    k = SS
    im = Image.new('RGBA', (56 * k, 42 * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for x0, y0, x1, y1 in RECTS:
        d.rectangle((x0 * k, y0 * k, x1 * k - 1, y1 * k - 1), fill=color + (255,))
    return im.resize((height * 4 // 3, height), Image.LANCZOS)


def icon(size):
    # Full bleed: a rounded square, the mark 56 of 92 wide, as on the dock.
    big = 92 * SS // 4 * 4
    k = big / 92
    im = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, big - 1, big - 1), radius=round(21 * k), fill=ICON_BG + (255,))
    for x0, y0, x1, y1 in RECTS:
        d.rectangle((round((x0 + 18) * k), round((y0 + 25) * k),
                     round((x1 + 18) * k) - 1, round((y1 + 25) * k) - 1), fill=GOLD + (255,))
    return im.resize((size, size), Image.LANCZOS)


def main(out):
    os.makedirs(out, exist_ok=True)
    for name in os.listdir(out):
        if name.startswith('caocode-'):
            os.remove(os.path.join(out, name))
    for name, color in COLORS.items():
        for h in MARK_HEIGHTS:
            mark(color, h).save(f'{out}/caocode-mark-{name}-{h}.webp', lossless=True, quality=100, method=6)
    for s in ICON_SIZES:
        icon(s).save(f'{out}/caocode-icon-{s}.png', optimize=True)


def extension():
    out = 'browser_extension/icons'
    os.makedirs(out, exist_ok=True)
    # The toolbar's, full bleed; the store's and the extensions page's 96
    # of 128, as Chrome's guidelines have it.
    for s in (16, 32, 48):
        icon(s).save(f'{out}/icon-{s}.png', optimize=True)
    framed = Image.new('RGBA', (128, 128), (0, 0, 0, 0))
    framed.alpha_composite(icon(96), (16, 16))
    framed.save(f'{out}/icon-128.png', optimize=True)
    store = 'docs/browser-extension-store'
    os.makedirs(store, exist_ok=True)
    tile = Image.new('RGBA', (440, 280), ICON_BG + (255,))
    tile.alpha_composite(mark(GOLD, 96), (220 - 64, 140 - 48))
    tile.convert('RGB').save(f'{store}/promo-small-440x280.png', optimize=True)


if __name__ == '__main__':
    if sys.argv[1] == '--extension':
        extension()
    else:
        main(sys.argv[1])
