#!/bin/sh
# Whole-machine bench: both CPUs run the real program against models of the
# Pocket's memories.  Slow -- a frame is 1.6 million clocks -- so use it for
# questions about the machine (does it boot, do the interrupts run, does the
# sound CPU answer) and sim/run_video.sh for anything about the picture.
#
#   sim/run_system.sh [rom] [extra bench args]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
rom=${1:-$root/.mame/masterw.rom}
case "$rom" in /*) ;; *) rom="$(pwd)/$rom" ;; esac
[ -f "$rom" ] || { echo "no ROM image at $rom" >&2; exit 2; }
[ $# -gt 0 ] && shift
cd "$here"

. "$here/waivers.sh"

# --no-assert-case: fx68k's ALU has a `unique case` that does not match while
# the CPU is still in reset, which Verilator would otherwise stop on.
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD --no-assert-case \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    "$WAIVERS" --top-module tb_system_top -Mdir obj_pocket \
    ../rtl/*.sv \
    ../modules/cpu-fx68k/fx68k.sv ../modules/cpu-fx68k/fx68kAlu.sv \
    ../modules/cpu-fx68k/uaddrPla.sv ../modules/cpu-tv80/*.v \
    ../modules/sound-jt03/*.v ../modules/sound-jt49/*.v \
    ../target/pocket/masterw_mem.sv ../target/pocket/sdram_ctrl.sv ../target/pocket/sram_port.sv sdram_model.sv sram_model.sv tb_pocket_top.sv tb_system.cpp > obj_pocket.log 2>&1 \
    || { tail -30 obj_pocket.log; exit 1; }

# fx68k reads its microcode with $readmemb from the working directory
ln -sf ../../modules/cpu-fx68k/microrom.mem obj_pocket/microrom.mem
ln -sf ../../modules/cpu-fx68k/nanorom.mem  obj_pocket/nanorom.mem

mkdir -p "$root/artifacts/pocket"
cd obj_pocket
exec ./Vtb_system_top "$rom" -dlgap "${DLGAP:-8}" -o "$root/artifacts/pocket" "$@"
