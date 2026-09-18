-- Log every byte the 68000 sends the sound board, with the time it sent it,
-- so sim/run_sound.sh can replay exactly the same stream into the core's own
-- Z80 and YM2203 and the two can be compared without the video in the way.
--
--   OUT=... COIN=200 START=300 tools/mame.sh -seconds_to_run 8 \
--       -autoboot_script tools/probe_ciu.lua
--
-- One line per access: <cycles-since-reset> <W|R> <port|comm> <byte>.
-- Cycles are the 68000's, at 12 MHz, which is exactly 8 of the core's 96 MHz
-- clocks.
local mac = manager.machine
local cpu = mac.devices[":maincpu"]
local sp  = cpu.spaces["program"]
local out = io.open(os.getenv("OUT") or "ciu.txt", "w")

local COIN  = tonumber(os.getenv("COIN")  or "-1")
local START = tonumber(os.getenv("START") or "-1")
local n = 0

local function cycles()
  -- machine time in 68000 clocks
  local t = mac.time
  return math.floor((t.seconds + t.attoseconds / 1e18) * 12000000)
end

_G.KEEP = {}
_G.KEEP.w = sp:install_write_tap(0xa00000, 0xa00003, "ciuw", function(offset, data, mask)
  local port = (offset & 2) ~= 0 and "comm" or "port"
  out:write(string.format("%d W %s %02x\n", cycles(), port, (data >> 8) & 0xff))
end)
_G.KEEP.r = sp:install_read_tap(0xa00000, 0xa00003, "ciur", function(offset, data, mask)
  local port = (offset & 2) ~= 0 and "comm" or "port"
  out:write(string.format("%d R %s %02x\n", cycles(), port, (data >> 8) & 0xff))
end)

local function press(f, on)
  mac.ioport.ports[":IN2"].fields[f]:set_value(on and 0 or 1)
end

_G.KEEP.n = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n == COIN      then press("Coin 1", true)  end
  if n == COIN + 10 then press("Coin 1", false) end
  if n == START     then press("1 Player Start", true)  end
  if n == START + 10 then press("1 Player Start", false) end
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  out:write(string.format("# frames %d\n", n)); out:close()
end)
