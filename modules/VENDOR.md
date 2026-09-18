# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k | fx68k by Jorge Cwik | the Namco Classic Collection core (originally Xenophobe) | GPL-3.0 (`modules/cpu-fx68k/LICENSE`) |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's tv80) | the Gaiapolis core, with its `tv80s_cen.v` clock-enable wrapper | MIT |
| sound-jt03 | https://github.com/jotego/jt12 `hdl/` (`jt03.v` is the YM2203 wrapper over `jt12_top`) | fetched from upstream master | GPL-3.0 |
| sound-jt49 | https://github.com/jotego/jt49 `hdl/` | fetched from upstream master -- jt12 instantiates `jt49` with `COMP`, `CLKDIV` and `YM2203_LUMPED`, so it has to be the version that has them | GPL-3.0 |

`sound-jt03` carries the whole of jt12's `hdl/`, including the ADPCM files it
never uses: `jt12_top` instantiates them outside a generate guard, so they
have to exist even with `use_adpcm(0)`.

Written here rather than vendored: the TC0180VCU, TC0040IOC and PC060HA, from
MAME's device models -- see `docs/hardware.md` for the behaviour and
`tools/vcu_model.py` for the video semantics they were written against.

To update one: re-copy from upstream at the new commit and record it here.
