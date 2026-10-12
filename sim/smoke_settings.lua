-- sim/smoke_settings.lua
--
-- VSync and the frame cap (services/Display, Settings):
--   defaults  vsync on, cap off; a cap the list doesn't offer is off
--   apply     vsync reaches the live window (setVSync) and the mode it sets
--   commit    the cap persists with the rest of the settings
--   cycle     the cap steps Off -> 60 -> 120 -> 144 -> Off, with labels
--   wait      off, no sleep; a fast frame sleeps out the budget; a long
--             frame never sleeps and the phase resyncs after it
--   keys      main.lua's settings file carries both keys
--
-- Standalone: `lua sim/smoke_settings.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local Display = require("services.Display")

-- defaults
local st = {}
Display.defaults(st)
c.eq(st.vsync, true, "vsync defaults on")
c.eq(st.fps_cap, 0, "the cap defaults off")
st = { vsync = false, fps_cap = 75 }
Display.defaults(st)
c.eq(st.vsync, false, "a saved vsync off stays off")
c.eq(st.fps_cap, 0, "a cap the list doesn't offer is off")

-- apply
local modes, vs = {}, {}
love.window.setMode  = function(w, h, flags) modes[#modes + 1] = { w = w, h = h, flags = flags }; return true end
love.window.setVSync = function(v) vs[#vs + 1] = v end
love.window.getMode  = function() return 1280, 720, { fullscreen = false, vsync = 1 } end
local s2 = { display_mode = "windowed", display_w = 1600, display_h = 900, vsync = false, fps_cap = 120 }
c.ok(Display.apply(s2), "apply succeeds")
c.eq(vs[#vs], 0, "vsync off reaches the live window")
c.ok(modes[#modes] and modes[#modes].flags.vsync == 0, "and the mode it sets")
s2.vsync = true
Display.apply(s2)
c.eq(vs[#vs], 1, "vsync on reaches the live window")

-- commit
local saved
local svc = { saveSettings = function(_, t) saved = t; return true end }
Display.commit(s2, svc, { fps_cap = 60 })
c.ok(saved ~= nil and saved.fps_cap == 60 and saved.vsync == true, "commit persists the cap with the rest")

-- cycle
c.eq(Display.nextFpsCap(0), 60, "Off steps to 60")
c.eq(Display.nextFpsCap(60), 120, "60 to 120")
c.eq(Display.nextFpsCap(144), 0, "144 wraps to Off")
c.eq(Display.nextFpsCap(nil), 0, "an unset cap reads Off")
c.eq(Display.fpsCapLabel(0), "Off", "the off label")
c.eq(Display.fpsCapLabel(120), "120", "a cap's label is its number")

-- wait
local clock, slept = 10, {}
love.timer.getTime = function() return clock end
love.timer.sleep   = function(s) slept[#slept + 1] = s; clock = clock + s end
Display.setFrameCap(0)
Display.frameWait(); Display.frameWait()
c.eq(#slept, 0, "off, no sleep")
Display.setFrameCap(100)
Display.frameWait()              -- the first frame starts the clock
clock = clock + 0.002            -- a 2 ms frame
Display.frameWait()
c.ok(#slept == 1 and math.abs(slept[1] - 0.008) < 1e-6,
     "a fast frame sleeps out the budget (" .. tostring(slept[1]) .. ")")
clock = clock + 1                -- a hitch
Display.frameWait()
c.eq(#slept, 1, "a long frame never sleeps")
clock = clock + 0.001
Display.frameWait()
c.ok(#slept == 2 and math.abs(slept[2] - 0.009) < 1e-6,
     "and the phase resyncs after it (" .. tostring(slept[2]) .. ")")

-- keys
local f = io.open("main.lua", "r")
local src = f and f:read("*a") or ""
if f then f:close() end
c.ok(src:find('"vsync", "fps_cap"', 1, true) ~= nil, "main.lua's settings keys carry vsync and fps_cap")

local fails = c.report("smoke_settings")
if fails > 0 then os.exit(1) end
