#!/bin/sh
# Lint every module in rtl/ on its own, so a warning has one obvious owner.
# Run before every push: it costs seconds and catches what a two-minute
# Quartus map would, without waiting for Quartus.
#
# The vendored cores are waived by rule and path. The waiver file is built
# here rather than committed, because Verilator rejects the whole file if it
# names a rule that version does not know -- which is how a waiver written
# against the newest Verilator broke the lint on CI's older one. Each rule is
# probed first and only the ones that exist go in.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }

. "$here/waivers.sh"
WAIVE="$WAIVERS"

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
echo 'module lintprobe; endmodule' > "$PROBE/lintprobe.v"

OPTS="-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD"
for w in UNUSEDPARAM PINCONNECTEMPTY; do
    verilator --lint-only "-Wno-$w" "$PROBE/lintprobe.v" >/dev/null 2>&1 \
        && OPTS="$OPTS -Wno-$w"
done

fail=0
for f in "$root"/rtl/*.sv; do
    m=$(basename "$f" .sv)
    printf '%-20s ' "$m"
    out=$(verilator --lint-only $OPTS "$WAIVE" --top-module "$m" \
          "$root"/rtl/*.sv "$root"/modules/*/*.v "$root"/modules/*/*.sv 2>&1 \
          | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' || true)
    if [ -z "$out" ]; then echo ok
    else echo; echo "$out" | sed 's/^/    /'; fail=1
    fi
done

printf '%-20s ' "pocket memories"
out=$(verilator --lint-only $OPTS "$WAIVE" --top-module masterw_mem \
      "$root"/target/pocket/masterw_mem.sv "$root"/target/pocket/sdram_ctrl.sv \
      "$root"/target/pocket/sram_port.sv 2>&1 \
      | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' \
      | grep -v 'sdram_ctrl.sv' || true)
if [ -z "$out" ]; then echo ok
else echo; echo "$out" | sed 's/^/    /'; fail=1
fi

[ $fail = 0 ] || exit 1
echo "lint clean"
