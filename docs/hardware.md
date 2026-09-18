# Master of Weapon — Taito B System hardware

Everything here is taken from MAME 0.288 (`ref/mame/`, fetched verbatim) or
measured from the running game with the Lua probes in `tools/`. Where a fact
was measured, the probe that measured it is named.

Board: `B SYSTEM K1100424A / J1100181A`, Taito 1989, MAME set `masterw`
(World). `masterwu` (US) and `masterwj` (Japan) differ only in the coinage DIP
table and one program ROM; `yukiwo` is a prototype on the same board.

---

## 1. Chips and clocks

| Part | Role | Clock |
|---|---|---|
| MC68000P12 | main CPU | 24 MHz / 2 = **12 MHz** |
| Z80B | sound CPU | 24 MHz / 4 = **6 MHz** |
| YM2203 (OPN) | FM + SSG + two 8-bit ports | 24 MHz / 8 = **3 MHz** |
| YM3014B | serial DAC behind the YM2203 | 24 MHz / 24 = 1 MHz |
| TC0180VCU | tilemaps, sprites, video timing, interrupts | 27.164 MHz / 4 = **6.791 MHz** |
| TC0260DAR | palette DAC / RGB output | — |
| TC0040IOC | inputs, DIPs, coin lockout/counters, watchdog | — |
| PC060HA | 68000 ↔ Z80 communication unit (CIU) | — |

Crystals: 24 MHz (CPUs and FM) and 27.164 MHz (video). They are unrelated, so
the design has two clock domains on the real board.

Guru measured **HSync 15.1782 kHz, VSync 60.0000 Hz** on the PCB. MAME models
the screen as 512×256 total with a 320×224 visible window at a nominal 60 Hz;
it does not model the real dot clock. 27.164 MHz / 2 = 13.582 MHz with
htotal = 895 half-pixels and vtotal = 253 gives 15.1754 kHz and 59.98 Hz,
within 0.02% of both measurements, and is what this core targets
(see `docs/core-design.md` once the video timing is written).

The monitor is rotated: MAME declares `ROT270`, so the tube is portrait with
the 320-pixel axis vertical.

---

## 2. ROMs

MAME set `masterw`, region layout as MAME loads it:

| Region | File | Size | CRC32 | Placement |
|---|---|---|---|---|
| `maincpu` | `b72_06.33` | 128 KB | `ae848eff` | offset 0, **even** bytes (high byte of each word) |
| `maincpu` | `b72_12.24` | 128 KB | `7176ce70` | offset 1, **odd** bytes |
| `maincpu` | `b72_04.34` | 128 KB | `141e964c` | offset 0x40000, even |
| `maincpu` | `b72_03.25` | 128 KB | `f4523496` | offset 0x40001, odd |
| `audiocpu` | `b72_07.30` | 64 KB | `2b1a946f` | offset 0 |
| `tc0180vcu` | `b72-02.6` | 512 KB | `843444eb` | offset 0 — bit planes 0 and 1 |
| `tc0180vcu` | `b72-01.5` | 512 KB | `a24ac26e` | offset 0x80000 — bit planes 2 and 3 |
| `plds` | `b72-08.ic3`, `b72-09.ic23`, `b72-10.ic32` | 260 B each | — | PAL16L8 dumps, not used by emulation |

Main program is 512 KB of 16-bit words; the two 128 KB ROM pairs are
byte-interleaved. Graphics are 1 MB total, split in halves by bit plane.

The `plds` region is required by MAME to start but is never read. The romset
the user supplied does not contain them, so `tools/shadow_romset.sh` builds a
symlink farm with placeholder PLD files for MAME's benefit; the core and the
ROM builder ignore them entirely.

---

## 3. 68000 memory map

From `taitob_state::masterw_map` (`ref/mame/taito_b.cpp:542`).

| Range | Width | Contents |
|---|---|---|
| `000000-07FFFF` | 16 | program ROM, 512 KB |
| `200000-203FFF` | 16 | main RAM, 16 KB |
| `400000-47FFFF` | 16 | TC0180VCU (see §4) |
| `600000-601FFF` | 16 | palette RAM, 4096 words |
| `800000-800003` | 8 (high byte) | TC0040IOC |
| `A00000-A00003` | 8 (high byte) | PC060HA |

Everything else is unmapped. Reads of `A00000` are explicitly `nopr` (the
68000 does a read-modify-write there that must not disturb the CIU).

### TC0040IOC at 800000

Byte accesses on the **high** half of each word (`umask16(0xff00)`).

| Address | Read | Write |
|---|---|---|
| `800000` | value of the selected port | write to the selected register |
| `800002` | 0, and kicks the watchdog | select port/register index |

Port indices (`tc0040ioc_device::portreg_r`, `ref/mame/taitoio.cpp:151`):

| Index | Read | Write |
|---|---|---|
| 0 | DSWA | — |
| 1 | DSWB | — |
| 2 | IN0 — player 1 | — |
| 3 | IN1 — player 2 | — |
| 4 | last value written | coin lockout (bits 0,1) and counters (bits 2,3) |
| 7 | IN2 — system | — |
| other | `0xFF` | ignored |

All inputs are **active low**.

| Bit | IN0 / IN1 | IN2 |
|---|---|---|
| 0 | up | tilt |
| 1 | down | service |
| 2 | left | coin 1 |
| 3 | right | coin 2 |
| 4 | button 1 | — |
| 5 | button 2 | — |
| 6 | — | start 1 |
| 7 | — | start 2 |

DSWA (SW1) and DSWB (SW2), also active low, as MAME lists them: cabinet, flip
screen, service mode, demo sounds, coin A, coin B; difficulty, bonus life,
lives, unused, ship type.

### PC060HA at A00000

Byte accesses on the high half (`master_port_w` at `A00000`, `master_comm_r/w`
at `A00002`). The CIU is a four-nibble mailbox in each direction plus a status
byte; `ref/mame/taitosnd.cpp` is the whole of it and the core implements it
literally. Writing mode 4 from the 68000 side drives the Z80's reset line;
the Z80 writing mode 5 or 6 disables or enables its own NMI.

---

## 4. TC0180VCU

Mapped at `400000`; sub-addresses below are relative to that
(`tc0180vcu_device::tc0180vcu_memrw`, `ref/mame/tc0180vcu.cpp:39`).

| Sub-range | Contents |
|---|---|
| `00000-0FFFF` | VRAM, 32768 words: eight 4096-word pages |
| `10000-1197F` | sprite RAM, 408 entries × 16 bytes |
| `11980-137FF` | plain RAM, not used by the video chip |
| `13800-13FFF` | scroll RAM, 1024 words |
| `18000-1801F` | 16 control registers |
| `40000-7FFFF` | sprite framebuffer, two pages (see §4.4) |

### 4.1 Control registers

Written as the **high byte** of each word.

| Reg | Meaning |
|---|---|
| 0 | fg VRAM pages: bits 2-0 tile codes, bits 6-4 attributes |
| 1 | bg VRAM pages, same encoding |
| 2 | fg scroll blocks: lines per block = 256 − value |
| 3 | bg scroll blocks, same |
| 4 | text tile bank 0 (bits 5-0) |
| 5 | text tile bank 1 (bits 5-0) |
| 6 | text VRAM page (bits 3-0), in units of 2048 words |
| 7 | video control (below) |
| 8-15 | unused, always zero |

Video control (reg 7):

| Bit | Meaning |
|---|---|
| 0 | 1 = do **not** erase the sprite framebuffer each frame |
| 3 | sprite priority: 1 = bg, fg, obj, tx; 0 = bg, obj1, fg, obj0, tx |
| 4 | screen flip |
| 5 | video enable (0 blanks the screen to palette entry 0) |
| 6 | framebuffer page to show when bit 7 is set |
| 7 | 1 = do not flip pages each vblank, use bit 6 |

**What Master of Weapon actually writes** (`tools/probe_vcu.lua`, 3601 frames
of boot, attract, a credit and a game):

| Reg | Values seen |
|---|---|
| 0 | `0x10` once — fg codes at word 0x0000, attributes at 0x1000 |
| 1 | `0x32` once — bg codes at word 0x2000, attributes at 0x3000 |
| 2, 3 | `0x00` once — 256 lines per block, i.e. one scroll value per layer |
| 4 | `0x00` once — text bank 0 |
| 5 | `0x01` once — text bank 1 |
| 6 | `0x08` once — text VRAM at word 0x4000 |
| 7 | `0x00`, `0x10`, `0x20`, `0x21`, `0x30` |

So the layout registers are configured once during boot and never change, and
only the video-control register moves. Bits 3, 6 and 7 are never set: the
sprite priority is always the split `bg, obj1, fg, obj0, tx` order, and the
framebuffer always flips every vblank.

Bit 0 is set from frame 2792 onward in that run — it is what draws the
hand-written "Master of Weapon" title (`artifacts/mame/frame_3300.png`): the
signature is a single sprite moving along the stroke, accumulating in a
framebuffer that is never cleared. **Both framebuffer pages are therefore
real state and cannot be optimised into a per-line sprite engine.**

### 4.2 Tilemaps

Three layers, all reading VRAM as 16-bit words:

* **bg** and **fg** — 64×64 tiles of 16×16 pixels. Tile code from page
  `reg[1]`/`reg[0]` bits 2-0, attribute word from bits 6-4 of the same
  register. Attribute: bits 5-0 colour, bit 6 flip X, bit 7 flip Y.
  Colour index = colour base + attribute bits 5-0.
* **tx** — 64×32 tiles of 8×8 pixels, one word each in the page selected by
  `reg[6]`. Word: bits 10-0 char code, bit 11 selects text bank `reg[4]` or
  `reg[5]` which supplies code bits 16-11, bits 15-12 colour.

Colour bases for this game: tx 0x00, fb 0x10, fg 0x20, bg 0x30. Palette index
is `(base + colour) * 16 + pen`, except the framebuffer (§4.4).

The fg and tx layers treat pen 0 as transparent; bg is opaque.

### 4.3 Scrolling

Scroll RAM holds pairs of words `(scrollx, scrolly)`. For layer *plane*
(0 = fg, 1 = bg) with `lines_per_block = 256 − reg[2+plane]`, block *i*
covers screen lines `[i·lpb, (i+1)·lpb − 1]` and takes its scroll from
`scrollram[plane·0x200 + i·2·lpb]` and the word after it. The tilemap is
scrolled by the **negated** value.

Master of Weapon writes 0 to both registers, so `lines_per_block` is 256, one
block covers the screen, and only `scrollram[0]`,`[1]` (fg) and
`scrollram[0x200]`,`[0x201]` (bg) are ever read.

### 4.4 Sprites and the framebuffer

Sprites are not composited per scanline. Once per vblank the chip walks the
sprite table and paints into one of two 8-bit framebuffer pages, and the
display reads that page.

`vblank_update()` (`ref/mame/tc0180vcu.cpp`, end of file), in order:

1. if video control bit 0 is clear, fill the current page with 0;
2. if bit 7 is clear, flip to the other page;
3. draw every sprite into the (new) current page.

Both steps are clipped to the visible area, so only x ∈ [0, 319] and
y ∈ [16, 239] of each page is ever meaningful. Note that step 1 clears the
page that is about to be *left*, and step 3 fills the page about to be
*shown* — different pages, which is what lets the core clear and draw at the
same time.

Sprite entry, 8 words:

| Word | Contents |
|---|---|
| 0 | tile code (16×16 tile, taken modulo 8192) |
| 1 | bits 5-0 colour, bit 14 flip X, bit 15 flip Y |
| 2 | bits 9-0 X, signed (≥ 0x200 means negative) |
| 3 | bits 9-0 Y, signed |
| 4 | bits 15-8 X zoom, bits 7-0 Y zoom (0 = full size, 0xFF = nothing) |
| 5 | bits 15-8 X count − 1, bits 7-0 Y count − 1, for multi-tile sprites |
| 6, 7 | unused |

The table is walked **backwards**, from entry 407 to entry 0, painting over
what is already there, so **entry 0 ends up on top**.

A non-zero word 5 starts a "big sprite": the entry latches the counts, the
position and the zoom, and the following entries (in the backwards walk) are
its tiles, stepping Y first then X. MAME notes its own zoom is not
hardware-exact — it chops the sprite into independently scaled 16×16 pieces
rather than scaling the whole thing — and this core reproduces MAME, which is
what the reference renderer and the frozen-state gate compare against.

The value written per pixel is `(colour & 0x3F) · 16 + pen`, 10 bits, with
pen 0 not written at all. A zero in the framebuffer therefore means "nothing
here". Note this is wider than the 8 bits the CPU-facing read/write handlers
expose — harmless, because Master of Weapon never touches the framebuffer
through the CPU (measured: zero reads and zero writes in 3601 frames).

### 4.5 Composition

`taitob_state::screen_update` (`ref/mame/taito_b_v.cpp`), back to front:

1. bg tilemap (opaque — it defines the background)
2. framebuffer pixels whose bit 4 is **set** ("obj1")
3. fg tilemap (pen 0 transparent)
4. framebuffer pixels whose bit 4 is **clear** ("obj0")
5. tx tilemap (pen 0 transparent)

Bit 4 of the framebuffer value is bit 0 of the sprite's colour code, so a
sprite's colour decides whether it is behind or in front of the foreground.
If video control bit 3 were set the framebuffer would instead be drawn once,
between fg and tx; Master of Weapon never sets it.

Framebuffer pixels map to palette index `0x100 + value`, i.e. colour base
0x10 × 16 plus the 10-bit value.

If video control bit 5 is clear the whole screen is palette entry 0.

### 4.6 Graphics ROM format

The 1 MB graphics region is two 512 KB halves: the first supplies bit planes
0 and 1, the second planes 2 and 3 (`charlayout`/`tilelayout`,
`ref/mame/tc0180vcu.cpp:13`).

An 8×8 character is 16 bytes in each half: two bytes per row, the first
holding plane 0 (or 2), the second plane 1 (or 3), MSB = leftmost pixel.
32768 characters exist.

A 16×16 tile is four consecutive characters — top-left, top-right,
bottom-left, bottom-right — so 64 bytes in each half, and 8192 tiles exist.
The text layer indexes characters, the bg/fg layers and the sprites index
tiles.

---

## 5. Interrupts

The TC0180VCU drives two interrupt lines through an external PAL
(`vblank_callback`, `ref/mame/tc0180vcu.cpp:129`):

* at the start of vblank: the sprite framebuffer is updated (§4.4), then
  **INTH** is asserted → 68000 **IRQ 5**;
* eight scanlines later: INTH is released and **INTL** is asserted → **IRQ 4**;
* at the end of vblank: INTL is released.

Both are auto-vectored and `HOLD_LINE`, so each is cleared when taken. MAME's
own comment records that the real duty cycle has not been measured and that
even the order of the two has not been confirmed; this core follows MAME.

The Z80 has two sources: the YM2203's IRQ on its `INT` line (the chip's
timers), and the PC060HA on `NMI`, gated by the NMI-enable the Z80 itself
writes through CIU mode 6 / mode 5. The 68000 can also hold the Z80 in reset
through CIU mode 4.

The TC0040IOC watchdog resets the board if the 68000 stops reading `800002`.

---

## 6. Z80 memory map

From `taitob_state::masterw_sound_map` (`ref/mame/taito_b.cpp:627`).

| Range | Contents |
|---|---|
| `0000-3FFF` | sound ROM, fixed first 16 KB |
| `4000-7FFF` | sound ROM, banked: one of four 16 KB windows over the same 64 KB |
| `8000-8FFF` | RAM, 4 KB |
| `9000-9001` | YM2203 (address / data) |
| `A000` | PC060HA port select |
| `A001` | PC060HA data |

The bank is selected by the **YM2203's port A**, bits 1-0 — not by a separate
latch (`ymsnd.port_a_write_callback().set_membank(m_audiobank).mask(0x03)`).

The YM2203's four outputs are mixed 0.25 / 0.25 / 0.25 / 0.80 in MAME: the
three SSG channels quiet, the FM loud.

---

## 7. Palette

4096 words at `600000`, format `RGBx_444`: bits 15-12 red, 11-8 green, 7-4
blue, 3-0 unused. Each 4-bit channel expands to 8 bits as `v × 0x11`.

Only indices up to 0x6FF are reachable: tx 0x000-0x0FF, framebuffer
0x100-0x4FF, fg 0x200-0x5FF, bg 0x300-0x6FF.

---

## 8. What still has to be measured

* the real INTH/INTL timing (MAME guesses; the game may not care);
* whether the game ever uses sprite zoom or multi-tile sprites, and how much
  of the 408-entry table is live on a busy frame — this sets the sprite
  engine's cycle budget;
* the SSG's level against the FM. The eight seconds compared against MAME
  play no SSG at all, so its scale is the one number in the core still taken
  on trust; the FM is measured (below).
* what the YM3014B and the board's analogue filters do to the output, which
  MAME does not model for this driver either.

The FM **is** measured. `sim/run_sound.sh` replays MAME's own CIU traffic
into the core's Z80 and YM2203 and compares eight seconds with MAME's
recording of the same:

| | MAME | core | ratio |
|---|---|---|---|
| 120-400 Hz | 12.49 | 12.57 | 1.006 |
| 400-1200 Hz | 5.93 | 5.60 | 0.944 |
| 40-120 Hz | 11.08 | 15.21 | 1.373 |
| RMS | 1312 | 1853 | 1.413 |

The two bands the music occupies are within 6%. The excess below 120 Hz is
low-frequency wander -- the SSG channels are unipolar, as the chip's DAC is,
and the offset is removed by the board's coupling capacitor and by the
Pocket's DC blocker rather than in the mixer.

---

## 9. Measured: what the game never does

Recorded here so nobody re-derives it. All from 3601-frame runs
(`tools/probe_vcu.lua`, `tools/dump_state.lua`) covering boot, attract, a
credit and a game.

* **The CPU never touches the sprite framebuffer.** Zero reads, zero writes.
* **The layout registers are written once at boot** and never change: fg codes
  at VRAM word 0x0000 with attributes at 0x1000, bg at 0x2000/0x3000, text at
  0x4000, text banks 0 and 1, and one scroll block per layer.
* **Video control bit 3 (the alternative sprite priority) is never set**, so
  the composite is always bg, obj1, fg, obj0, tx.
* **Bits 6 and 7 are never set**, so the framebuffer always flips every vblank.
* **Screen flip is effectively unused.** Bit 4 is set only for frames 4-6 of
  boot, while bit 5 has the video disabled, plus one sub-frame write of 0x30
  that is gone before the frame is drawn. Turning the Flip Screen DIP on
  changes nothing: the video-control trace is identical with the DIP on and
  off, frame for frame, over 3601 frames. The core implements flip anyway,
  but it cannot be checked against MAME because the game will not ask for it.
* **Sprite zoom and multi-tile sprites are both used** in normal play -- the
  player's ship and the tanks are 2x2 and 3x3 groups, and some carry a zoom of
  0x60. MAME's zoom is not hardware-exact (it scales each 16x16 piece
  separately); this core reproduces MAME.
* The sprite table is used up to entry 406 of 408.

---

## 10. The YM2203's strobe

The Z80 writes the chip with its own `/WR`, about two Z80 clocks -- 333 ns at
6 MHz, which is one clock of the 3 MHz chip. The core passes that strobe
through unchanged rather than shaping it into exactly one chip clock, because
that is what the board does; jt12 acts on the strobe as a level, so a strobe
that happens to straddle two chip clocks writes the register twice. Every
OPN register is idempotent under a repeat -- key-on is a level, the timer
control's flag resets are edges the chip has already taken -- so the two are
the same, and the audio comparison against MAME is what would show otherwise.
