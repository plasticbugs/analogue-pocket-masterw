# Mapping the board onto the Analogue Pocket

`docs/hardware.md` says what the board does. This says how the core does it,
and why each memory ended up where it did.

---

## 1. Clocks

One system clock, **96 MHz**, from the core PLL, and a video clock of
**96 / 14 = 6.857 MHz** from the same PLL, so the two stay in a fixed
relationship and the only clock-domain crossings are the Pocket's own.

96 MHz divides exactly into every clock the board has on its 24 MHz side:

| | board | core | divider |
|---|---|---|---|
| 68000 | 12 MHz | 12 MHz | 96 / 8 |
| Z80 | 6 MHz | 6 MHz | 96 / 16 |
| YM2203 | 3 MHz | 3 MHz | 96 / 32 |

The video is the one thing that cannot be exact. The board's dot clock is
27.164 / 4 = 6.791 MHz, which shares no useful ratio with 96 MHz, and a
second PLL running the video in its own domain would buy 1% of dot-clock
accuracy at the price of a clock-domain crossing on every pixel. So the core
runs the video 1% fast and takes the total counts back the other way:

| | board (measured by Guru) | core |
|---|---|---|
| dot clock | 6.791 MHz | 6.857 MHz |
| htotal | ~447.5 | 452 |
| vtotal | 253 | 253 |
| line rate | 15.178 kHz | 15.171 kHz |
| frame rate | 60.000 Hz | 59.96 Hz |

The visible window is the same 320x224 either way, and the line and frame
rates land within 0.05% and 0.07% of the board's. What the extra dot clocks
buy is a slightly longer horizontal blanking, which nothing observes.

Rotation is left to the Pocket: the core emits the arcade's own 320x224
landscape frame and `video.json` declares the 270-degree rotation.

---

## 2. Memories

The romset is 1.6 MB and the sprite framebuffer alone is another 140 KB of
state, so nothing like all of it fits in the Cyclone V's 385 KB of block RAM.
The split follows what each memory needs per clock.

### Block RAM — everything with no time to spare

| | size | blocks |
|---|---|---|
| sprite framebuffer, 2 pages of 320x224x10 | 140 KB | ~140 |
| sprite RAM, scratch and scroll RAM (VCU 0x10000-0x13FFF) | 16 KB | 16 |
| palette RAM, 4096x16 | 8 KB | 8 |
| 68000 main RAM, 8192x16 | 16 KB | 16 |
| Z80 RAM, 4096x8 | 4 KB | 4 |
| line buffer, ROM caches | — | ~12 |

The framebuffer has to be here: the sprite engine writes about one pixel per
clock for a hundred thousand clocks every vblank, which no external memory on
the Pocket can sustain. Ten bits per pixel, not eight: the value the chip
stores is `(colour & 0x3F) * 16 + pen`.

The two pages are separate memories on purpose. The chip clears the page it
is leaving and paints the page it is about to show, and those are different
pages, so the core does both at once and the whole job fits in vblank with
room to spare.

### Pocket SRAM — VRAM

The 64 KB of tilemap VRAM (32768 x 16) goes in the Pocket's 256 KB SRAM. It
is read about 120 times per scanline by the three tilemap renderers and
occasionally by the 68000, which at roughly seven clocks per access is under
15% of the SRAM's time; keeping it out of block RAM leaves 64 blocks for the
framebuffer.

### SDRAM — the whole ROM image

All 1.6 MB, exactly as `masterw.mra` builds it:

| offset | size | contents |
|---|---|---|
| `0x000000` | 512 KB | 68000 program |
| `0x080000` | 64 KB | Z80 program |
| `0x090000` | 1 MB | graphics, one 32-bit word per 8-pixel row |

Both CPUs read their program through a small direct-mapped cache. The ROM is
read-only, so a cache entry can never go stale -- the cheapest safety there
is. The graphics are read in bursts by the tilemap and sprite engines.

---

## 3. The video pipeline

The chip does two different jobs at two different times, and the core keeps
them apart.

**During vblank** the sprite engine walks the 408-entry table backwards,
painting 16x16 tiles into the framebuffer page that the next frame will show,
while the other page is being cleared. The budget is 29 lines, 183,500 clocks
at 96 MHz. A table of 408 full-size sprites is 104,448 pixels, so even the
impossible worst case fits; the clear is 71,680 writes on the other memory
and overlaps completely.

**During each visible line** the line renderer fills a 320-entry line buffer
of palette indices in the chip's own order -- bg, then framebuffer pixels
with bit 4 set, then fg, then framebuffer pixels with bit 4 clear, then the
text layer -- and the line is read out a pixel at a time through the palette
on the following line. Five passes over 320 pixels plus the tile fetches is
about 2,500 of the 6,328 clocks in a line.

Both are written against `tools/vcu_model.py`, and
`sim/run_video.sh` renders frozen MAME states through the RTL and diffs the
result against the model, which is itself pixel-identical to MAME.

---

## 4. What the core does not reproduce

* **Screen flip** (video control bit 4) is implemented but unverified: the
  game never asks for it, even with the Flip Screen DIP on (`docs/hardware.md`
  section 9).
* **Sprite RAM is read as the sprite engine runs**, not latched at the start
  of vblank. On the board the chip reads it over time too; MAME reads it all
  at one instant. The two differ only if the 68000 writes sprite RAM during
  vblank, which the frozen-state bench cannot see and the system bench can.
* **MAME's zoom is reproduced, including its inaccuracy.** MAME scales each
  16x16 piece of a multi-tile sprite separately rather than scaling the whole
  sprite, and says so in its own comment. Matching the board here would mean
  diverging from the only reference available.

---

## 5. Measured budgets

`sim/run_video.sh` reports what each frame actually cost, at the real dot
rate, on the nine frozen states:

| | worst seen | budget |
|---|---|---|
| sprite pass | 67,133 clocks | 183,500 (29 lines of vblank) |
| line render | 3,675 clocks | 6,328 (one line) |

The busiest frame is gameplay (frame 1000), with its zoomed and multi-tile
sprites. Both have better than 2x headroom, which is why the sprite engine
can stay simple -- fetch a tile, then blit it -- and the line renderer can
make five straight passes over the line rather than interleaving them.
