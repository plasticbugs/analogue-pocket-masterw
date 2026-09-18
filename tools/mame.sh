#!/bin/sh
# Run MAME on masterw against the shadow romset, headless and deterministic.
# Always pass -seconds_to_run: a Lua script that ends the run with
# machine:exit() has proved unreliable, while -seconds_to_run plus an
# add_machine_stop_notifier that writes the results is repeatable to the frame.
root=$(cd "$(dirname "$0")/.." && pwd)
exec mame masterw -rompath "$root/.mame/roms" \
    -video none -sound none -nothrottle -skip_gameinfo \
    -cfg_directory "$root/.mame/cfg" -nvram_directory "$root/.mame/nvram" \
    "$@"
