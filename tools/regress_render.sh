#!/bin/sh
# Check the TC0180VCU model in tools/vcu_model.py against MAME, pixel for
# pixel, over a spread of frames chosen to exercise every part of the video
# chip.  This is the gate the RTL is later held to: whatever the model says
# here is what the gateware has to produce.
#
#   tools/regress_render.sh [rom-image]
#
# States are dumped into .mame/states the first time and reused after that;
# delete that directory to force a fresh capture.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
rom=${1:-$root/.mame/masterw.rom}
states=$root/.mame/states

if [ ! -f "$rom" ]; then
    echo "building $rom from the romset"
    python3 "$root/tools/mra_build.py" "$root/masterw.mra" "$root/masterw" "$rom" >/dev/null
fi

# Each group is a run of consecutive frames: the model needs the two dumps
# before a frame to reproduce it (tilemaps one back, sprites two back).
#
#   0198-0200  boot, before the game has drawn anything
#   0398-0400  attract: the demo ship formation over a scrolling background
#   0998-1000  gameplay: zoomed sprites, big sprites, palette animation
#   1998-2000  a blanked screen between attract scenes
#   2798-2800  the title screen just after the framebuffer stops being cleared
#
# and one long replay over the title screen, where the framebuffer is never
# cleared and the "Master of Weapon" signature accumulates for 500 frames.
full=198,199,200,398,399,400,998,999,1000,1998,1999,2000,2778,2779,2780,2781,2849,2850,2999,3000,3299,3300
lite=2778-3300

if [ ! -f "$states/run.txt" ]; then
    "$root/tools/dump_states.sh" "$states" "$full" "$lite"
fi

python3 "$root/tools/render_model.py" "$rom" "$states" -replay -o "$root/artifacts/render"
