-- Dump MAME's loaded ROM regions to raw files, so tools/verify_rom.py can
-- check the image the .mra builds against what MAME actually feeds the chips.
local mac = manager.machine
local dir = os.getenv("REGION_DIR") or "."
_G.KEEP = {}
_G.KEEP.s = emu.add_machine_stop_notifier(function() end)

for _, tag in ipairs({":maincpu", ":audiocpu", ":tc0180vcu"}) do
  local r = mac.memory.regions[tag]
  if r then
    local f = io.open(dir .. "/" .. tag:sub(2) .. ".bin", "wb")
    for i = 0, r.size - 1 do f:write(string.char(r:read_u8(i))) end
    f:close()
  end
end
