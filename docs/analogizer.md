# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

This core supports it (`USE_ANALOGIZER = 1` in `core_top.sv`), with the
pocket-core-template's wrapper and menu scheme. This page is what the player
needs, what the core does, and what has been proven.

## For the player

**Settings are in the core's own menu**, under the game's other options,
like RndMnkIII's own "Pocket Menu" Analogizer cores (the wiki's list calls the
other kind, which reads a shared `analogizer.bin`, "Analogizer File"; this
core does not read that file). The Pocket remembers them per
core.

| entry | options |
|---|---|
| Analogizer | Off (the default), On, On, Pocket off (the picture goes to the CRT only) |
| Analogizer Video | RGBS, RGsB, YPbPr, Y/C NTSC, Y/C PAL (no scandoubler modes: below) |
| SNAC Adapter | None, DB15, NES, SNES, PCE 2-button, PCE 6-button, PCE Multitap, DB15 Fast, SNES A,B<->X,Y, PSX Digital, PSX Digital Fast, PSX Analog, PSX Analog Fast |
| SNAC Assignment | the six below |
| Analogizer H Position | -48 to +11 dots; + moves the picture right on the CRT |
| Analogizer V Position | -24 to +2 lines; + moves the picture down on the CRT |
| Analogizer H Size | -20% to +20%; + wider on the CRT (with the set on its side, the game's height); 15 kHz modes only |

To fit the Pocket's 16 menu entries, four of the core's own left the menu,
each now fixed at the board's factory setting: Scanlines and Shadow Mask
(off; nothing writes their word any more), Coin B (1 coin / 2 credits; only
player 2's coin uses it) and Demo Sounds Off (demo sounds on). The menu's
DIP words start at 0 and are XORed with the factory setting in `core_top`,
so an entry that is gone leaves its switches at factory.

**The CRT stands on its side.** Master of Weapon is a vertical game (MAME
ROT270): the cabinet's monitor lay on its side and the board draws its
picture sideways, which the Pocket's scaler turns for its own screen. The
Analogizer gets the board's picture as drawn, unrotated, so turn the set a
quarter turn anticlockwise as you face it -- its top to the left -- and the
game is upright. Turned the other way it is upside down.

With **Analogizer** off the core behaves exactly as it did without Analogizer
support. The adapter itself is set up as its wiki's
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
says: SNAC switch in position A, 5 V into its USB-C port, the SCART cable's
audio jack in the Pocket's headphone socket.

**Width.** "Analogizer H Size" makes the 15 kHz picture narrower or wider
about its centre, in percent; with the set on its side, that is the game's
height. A CRT has no
digital width: the picture is as wide as its dots take to draw, so the
core plays each line back a little faster or slower. Many consumer sets
have no width control at all, and on a set stood on its side for a
vertical game the width is the game's height. There is no vertical
equivalent: a CRT's height is its sweep, and scaling lines would double
or drop whole scanlines. The scandoubler modes are left alone (a VGA
monitor has its own width control).

**Position.** The two sliders move the picture on the CRT, in the core's
own dots and lines, for a set whose picture sits off centre (the first one
tried with Moo Mesa showed it about 10 lines high). On a set on its side,
H Position moves the game up and down and V Position left and right. They move the syncs,
not the picture, so nothing is cropped and every mode follows; the size is
still the set's to adjust. 0 is the board's own timing.

**Video.** The core sends the board's own signal, at the board's own line
and frame rate -- the timing a 15 kHz arcade monitor or a PVM expects:
320 × 224 visible of 452 × 253 dots at 6.857 MHz, 15.17 kHz, 59.96 Hz.

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |
| (scandoubler, HQ2x) | -- | not built in this core: a VGA monitor will not take its 15 kHz picture |

**No scandoubler.** This core's block RAM is nearly full (281 of 308 blocks
before the Analogizer). With the adapter module's scandoubler and HQ2x in,
synthesis built HQ2x's line buffers out of logic and the design needed
2,398 logic blocks of the chip's 1,848. So, as in the S.T.U.N. Runner core,
the module is built without them (`USE_SD = 0`, a local change marked in
`target/pocket/analogizer/openFPGA_Pocket_Analogizer.v` and recorded in
`modules/VENDOR.md`); the menu does not offer those modes, and if one is
selected anyway it shows the RGBS picture. Y/C stays.

"On, Pocket off" turns the Pocket's own picture black while the CRT keeps
it.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
**SNAC Assignment** chosen in the menu:

| assignment | player 1 | player 2 | player 3 | player 4 |
|---|---|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls | dock 3 | dock 4 |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 | dock 3 | dock 4 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P3,P4 | Pocket | dock 2 | SNAC 1 | SNAC 2 |
| SNAC P1-P4 → P1-P4 | SNAC 1 | SNAC 2 | SNAC 3 | SNAC 4 |

Four SNAC players need the PC Engine multitap. A pad's buttons arrive as the
Pocket's own (SNAC's A is the Pocket's A, and so on), so they do whatever the
core maps those to. A PlayStation pad in analog mode steers with its left
stick.

**Cart power is on for everyone.** `core.json` declares the cartridge adapter,
so the Pocket powers the slot whether or not an Analogizer is in it. Do not
leave a game cartridge in the slot while this core runs.

Say in the core's README whether it has been tried on an Analogizer. What
the bench proves is listed under *What was measured* below. Send problems with
the adapter itself to the Analogizer project.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` and what it instantiates, **verbatim** (modules/VENDOR.md has the commit). Its `analogizer.qip` is ours: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: clock hand-over, Y/C constants, SNAC → controller words. Core-agnostic; the same file in the template. |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the instance (after the bring-up panel; `LINE_LEN` 452, the syncs and blanks taken a dot late so they frame the VCU's registered colour), `key1..key4` in place of `cont1..4_key`, the bridge read at `0xF7xxxxxx`, the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `core_pll` `outclk_4` | the Analogizer's 48 MHz, `clk_sys / 2` in phase; in the SDC's PLL group. |
| `pkg/.../interact.json` | the entries above: ids 70–73, each a masked field of the word at `0xF7000000`, and 74–75, signed sliders at `0xF7000004` and `0xF7000008` and 76, the width slider at `0xF700000C`. The enable and the Pocket-screen blank share one entry; the menu is at the Pocket's 16 entries, 45 options (`tools/check_json.py`) |
| `pkg/.../core.json` | `"cartridge_adapter": 0` (powers the slot) |
| `sim/run_analogizer.sh` | the bench (below), with this core's raster at the top of `sim/tb_analogizer.sv` |
| `tools/check_json.py` | fails if an entry writes outside its mask, none sets the enable, a position slider is not signed within ±127, a data slot also writes `0xF7000000`, or the slot is not powered |

### The settings word

One 32-bit word at `0xF7000000`, the layout RndMnkIII's adapter module (1.4)
decodes. Each menu entry is a list with a mask that keeps every bit but its
own field (or fields), so the four entries share the word:

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (+ pad; not in the menu, the wrapper does not wire the keyboard out), 0x10/0x11 PSX digital (125/250 kHz), 0x12/0x13 PSX analog. 16 and up select the adapter's B wiring. |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used by this core; no menu entry |

**Read-back.** The word is written as a number (the adapter module is told
`bridge_endian_little = 1`, so it does not byte-swap it as it would a file),
and `pocket_analogizer` keeps its own copy to read back, combinationally.
The Pocket's bridge (`io_bridge_peripheral.sv`) samples read data four clocks
after it presents the address and pulses `bridge_rd` only afterwards; the
adapter module updates its read-back on that pulse, so it would hand back
the *previous* read's value. The firmware merges a masked entry by
reading the word back (Analogue's interact.json docs: every entry not
`writeonly` is read back every frame), so that stale value would wipe the
other fields: in the bench, choosing a video mode turned the Analogizer off. RndMnkIII's menu
cores (Gauntlet) read the word back the same way, from a register.

**Picture position.** Two more words, each a whole signed slider value
(no mask): `0xF7000004` horizontal in dots, + right, and `0xF7000008`
vertical in lines, + down. `pocket_analogizer` reads the low 8 bits and
reads both words back. The adapter module stores them in a table it never
reads (`config_mem`). They move the syncs, not the picture: hsync n dots
earlier puts the picture n dots right, vsync n lines earlier puts it n
lines down. Earlier is built as a line (or frame) less n later: each sync
is re-made from the source's own rising edge after a delay counted in
dots, as wide as the source's, with the line and frame measured from the
source's syncs; the vsync's delay is whole lines, so its edges keep their
place in the line. RGB and blanking go through one clock later with them,
and at 0 each sync passes straight through.

A re-made sync starts only once it has been off at least as long as it is
on. The adapter module's `sync_fix` decides each sync's polarity afresh
every period, by whether the signal was high longer than low. A jump
between settings in one write (one "large" slider step, or a value loaded
at start) can put the next pulse just after the last one ends, and that
period reads as active-low: csync turned inside out for a frame (a line,
for hsync). With the rule such a jump skips one pulse instead.

**The ranges are this board's blanking.** Moving right, hsync may come
earlier until it meets the end of the picture; moving left, it may come
later until the Y/C colour burst, which ends about 3.5 µs after hsync
does (25 dots at this dot rate), would reach the picture. Vsync may move
either way until it reaches a picture line. The TC0180VCU puts the picture
at dots 0-319 and lines 16-239 of its 452 × 253 raster, hsync at dots
331-370 and vsync at lines 242-244 (`rtl/tc0180vcu.sv`): 11 dots before
hsync and 81 after it (56 clear of the burst), 2 lines before vsync and 24
after it. Hence +11 and -48 dots, +2 and -24 lines: the picture can go down
only 2 lines, because the board starts vsync 2 lines after its last. `sim/run_analogizer.sh` tries both ends of the range in
`interact.json` and fails if csync is low while a dot is drawn.

**Picture width.** `0xF700000C`, a signed slider in percent, scales the
15 kHz picture's width about its centre (`pocket_analogizer`'s width
stage). Each line's dots go into a two-line buffer, six bits a channel,
and the line before is read back during this one, `A × (100 + n) / 100`
clocks long where it was `A`, starting so its centre stays put: nearest
dot, the index advancing by `dots / clocks` (20 fractional bits, from a
divider run once a line) every clock. A dot is held `floor` or `ceil` of
its new length, so at 48 MHz and 8 MHz dots a 10% stretch holds them 6 or 7
clocks. All of a line's measures are the line before's. The picture comes
a line late, so vblank does too and the position stage delays vsync by a
line to match; the picture stays exactly where it was. Off (0), or in a
scandoubler mode, everything passes through as before.

The adapter module takes colour, blanks and syncs only on the *rising edge*
of its pixel enable (`openFPGA_Pocket_Analogizer.v`, "Fix video"). Fed the
source's enable, the scaled picture snapped back to the source's dots: the
bench measured every dot held 7 clocks at ±10%. Scaled, the wrapper makes
its own enable instead: a one-clock pulse whenever the dot, a blank or a
sync changes, delayed a clock if it would follow another directly so the
edge is still there. The bench now sees the 7/8 and 6/7 holds asked for.

A stretched line may run past the source's own next hsync (H Position can
have moved the output's later), so the read finishes the line from the
buffer and vblank latched at its start.

**Never into a sync.** Where H Position and H Size together would put
picture on hsync or on the colour burst after it, the wrapper crops the
picture's edge instead (`KEEP_CB`, from the previous line's hsync), so the
set never loses sync; a player sees an edge go missing and backs off.

**The width range comes from the blanking** with the picture centred: the
wider picture grows into both porches by half the increase, and a player
centres it with H Position first. The room is the line's whole free
blanking (less hsync and the burst), not just the shorter porch. The bench
centres the picture with H Position the way a player would (clamped to the
menu's range), tries both ends of the width range there (±10% where the
menu has no width entry) and fails if a line is the wrong length, off
centre, missing or reordering dots, a dot is held the wrong time, or the
picture moves vertically; then, at the largest width with H Position at
either end, it fails if csync is ever low while a dot is drawn or the
picture starts inside the colour burst.

**The file scheme, not used here.** The adapter module 1.4 was written for
`analogizer.bin`, a file Pupdate and AnalogizerConfigurator write to
`/Assets/analogizer/common/`, loaded through a data slot at the same address.
It needs a data slot naming the file, a second platform id `analogizer`
that the slot's parameters point at, and the file on the card before the
adapter does anything. A player who has never heard of the file has an
Analogizer that stays dark, so this core uses the menu. A data slot at
`0xF7000000` would load the file over the menu's word; `tools/check_json.py`
refuses one.

### Clocks

`openFPGA_Pocket_Analogizer` runs its logic on `i_clk`, puts `video_clk` on the
cartridge pin that clocks the ADV7123, and assumes that is `i_clk` too. The
scandoubler halves the pixel period, so the clock has to be at least four
times the dot rate. The shipped Analogizer cores use 42.95–48 MHz. This
core's system clock is 96 MHz, which is more than the cart's level
translators have been asked to pass, so the PLL's spare output (`outclk_4`,
`general[4]`, in the SDC's PLL group) gives 48 MHz, in phase with
`clk_sys`: 7 of its clocks a 6.857 MHz dot. `pocket_analogizer` takes each
pixel `PIX_LAG` (2) system clocks after the dot enable -- the VCU's colour
index is registered on the enable and the palette RAM read a clock after
it, so the colour has settled -- into a holding register and hands it over
with a toggle. The syncs and blanks it gets are the VCU's, taken on that
same enable a dot late, because the VCU makes them straight from its
counters while its colour comes out registered.

The Y/C encoder's subcarrier step and colour-burst window are computed in
integers from `CLK_HZ`. The reals used elsewhere lose the bits past 32 in some
tools, and MSX2's hand-typed NTSC step is a few counts off.

### Using SNAC in the game's inputs

`pocket_analogizer` outputs `key1..key4`, the Pocket's controller words with
SNAC pads put in place by the assignment. SNAC's bit order is the Pocket's
(0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, … 14 select,
15 start). They feed the `gamepad` helper and the direct player-3/4 reads in
place of `cont1..4_key`. **Wherever a core reads `cont*_key` directly**
(players 3 and 4 often are), read `key*` instead, or SNAC will not reach it.

### What was measured

- `sim/run_analogizer.sh` (PASS): the wrapper and the vendored module at this
  core's raster (452 × 253 dots, 7 Analogizer clocks a dot), built without
  the scandoubler as core_top builds it, read at the cartridge pins as the
  DAC reads them.
  - With the menu at its defaults, every pin sits as on a core without the
    adapter, and the controller words pass through.
  - All 27 options of the four Analogizer lists in the package's
    `interact.json`, set as the firmware sets a masked entry (read back,
    merged, written): the word, the adapter's copy and the enable followed.
  - RGBS: all 71,680 visible dots of a frame at the DAC pins, in order, 0
    differing; csync one 40-dot pulse a line. A scandoubler mode, selected
    anyway, shows exactly that RGBS picture.
  - Position at +11,+2 and -48,-24: csync moves by exactly the dots and lines
    asked (77 and -336 clocks, 2 and 24 lines), never low while a dot is
    drawn, the picture clear of the Y/C burst; jumps V +2 to -2, H +11 to -30
    and both to 0 in one write: 0 clocks of csync in the picture. One step
    past each end (+12 dots, +3 lines, -25 lines) fails the bench.
  - Width, centred by H Position -22: +20% and -20% give 224 lines of 2,689
    and 1,793 clocks (asked 2,688 and 1,792), centred to the clock, every dot
    in order, held 8/9 and 5/6 clocks, the lines as far from vsync as at 0;
    +20% at H Position +11 and -48: csync never low in the picture, the burst
    clear.
  - YPbPr and Y/C NTSC/PAL: no unknown on any pin. SNAC assignments 0-5, the
    analog stick, type none, the blank bit and enable off again all check.
- `sim/lint.sh` clean (the wrapper behind its own block); `sim/run_video.sh`:
  all 9 frozen states match the reference renderer (`rtl/` is unchanged).
- `tools/check_json.py pkg/pocket --active 320x224` clean: 16 entries, 45
  options, under the firmware limit measured on hardware (68 options, 80
  with entries).
- Quartus 18.1, before (v0.1.2's build) and after: 11,146 → 12,416 ALMs (67%),
  281 → 286 RAM blocks, 10 → 16 DSP; worst setup +0.398 → +0.397 ns (slow
  0C, clk_sys), worst hold +0.103 → +0.080 ns (fast 0C, into the
  Analogizer's reset synchroniser); SDRAM read capture hold +0.334 ns, setup
  +0.402 ns, so the SDRAM clock phase is unchanged. No constraint ignored
  outside the platform's own `sys_constr.sdc`. With the scandoubler and
  HQ2x built, it did not fit: 2,398 LABs of 1,848, HQ2x's input line
  buffers built from 21,744 registers.

**Not proven:** anything on hardware with this core (the adapter module
itself ships in RndMnkIII's cores and in plasticbugs' other cores),
and the SNAC serial protocols, which are
the adapter module's and are forced at its outputs in the bench rather than
driven over the pins. The Y/C and YPbPr encodings have no reference to compare
against, only a run without unknowns.

### On hardware, in this order

1. **"Analogizer: Off"** (the default): the game plays exactly as before,
   Pocket screen and controls. If not, the cart port is not idle: stop.
2. **On, RGBS, SNAC None**, the CRT on its side (top to the left): the same
   picture as the Pocket's, upright, 15.17 kHz / 59.96 Hz.
3. **H Position** about -22 centres the picture between the syncs; then
   **H Size** up to +20% makes the game taller. V Position moves it
   sideways (only 2 lines one way: the board's blanking).
4. Each other video mode; then a SNAC pad ("SNAC P1 -> P1": the Pocket's
   own controls become player 2); then that the menu keeps its settings
   across a reload.

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv`, remove `general[4]` from the PLL
group in the SDC (it would match nothing), and take the six menu entries
and `cartridge_adapter: 0` out of the JSON.
