-- services/ClickFX.lua
--
-- Every click answers where it lands (docs/sound-checklist.md section 8).
-- main.lua brackets each left click: `begin(x, y)` before the screens see
-- it, `finish()` after. In between, ClickFlash records whether a press
-- happened (a button did something) or a refusal (ClickFlash.deny). Then:
--
--   result  a press fired: the surface's sound under the button click
--           (ClickFlash already played it), the surface's specks and a gold
--           burst
--   denied  ClickFlash.deny fired, or the surface under the click is a
--           disabled button (registered as "denied"): the dull thunk, dark
--           specks, the button shakes
--   dead    nothing took it: the surface's own sound, specks and reaction
--
-- The surface comes from services/ClickSurfaces; the numbers from
-- data/clicks.lua. Rapid clicks build a streak that lifts the pitch and the
-- specks. `cursor(x, y)` is a cursor's click: same surface, higher,
-- quieter, smaller, no streak.
--
-- Engine-free apart from the services it calls: sound goes through the
-- injected `ClickFX.play(name, opts)`, a room item's foley through
-- `ClickFX.onItem(id)`, a chip pile's hop through `ClickFX.onPile(key, x,
-- y)` (main.lua and views set them), so a headless run is silent and the
-- service names no view.

local ClickFlash    = require("services.ClickFlash")
local ClickSurfaces = require("services.ClickSurfaces")
local Sparks        = require("services.Sparks")
local Poke          = require("services.Poke")
local Data          = require("data.clicks")

local ClickFX = {}

ClickFX.play   = nil   -- function(name, opts)
ClickFX.onItem = nil   -- function(item_id)
ClickFX.onPile = nil   -- function(pile_key, x, y)

local _x, _y, _active = 0, 0, false
local _streak, _last_t = 0, -1e9
local _opts = {}
local _burst = {}

local function now() return (love and love.timer and love.timer.getTime()) or os.clock() end

local function play(name, vol, pitch)
    if not (name and ClickFX.play) then return end
    _opts.volume_mult, _opts.pitch = vol, pitch
    ClickFX.play(name, _opts)
end

-- The effect itself. `outcome` result / denied / dead; `cursor` true for a
-- cursor's click; `deny_key` the poke key a handler refused on.
local function fire(x, y, surf, outcome, streak, cursor, deny_key)
    local mat = (outcome == "denied") and "denied" or surf.material
    local spec = Data.materials[mat] or Data.materials.wall
    local st, cs = Data.streak, Data.cursor
    local pitch = (spec.pitch or 1) * (1 + streak * st.pitch_step)
    local vol   = spec.volume or 0.5
    local scale = 1 + streak * st.specks_step
    if outcome == "result" then vol = vol * Data.result.surface_volume end
    if cursor then pitch, vol, scale = pitch * cs.pitch, vol * cs.volume, scale * cs.specks end

    if mat == "item" and surf.item then
        if ClickFX.onItem then ClickFX.onItem(surf.item) end
    else
        play(spec.sound, vol, pitch)
    end

    _burst.tint, _burst.scale = surf.tint, scale
    Sparks.burst(x, y, spec, _burst)
    if outcome == "result" and not cursor then Sparks.burst(x, y, Data.result, _burst) end

    -- The reaction: a refusal shakes the refused thing, anything else pokes
    -- the surface's key with its kind, leaning away from the click.
    local key = (outcome == "denied" and (deny_key or surf.poke)) or surf.poke
    local kind = (outcome == "denied") and "shake" or (surf.poke_kind or spec.poke)
    if key and kind then
        local dir = (x < surf.x + surf.w * 0.5) and 1 or -1
        Poke.hit(key, kind, cursor and 0.5 or 1, dir)
    end
    if surf.pile and ClickFX.onPile and outcome ~= "denied" then ClickFX.onPile(surf.pile, x, y) end

    -- The House poster: now and then the speaker answers with a tick.
    if surf.poke == "house:poster" and not cursor and love and love.math
       and love.math.random() < (Data.poster_notice_chance or 0) then
        play("click_speaker", 0.2, 0.8)
        Poke.hit("house:speaker", "rattle", 0.5)
    end
end

function ClickFX.begin(x, y)
    _x, _y, _active = x, y, true
    ClickFlash.beginDispatch()
end

-- Decides and plays the click begun by `begin`. Returns the outcome and the
-- surface (for the checks).
function ClickFX.finish()
    if not _active then return nil end
    _active = false
    local d = ClickFlash.endDispatch()
    local surf = ClickSurfaces.at(_x, _y)
    local outcome = "dead"
    if d.pressed then outcome = "result"
    elseif d.denied or surf.material == "denied" then outcome = "denied" end
    local t = now()
    if t - _last_t <= Data.streak.window then
        _streak = math.min(Data.streak.cap, _streak + 1)
    else
        _streak = 0
    end
    _last_t = t
    fire(_x, _y, surf, outcome, _streak, false, d.deny_key)
    return outcome, surf
end

-- A cursor's click at (x, y): it pressed a button, so a result, in the
-- cursor's smaller voice.
function ClickFX.cursor(x, y)
    if not (x and y) then return end
    fire(x, y, ClickSurfaces.at(x, y), "result", 0, true, nil)
end

function ClickFX.streak() return _streak end

return ClickFX
