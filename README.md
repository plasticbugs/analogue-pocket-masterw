# Master of Weapon — Analogue Pocket core (openFPGA)

Master of Weapon (Taito, 1989) on Taito B System hardware, for the Analogue
Pocket via openFPGA.

The whole board is in gateware: the 68000, the Z80 sound board with its
YM2203, and the TC0180VCU that draws the two 16×16 tilemaps, the text layer
and the sprites — including the sprite framebuffer the chip paints into during
vblank, which is what draws the game's hand-written title.

> **ROMs are not included and never will be.** You supply your own MAME
> `masterw` romset; the core reads one image built from it.

| board part | implementation | verified by |
|---|---|---|
| 68000 @ 12 MHz | fx68k (cycle-accurate) | system bench |
| Z80 @ 6 MHz | tv80 | system bench |
| YM2203 @ 3 MHz | jotego's jt03 | *not yet measured against MAME* |
| TC0180VCU | `rtl/tc0180vcu.sv` and the three engines beside it | **pixel-identical to MAME** on nine frozen states (`sim/run_video.sh`) |
| TC0040IOC | `rtl/tc0040ioc.sv` | — |
| PC060HA | `rtl/pc060ha.sv`, a literal translation of MAME's | system bench |
| 1.6 MB ROM | Pocket SDRAM (`target/pocket/masterw_mem.sv`) | image byte-identical to MAME's regions (`tools/verify_rom.py`) |
| 64 KB tilemap VRAM | Pocket SRAM | — |

`docs/hardware.md` describes the board, `docs/core-design.md` the mapping onto
the Pocket, and `METHODOLOGY.md` the method: MAME is the oracle, a Python
reference renderer is the executable spec, and frozen-state benches are the
regression gate.

## Status

Not yet run on hardware. What is proven, and how:

* **The ROM image is exactly what MAME loads.** `tools/verify_rom.py`
  de-interleaves the built image and compares all three regions with the bytes
  MAME hands to the chips: identical.
* **The video is pixel-identical to MAME.** `tools/vcu_model.py` is a model of
  the TC0180VCU written from MAME's device, checked frame by frame against
  MAME's own output; `sim/run_video.sh` then loads the same frozen states into
  the RTL and diffs the palette indices the hardware produced against the
  model's. Nine frames spanning boot, attract, gameplay and the title screen
  match exactly, with zero differing indices.
* **The machine boots.** `sim/run_system.sh` runs both CPUs on the real
  program against models of the Pocket's memories: 420 frames with no watchdog
  reset, no halt, and the attract sequence drawing.
* **The budgets are measured, not assumed.** The busiest frame spends 45,000
  of vblank's 183,500 clocks painting sprites and 3,675 of a line's 6,328
  rendering it.

* **The sound plays MAME's music.** `sim/run_sound.sh` replays the 68000's own
  CIU traffic, recorded from MAME, into the core's Z80 and YM2203 and compares
  eight seconds with MAME's recording: within 6% in the two bands the music
  occupies (`artifacts/audio/comparison.txt`). The SSG's level against the FM
  is still unmeasured, because the passage compared plays no SSG.
* **It fits.** Quartus 18.1: 67% of the ALMs, 65% of the block memory bits,
  279 of 308 RAM blocks, 14 of 66 DSPs.

Still to do: **close timing**. The 96 MHz clock is short by about a
nanosecond, every failing path inside the sprite engine's fixed-point
arithmetic, which is being pipelined and narrowed a path at a time (each
change is checked against the frozen-state gate before it is pushed, so the
picture cannot drift while the timing is chased). And then run it on a
Pocket.

<p align="center">
  <img src="artifacts/rtl/3300.png" width="320" alt="the title screen, drawn by the RTL"><br>
  <em>The title screen as the RTL draws it. The signature is a single sprite
  moving along the stroke, accumulating in a framebuffer the chip is told not
  to clear — 500 frames of it, and the core lands on MAME's frame exactly.</em>
</p>

## Building the ROM image

```sh
python3 mra_build.py masterw.mra masterw.zip
```

The builder needs nothing but Python 3. It reads the MAME zip (or a directory
of loose files) directly, checks every ROM's CRC32, and verifies the finished
1,638,400-byte image against a known md5, so a wrong or damaged romset is
reported rather than quietly built into something that half works.

Copy the result to `Assets/masterw/common/masterw.rom` on the Pocket's SD
card. Already using `pupdate` or the standard `mra` tool? Point it at
`masterw.mra`; it is an ordinary MRA file.

## Building the core

`./build-local.sh` compiles with Quartus 18.1 in Docker and leaves the SD-card
package in `release/pocket/`. `./build-local.sh map` runs analysis and
synthesis only, which takes a couple of minutes and catches what Verilator
cannot — run it before every push, because a broken push costs a whole CI
cycle. Every push to `main` compiles in CI and uploads the package as the
`masterw-pocket` artifact.

## Checking it

```sh
tools/regress_render.sh     # the model against MAME, pixel for pixel
sim/run_video.sh            # the RTL against the model, index for index
sim/run_system.sh           # the whole machine, both CPUs, real program
sim/lint.sh                 # every module on its own
```

The first run of `tools/regress_render.sh` captures the frozen states from
MAME, which needs a `masterw` romset in `masterw/` and MAME on the path.
MAME will not start the set without three PAL dumps that no emulation reads,
so `tools/shadow_romset.sh` builds a symlink farm with placeholders rather
than touching your romset.

## Credits

* MAME, for the driver and device models this was written against —
  `ref/mame/` holds the exact files, fetched verbatim.
* Jorge Cwik's fx68k, Guy Hutchison's tv80, and Jose Tejada's jt03 and jt49;
  see `modules/VENDOR.md`.
* The openFPGA/opengateware framework in `platform/pocket/`.
* Guru, for the board photograph and the measurements in `docs/hardware.md`.
