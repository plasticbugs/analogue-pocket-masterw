#!/bin/sh
# Lint every module in rtl/ on its own, so a warning has one obvious owner.
# Run this before every push: it costs seconds and catches what a two-minute
# Quartus map would, without waiting for Quartus.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
opts="-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD"
fail=0
for f in "$root"/rtl/*.sv; do
    m=$(basename "$f" .sv)
    printf '%-20s ' "$m"
    if out=$(verilator --lint-only $opts "$here/waivers.vlt" --top-module "$m" \
             "$root"/rtl/*.sv "$root"/modules/*/*.v "$root"/modules/*/*.sv 2>&1 \
             | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to'); then
        [ -z "$out" ] && echo ok || { echo; echo "$out" | sed 's/^/    /'; fail=1; }
    else
        echo ok
    fi
done
[ $fail = 0 ] || exit 1
