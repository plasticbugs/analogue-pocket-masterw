#!/bin/sh
# MAME refuses to start masterw without the three PAL dumps in the `plds`
# region, which no emulation ever reads and which the user's romset does not
# carry.  Build a shadow romset in .mame/roms: symlinks to the real ROMs plus
# placeholder PLDs, so the user's own files are never touched or polluted.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$root/masterw}
dst=$root/.mame/roms/masterw
mkdir -p "$dst" "$root/.mame/cfg" "$root/.mame/nvram"
for f in "$src"/*; do
    case "$(basename "$f")" in b72-08.ic3|b72-09.ic23|b72-10.ic32) continue;; esac
    ln -sf "$f" "$dst/$(basename "$f")"
done
for p in b72-08.ic3 b72-09.ic23 b72-10.ic32; do
    [ -e "$src/$p" ] && ln -sf "$src/$p" "$dst/$p" || \
        python3 -c "open('$dst/$p','wb').write(b'\xff'*260)"
done
echo "shadow romset ready: $dst"
