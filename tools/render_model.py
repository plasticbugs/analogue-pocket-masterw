#!/usr/bin/env python3
"""Render dumped MAME states with the TC0180VCU model and diff against MAME.

The model in tools/vcu_model.py is the executable spec the RTL is written
from; this is what proves it is the spec and not a guess.

**Frame alignment.** A dump is taken from MAME's frame notifier, which fires
before the screen is drawn and before the chip's vblank handler and the
68000's interrupt run.  So for the frame MAME finally shows as `pixels` in
dump N:

  * the tilemaps, scroll, palette and control registers are the ones in
    dump N-1 -- the state as the beam finished the previous frame;
  * the sprite framebuffer was painted at the vblank of dump N-2, from the
    sprite RAM in *that* dump.

That is not an artefact of the dumping: it is the hardware's one-frame
sprite latency, and the RTL has to reproduce it too.  `-window` renders a run
of consecutive dumps with this alignment; without it each dump is rendered
against its own pixels, which only matches on a still screen.

`-replay` goes further: it walks every dump in order through the chip's
framebuffer model, so a framebuffer the game never clears (video control bit
0, which is how the title screen's hand-written signature is drawn)
accumulates exactly as it does on the board.  Full dumps in the run are
checked against their pixels; lite dumps only carry the replay forward.

    render_model.py <rom.rom> <dir-or-state.bin>... [-o artifacts/render]
                    [-idx artifacts/model]

`-idx` also writes each frame's 320x224 palette indices as little-endian
16-bit words, which is what the RTL bench (sim/run_video.sh) diffs against.

Writes <frame>.png for the model's output and, when they differ,
<frame>_mame.png and <frame>_diff.png beside it.
"""
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio
import vcu_model as vcu

GFX_BASE, GFX_LEN = 0x090000, 0x100000


def diff_image(a, b):
    """Red where they differ, the model's own pixel dimmed where they agree."""
    out = bytearray(len(a))
    n = 0
    for i in range(0, len(a), 3):
        if a[i:i + 3] != b[i:i + 3]:
            out[i], out[i + 1], out[i + 2] = 255, 0, 0
            n += 1
        else:
            out[i] = a[i] // 4
            out[i + 1] = a[i + 1] // 4
            out[i + 2] = a[i + 2] // 4
    return out, n


def render(st_tiles, st_sprites, gfx):
    """The frame the chip would show, given the two dumps that feed it."""
    fb = [0] * (vcu.W * vcu.H)
    vcu.draw_sprites(st_sprites, gfx, fb)
    return vcu.compose(st_tiles, gfx, fb)


def expand(args):
    out = []
    for a in args:
        if os.path.isdir(a):
            out.extend(sorted(glob.glob(os.path.join(a, 'state_*.bin'))))
            out.extend(sorted(glob.glob(os.path.join(a, 'lite_*.bin'))))
        else:
            out.append(a)
    return out


def main():
    args = sys.argv[1:]
    outdir = 'artifacts/render'
    window = False
    idxdir = None
    if '-idx' in args:
        i = args.index('-idx')
        idxdir = args[i + 1]
        del args[i:i + 2]
    if '-o' in args:
        i = args.index('-o')
        outdir = args[i + 1]
        del args[i:i + 2]
    if '-window' in args:
        args.remove('-window')
        window = True
    replay = '-replay' in args
    if replay:
        args.remove('-replay')
        window = True
    if len(args) < 2:
        sys.exit(__doc__)

    rom = open(args[0], 'rb').read()
    gfx = vcu.Gfx(rom[GFX_BASE:GFX_BASE + GFX_LEN])
    paths = expand(args[1:])
    os.makedirs(outdir, exist_ok=True)
    if idxdir:
        os.makedirs(idxdir, exist_ok=True)

    states = {}
    for p in paths:
        st = vcu.State(p)
        # a frame can have both a full and a lite dump; the full one wins
        if st.full or st.frame not in states:
            states[st.frame] = st

    frames = sorted(states)
    worst = 0
    checked = 0
    fbmodel = vcu.Framebuffer() if replay else None
    fb_after = {}
    if replay:
        # step the framebuffer once per dump, in order; after stepping with
        # dump k the current page is what frame k+1 shows
        for n in frames:
            fbmodel.step(states[n], gfx)
            fb_after[n] = list(fbmodel.current())

    for n in frames:
        if window:
            # pixels in dump n come from tilemaps in n-1 and sprites in n-2
            if n - 1 not in states or n - 2 not in states:
                continue
            st_t, st_s, st_p = states[n - 1], states[n - 2], states[n]
        else:
            st_t = st_s = st_p = states[n]
        if not st_p.full or not st_t.full:
            continue
        checked += 1
        if replay:
            indices = vcu.compose(st_t, gfx, fb_after[n - 2])
        else:
            indices = render(st_t, st_s, gfx)
        # MAME's screen_update fills an *indexed* bitmap; the palette lookup
        # happens when the frame is handed out, so screen:pixels() uses the
        # palette as it stands at this dump, not the one the beam saw.  The
        # game repaints palette entries in its vblank interrupt (flashing
        # enemies), so the two differ and the pixel dump's palette is the one
        # that reproduces MAME.  Real hardware looks colours up as the beam
        # scans; the difference is one frame of palette animation.
        if idxdir:
            with open(f'{idxdir}/{st_p.frame}.idx', 'wb') as fh:
                fh.write(b''.join(int(v).to_bytes(2, 'little') for v in indices))
        got = vcu.to_rgb(st_p, indices)
        want = vcu.mame_rgb(st_p)
        d, ndiff = diff_image(got, want)
        worst = max(worst, ndiff)
        tag = f'{st_p.frame:04d}'
        pngio.write(f'{outdir}/{tag}.png', vcu.W, vcu.H, got)
        for suffix, data in (('_mame', want), ('_diff', d)):
            path = f'{outdir}/{tag}{suffix}.png'
            if ndiff:
                pngio.write(path, vcu.W, vcu.H, data)
            elif os.path.exists(path):
                os.remove(path)
        vc = st_t.video_control
        if ndiff:
            print(f'  frame {tag}  vc={vc:02x}  {ndiff:6d} / {vcu.W*vcu.H} pixels differ')
        else:
            print(f'  frame {tag}  vc={vc:02x}  identical to MAME')

    if not checked:
        print('nothing to check (a -window run needs three consecutive dumps)')
        return 1
    print('OK' if worst == 0 else f'FAIL: worst frame differs in {worst} pixels')
    return 0 if worst == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
