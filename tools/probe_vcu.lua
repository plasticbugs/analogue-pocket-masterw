-- Probe TC0180VCU usage in masterw: video_control values, framebuffer CPU access,
-- scroll-block and text-bank registers, sprite table extent.
-- Run:  OUT=... mame masterw ... -seconds_to_run 30 -autoboot_script tools/probe_vcu.lua
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local out = io.open(os.getenv("OUT") or "probe_vcu.txt", "w")

local COIN   = tonumber(os.getenv("COIN")  or "200")
local START  = tonumber(os.getenv("START") or "260")

local frames = 0
local ctrl_seen, vc_hist = {}, {}
local fb_w, fb_r = 0, 0
local fb_min, fb_max = nil, nil
local spr_hi = 0        -- highest sprite slot with a non-zero code word

local function note(t, k) t[k] = (t[k] or 0) + 1 end

_G.KEEP = {}
_G.KEEP.ctrl = sp:install_write_tap(0x418000, 0x41801f, "ctrl", function(offset, data, mask)
  local idx = ((offset - 0x418000) // 2) & 0xf
  ctrl_seen[idx] = ctrl_seen[idx] or {}
  note(ctrl_seen[idx], string.format("%04x/%04x", data & mask, mask))
end)
_G.KEEP.fbw = sp:install_write_tap(0x440000, 0x47ffff, "fbw", function(offset, data, mask)
  fb_w = fb_w + 1
  local o = offset - 0x440000
  if not fb_min or o < fb_min then fb_min = o end
  if not fb_max or o > fb_max then fb_max = o end
end)
_G.KEEP.fbr = sp:install_read_tap(0x440000, 0x47ffff, "fbr", function() fb_r = fb_r + 1 end)

local function press(port, field, on)
  mac.ioport.ports[port].fields[field]:set_value(on and 0 or 1)   -- ACTIVE_LOW
end

_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  note(vc_hist, string.format("%02x", (sp:read_u16(0x41800e) >> 8) & 0xff))

  -- highest used sprite slot this frame (sprite RAM 0x410000, 16 bytes/slot, 408 slots)
  for s = 0, 0x1980 // 16 - 1 do
    if sp:read_u16(0x410000 + s * 16) ~= 0 then
      if s > spr_hi then spr_hi = s end
    end
  end

  if frames == COIN      then press(":IN2", "Coin 1", true)  end
  if frames == COIN + 10 then press(":IN2", "Coin 1", false) end
  if frames == START     then press(":IN2", "1 Player Start", true)  end
  if frames == START +10 then press(":IN2", "1 Player Start", false) end
end)

_G.KEEP.s = emu.add_machine_stop_notifier(function()
  out:write(string.format("frames %d\n", frames))
  out:write(string.format("framebuffer CPU access: writes %d reads %d min %s max %s\n",
    fb_w, fb_r, tostring(fb_min), tostring(fb_max)))
  out:write(string.format("highest non-zero sprite slot: %d (of %d)\n", spr_hi, 0x1980 // 16))
  out:write("video_control histogram:\n")
  local keys = {}
  for k in pairs(vc_hist) do keys[#keys+1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do out:write(string.format("  %s : %d\n", k, vc_hist[k])) end
  out:write("ctrl writes (value/mask(count)):\n")
  for i = 0, 15 do
    if ctrl_seen[i] then
      local ks = {}
      for k in pairs(ctrl_seen[i]) do ks[#ks+1] = k end
      table.sort(ks)
      out:write(string.format("  reg%02d:", i))
      for _, k in ipairs(ks) do out:write(string.format(" %s(%d)", k, ctrl_seen[i][k])) end
      out:write("\n")
    end
  end
  out:close()
end)
