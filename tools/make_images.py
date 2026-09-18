#!/usr/bin/env python3
"""Make the Pocket's platform banner and core icon from the core's own frames.

    make_images.py <frame.png> [more.png] -o pkg/pocket

The Pocket stores both as raw 16-bit RGB565, little-endian, in its own
portrait orientation:

  * the platform banner is 165 x 521 (`Platforms/_images/<platform>.bin`)
  * the core icon is 36 x 36 (`Cores/<author>.<core>/icon.bin`)

Both were worked out by decoding an existing core's files rather than from a
specification: in those, every second byte is zero, which pins the layout to
little-endian 16-bit, and the row stride that makes the picture hold together
is 165 pixels, not 521.

The frames are the core's own output, which is 320x224 the way the chip draws
it; they are turned a quarter turn anticlockwise here, the same turn
video.json asks the scaler for, so the banner shows the game the way the
cabinet did.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio

BANNER_W, BANNER_H = 165, 521
ICON = 36


def rot90ccw(w, h, rgb):
    """320x224 as the chip draws it -> 224x320 the way the cabinet stood."""
    ow, oh = h, w
    out = bytearray(ow * oh * 3)
    for j in range(oh):
        for i in range(ow):
            sx, sy = w - 1 - j, i
            s = 3 * (sy * w + sx)
            d = 3 * (j * ow + i)
            out[d:d + 3] = rgb[s:s + 3]
    return ow, oh, out


def scale(w, h, rgb, nw, nh):
    """Nearest neighbour; the sources are already close to the target size."""
    out = bytearray(nw * nh * 3)
    for j in range(nh):
        sy = j * h // nh
        for i in range(nw):
            sx = i * w // nw
            s = 3 * (sy * w + sx)
            d = 3 * (j * nw + i)
            out[d:d + 3] = rgb[s:s + 3]
    return out


def blit(dst, dw, src, sw, sh, x0, y0):
    for j in range(sh):
        d = 3 * ((y0 + j) * dw + x0)
        s = 3 * (j * sw)
        dst[d:d + 3 * sw] = src[s:s + 3 * sw]


def to565(w, h, rgb):
    out = bytearray(w * h * 2)
    for i in range(w * h):
        r, g, b = rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2]
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        out[2 * i] = v & 0xFF
        out[2 * i + 1] = v >> 8
    return out


def main():
    args = sys.argv[1:]
    outdir = 'pkg/pocket'
    if '-o' in args:
        i = args.index('-o')
        outdir = args[i + 1]
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)

    frames = []
    for p in args:
        w, h, rgb = pngio.read(p)
        frames.append(rot90ccw(w, h, rgb))

    # banner: the frames stacked down the portrait strip, on black
    banner = bytearray(BANNER_W * BANNER_H * 3)
    n = min(len(frames), 2)
    fh = 236
    tops = [24] if n == 1 else [20, 270]
    for k in range(n):
        w, h, rgb = frames[k]
        s = scale(w, h, rgb, BANNER_W, fh)
        blit(banner, BANNER_W, s, BANNER_W, fh, 0, tops[k])

    os.makedirs(f'{outdir}/Platforms/_images', exist_ok=True)
    with open(f'{outdir}/Platforms/_images/masterw.bin', 'wb') as f:
        f.write(to565(BANNER_W, BANNER_H, banner))
    pngio.write(f'{outdir}/Platforms/_images/masterw_preview.png',
                BANNER_W, BANNER_H, banner)

    # icon: the middle of the first frame, square
    w, h, rgb = frames[0]
    side = min(w, h)
    crop = bytearray(side * side * 3)
    x0, y0 = (w - side) // 2, (h - side) // 2
    for j in range(side):
        s = 3 * ((y0 + j) * w + x0)
        d = 3 * (j * side)
        crop[d:d + 3 * side] = rgb[s:s + 3 * side]
    icon = scale(side, side, crop, ICON, ICON)
    core = f'{outdir}/Cores/plasticbugs.masterw'
    os.makedirs(core, exist_ok=True)
    with open(f'{core}/icon.bin', 'wb') as f:
        f.write(to565(ICON, ICON, icon))
    pngio.write(f'{core}/icon_preview.png', ICON, ICON, icon)

    print(f'wrote {outdir}/Platforms/_images/masterw.bin '
          f'({BANNER_W}x{BANNER_H}) and {core}/icon.bin ({ICON}x{ICON})')


if __name__ == '__main__':
    main()
