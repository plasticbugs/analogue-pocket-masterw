#!/bin/sh
# Frozen-state video gate: load a dumped MAME frame into the RTL, render it,
# and diff the palette indices against tools/vcu_model.py, which is
# pixel-identical to MAME.
#
#   sim/run_video.sh [rom] [state-name ...]
#
# A state name is the frame number of a full dump in .mame/states; the bench
# is given the dumps it needs before it, oldest first.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
rom=${1:-$root/.mame/masterw.rom}
case "$rom" in /*) ;; *) rom="$(pwd)/$rom" ;; esac
[ -f "$rom" ] || { echo "no ROM image at $rom -- run tools/regress_render.sh first" >&2; exit 2; }
[ $# -gt 0 ] && shift
cd "$here"

. "$here/waivers.sh"

verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    "$WAIVERS" --top-module tb_video_top -Mdir obj_video \
    ../rtl/tc0180vcu.sv ../rtl/vcu_line.sv ../rtl/vcu_sprite.sv ../rtl/vcu_fb.sv \
    tb_video_top.sv tb_video.cpp > obj_video.log 2>&1 \
    || { tail -30 obj_video.log; exit 1; }

states=$root/.mame/states
mkdir -p "$root/artifacts/rtl"
# by default, every frame the reference renderer produced an answer for --
# which is every frame with a full dump and a full dump one frame before it
if [ $# -gt 0 ]; then names="$*"; else
    names=$(ls "$root"/artifacts/model/*.idx 2>/dev/null \
            | sed 's|.*/||; s/\.idx//' | sort -n)
    [ -n "$names" ] || { echo "no reference frames: run tools/regress_render.sh with -idx first" >&2; exit 2; }
fi

fail=0
for n in $names; do
    printf '%-6s ' "$n"
    # the two dumps before it: tilemaps one back, sprites two back
    prev=$(printf '%04d' $((n - 1)))
    prev2=$(printf '%04d' $((n - 2)))
    if [ ! -f "$states/state_$prev.bin" ] && [ ! -f "$states/lite_$prev.bin" ]; then
        echo "skipped (no dump for frame $((n - 1)))"; continue
    fi
    # replay chain: every lite dump from the first available up to n-2,
    # then the full dump at n-1
    chain=""
    for f in "$states"/lite_*.bin "$states"/state_*.bin; do
        [ -f "$f" ] || continue
        fn=$(echo "$f" | sed 's/.*_0*//; s/\.bin//')
        [ "$fn" -le $((n - 2)) ] || continue
        chain="$chain $f"
    done
    # keep only one dump per frame, preferring the full one, and sort
    chain=$(for f in $chain; do
                fn=$(echo "$f" | sed 's/.*_0*//; s/\.bin//'); echo "$fn $f"
            done | sort -n -k1,1 -u | awk '{print $2}')
    last=$states/state_$prev.bin
    [ -f "$last" ] || last=$states/lite_$prev.bin
    out=$root/artifacts/rtl/$n.idx
    if ! msg=$(./obj_video/Vtb_video_top "$rom" $chain "$last" -o "$out" 2>&1); then
        echo "BENCH FAILED"; echo "$msg" | sed 's/^/    /'; fail=1; continue
    fi
    python3 "$root/tools/idx2png.py" "$out" "$last" "$root/artifacts/rtl/$n.png" 2>/dev/null || true
    if python3 "$root/tools/diff_index.py" "$out" "$root/artifacts/model/$n.idx"; then
        echo "PASS  $msg"
    else
        echo "FAIL  $msg"; fail=1
    fi
done
[ $fail = 0 ] && echo "every frame matches the reference renderer" || { echo FAILURES; exit 1; }
