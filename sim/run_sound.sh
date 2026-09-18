#!/bin/sh
# Sound-board bench: replay the 68000's own CIU traffic, recorded from MAME,
# into the core's Z80 and YM2203, and record what it plays.  No video, so it
# is minutes rather than half an hour, and it isolates the sound board from
# everything else.
#
#   sim/run_sound.sh [rom] [seconds]
#
# Capture the traffic first with:
#   OUT=artifacts/audio/ciu.txt COIN=200 START=300 \
#       tools/mame.sh -seconds_to_run 8 -autoboot_script tools/probe_ciu.lua
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
rom=${1:-$root/.mame/masterw.rom}
case "$rom" in /*) ;; *) rom="$(pwd)/$rom" ;; esac
secs=${2:-8}
cd "$here"

verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    --top-module tb_sound_top -Mdir obj_sound \
    ../rtl/masterw_sound.sv ../rtl/pc060ha.sv \
    ../modules/cpu-tv80/*.v ../modules/sound-jt03/*.v ../modules/sound-jt49/*.v \
    tb_sound_top.sv tb_sound.cpp > obj_sound.log 2>&1 \
    || { tail -30 obj_sound.log; exit 1; }

mkdir -p "$root/artifacts/audio"
./obj_sound/Vtb_sound_top "$rom" "$root/artifacts/audio/ciu.txt" \
    -secs "$secs" -o "$root/artifacts/audio/core"
echo
echo "== against MAME =="
for w in mix jt03 fm; do
    printf '%s\n' "-- $w --"
    python3 "$root/tools/compare_audio.py" "$root/artifacts/audio/mame_coin.wav" \
        "$root/artifacts/audio/core_$w.wav" "$secs" || true
done
