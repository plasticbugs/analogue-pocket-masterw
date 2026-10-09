# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k | fx68k by Jorge Cwik | the Namco Classic Collection core (originally Xenophobe) | GPL-3.0 (`modules/cpu-fx68k/LICENSE`) |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's tv80) | the Gaiapolis core, with its `tv80s_cen.v` clock-enable wrapper | MIT |
| sound-jt03 | https://github.com/jotego/jt12 `hdl/` (`jt03.v` is the YM2203 wrapper over `jt12_top`) | fetched from upstream master | GPL-3.0 |
| sound-jt49 | https://github.com/jotego/jt49 `hdl/` | fetched from upstream master -- jt12 instantiates `jt49` with `COMP`, `CLKDIV` and `YM2203_LUMPED`, so it has to be the version that has them | GPL-3.0 |
| `target/pocket/analogizer/` | RndMnkIII's Analogizer adapter module (`openFPGA_Pocket_Analogizer` 1.4) and the 14 files it instantiates, verbatim; `analogizer.qip` is ours | https://github.com/RndMnkIII/MiraxPocket `src/fpga/analogizer/` at 9dfdd2b9bec79fe5ea10e154a0613a0c9d4fe37f, via the pocket-core-template (9233037); **one local change** in `openFPGA_Pocket_Analogizer.v`, marked `LOCAL`: parameters `USE_YC` / `USE_SD` (default 1, the module as upstream wrote it) leave out the Y/C encoder or the scandoubler with HQ2x; this core builds it with `USE_SD = 0` (no block RAM for it), taken from plasticbugs' S.T.U.N. Runner core | GPL-3.0-or-later; `hq2x.sv`, `scandoubler_2.v`, `yc_out_legacy.sv` carry their own GPL headers |

`sound-jt03` carries the whole of jt12's `hdl/`, including the ADPCM files it
never uses: `jt12_top` instantiates them outside a generate guard, so they
have to exist even with `use_adpcm(0)`.

Written here rather than vendored: the TC0180VCU, TC0040IOC and PC060HA, from
MAME's device models -- see `docs/hardware.md` for the behaviour and
`tools/vcu_model.py` for the video semantics they were written against.

The Analogizer module lives under `target/pocket/` rather than `modules/`
because it is the Pocket's cartridge port, not the machine, and so that the
per-module lint does not sweep it in: `core.qip` includes its own
`analogizer.qip`, and `sim/lint.sh` lints it behind
`target/pocket/pocket_analogizer.sv` with a stand-in for its one VHDL file
(`sim/ps2_keyboard_stub.v`).  Left out, as nothing instantiates them:
`scandoubler.v`, `scanlines.v`, `yc_out.sv`, `psPAD_top.v`, `psx_control.v`,
`csync.v`, `sync_fix.v` (also defined inside the top file),
`two_button_press_detector.v`, `uart_tx.v` and `sine_lut.mem`.

To update one: re-copy from upstream at the new commit and record it here.
