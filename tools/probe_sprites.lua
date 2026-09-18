-- Budget input for the sprite engine: how many of the 408 sprite entries are
-- actually on screen, frame by frame, over a long run.  The engine walks the
-- whole table regardless, but only an on-screen entry costs a tile fetch and
-- 256 pixel writes.
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local out = io.open(os.getenv("OUT") or "probe_sprites.txt", "w")

local frames, worst, worst_frame = 0, 0, 0
local hist = {}

_G.KEEP = {}
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  local n = 0
  for s = 0, 407 do
    local base = 0x410000 + s * 16
    local x = sp:read_u16(base + 4) & 0x3ff
    local y = sp:read_u16(base + 6) & 0x3ff
    if x >= 0x200 then x = x - 0x400 end
    if y >= 0x200 then y = y - 0x400 end
    if x + 15 >= 0 and x <= 319 and y + 15 >= 16 and y <= 239 then n = n + 1 end
  end
  local b = (n // 16) * 16
  hist[b] = (hist[b] or 0) + 1
  if n > worst then worst, worst_frame = n, frames end

  if frames == 200 then mac.ioport.ports[":IN2"].fields["Coin 1"]:set_value(0) end
  if frames == 210 then mac.ioport.ports[":IN2"].fields["Coin 1"]:set_value(1) end
  if frames == 260 then mac.ioport.ports[":IN2"].fields["1 Player Start"]:set_value(0) end
  if frames == 270 then mac.ioport.ports[":IN2"].fields["1 Player Start"]:set_value(1) end
  -- hold fire so the demo shoots things and the screen fills up
  if frames > 300 then
    mac.ioport.ports[":IN0"].fields["P1 Button 1"]:set_value((frames % 4 < 2) and 0 or 1)
  end
end)

_G.KEEP.s = emu.add_machine_stop_notifier(function()
  out:write(string.format("frames %d\nworst %d on-screen entries at frame %d\n", frames, worst, worst_frame))
  local ks = {}
  for k in pairs(hist) do ks[#ks+1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do out:write(string.format("  %3d-%3d : %d\n", k, k + 15, hist[k])) end
  out:close()
end)
