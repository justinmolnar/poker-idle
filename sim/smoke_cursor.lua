-- sim/smoke_cursor.lua
--
-- The player's cursor (services/PlayerCursor, services/CursorIntent):
--   art       every shape builds with its rim; its hot spot is an outline
--             or body pixel; badges sit inside the image in their colour
--   build     apply() makes every kind, a pressed variant (one art pixel
--             lower, same hot spot) and the glitch frames, at a size that
--             follows the window; rebuilds only when that size changes
--   set       setCursor only on a change
--   priority  wait over everything; fist; lock / no; point; open; info
--             (a tooltip and nothing else); arrow; a maxed button is not a
--             refusal
--   glitch    only under strain or after the underflow; never while
--             waiting, never at Motion None
--   flow      the mouse on an upgrade button, through the view's own hit
--             test, gives point; on a table header, open
--
-- Standalone: `lua sim/smoke_cursor.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()
local Cfg = require("data.player_cursor")

-- ── art ────────────────────────────────────────────────────────────────
for name, sh in pairs(Cfg.shapes) do
    local w = #sh.rows[1]
    local same = true
    for _, r in ipairs(sh.rows) do if #r ~= w then same = false end end
    c.ok(same, name .. ": every row is " .. w .. " wide")
end
for name, b in pairs(Cfg.badges) do
    local w = #b.rows[1]
    local same = true
    for _, r in ipairs(b.rows) do if #r ~= w then same = false end end
    c.ok(same, "badge " .. name .. ": every row is " .. w .. " wide")
end

local PC = require("services.PlayerCursor")
for kind in pairs(Cfg.kinds) do
    local a = PC.art(kind)
    local hot = a.grid[a.hot[2] + 1] and a.grid[a.hot[2] + 1][a.hot[1] + 1]
    c.ok(hot == "X" or hot == "#", kind .. ": the hot spot lands on the shape (" .. tostring(hot) .. ")")
    local rimmed = false
    for _, row in ipairs(a.grid) do for _, ch in ipairs(row) do if ch == "O" then rimmed = true end end end
    c.ok(rimmed, kind .. ": has its white rim")
end
c.ok(PC.art("info").badge and PC.art("no").badge and PC.art("lock").badge, "the badged kinds carry a badge colour")
c.ok(PC.art("info").w > PC.art("arrow").w, "a badge grows the image")

-- ── build ──────────────────────────────────────────────────────────────
local made, set_calls = 0, 0
local height = 1080
love.graphics.getHeight = function() return height end
love.image = { newImageData = function(w, h)
    local px = {}
    return { w = w, h = h, px = px,
             setPixel = function(self, x, y, r, g, b, a) px[y * w + x] = { r, g, b, a } end }
end }
local hots = {}
love.mouse.newCursor = function(data, hx, hy)
    made = made + 1
    local cur = { data = data, hx = hx, hy = hy, release = function() end }
    hots[#hots + 1] = cur
    return cur
end
love.mouse.setCursor = function() set_calls = set_calls + 1 end

c.eq(PC.pixelSize(720), 3, "three screen pixels per art pixel at 720p")
c.eq(PC.pixelSize(1080), 4, "four at 1080p")
c.ok(PC.apply(), "the cursors are built")
local n_kinds = 0
for _ in pairs(Cfg.kinds) do n_kinds = n_kinds + 1 end
c.eq(made, n_kinds * (2 + Cfg.glitch.frames), "every kind, its pressed variant and its glitch frames")
local base, pressed = PC.cursorFor("point"), PC.cursorFor("point", "pressed")
c.ok(base and pressed and base.hx == pressed.hx and base.hy == pressed.hy, "pressed keeps the hot spot")
c.ok(pressed.data.h == base.data.h + 4, "and sits one art pixel lower")
local arrow = PC.cursorFor("arrow")
c.ok(arrow.hx == 4 and arrow.hy == 4, "the arrow's hot spot is its tip, inside the rim")
local tip = arrow.data.px[(4) * arrow.data.w + 4]
c.ok(tip and tip[1] == 0, "the tip is the black outline")
local g1 = PC.cursorFor("arrow", 1)
c.ok(g1 and g1.hx == arrow.hx and g1.hy == arrow.hy, "a glitch frame keeps the hot spot")

PC.apply()
c.eq(made, n_kinds * (2 + Cfg.glitch.frames), "the same window size builds nothing new")

-- ── set ────────────────────────────────────────────────────────────────
set_calls = 0
PC.set("point"); PC.set("point"); PC.set("point", true); PC.set("point", true)
c.eq(set_calls, 2, "setCursor only when the cursor changes")
c.ok(PC.current() == PC.cursorFor("point", "pressed"), "pressed shows the pressed variant")

-- ── priority ───────────────────────────────────────────────────────────
local CI = require("services.CursorIntent")
local got
local function apply(kind, pr, gl) got = { kind, pr, gl } end
local function pick(marks, opts)
    CI.begin()
    for _, m in ipairs(marks) do CI.mark(m) end
    opts = opts or {}
    opts.apply = apply
    return (CI.resolve(opts))
end
c.eq(pick({}), "arrow", "nothing under the pointer: the arrow")
c.eq(pick({}, { tooltip = true }), "info", "a tooltip and nothing to click: info")
c.eq(pick({ "point" }, { tooltip = true }), "point", "a clickable thing with a tooltip: point")
c.eq(pick({ "open" }, { tooltip = true }), "open", "a header: open")
c.eq(pick({ "open", "point" }), "point", "a header button over the header: point")
c.eq(pick({}, { denied = true, tooltip = true }), "no", "a refusal: no")
c.eq(pick({ "lock" }, { denied = true }), "lock", "a locked control: lock, not no")
c.eq(pick({ "point", "fist" }), "fist", "carrying a table: fist over anything")
c.eq(pick({ "fist", "point" }, { waiting = true, denied = true }), "wait", "the story holding the click: wait over everything")
pick({ "point" }, { pressed = true })
c.ok(got[2] == true, "the button down is passed on")

-- ── glitch ─────────────────────────────────────────────────────────────
local function glitchSeen(opts)
    CI.reset()
    local seen = false
    for i = 0, 1200 do
        CI.begin()
        local o = { apply = apply, now = i * (1 / 60) }
        for k, v in pairs(opts) do o[k] = v end
        local _, _, gl = CI.resolve(o)
        if gl then seen = true end
    end
    return seen
end
c.ok(not glitchSeen({}), "no glitch on a calm board")
c.ok(glitchSeen({ strain = 2 }), "a glitch now and then over the focus cap")
c.ok(glitchSeen({ underflow = true }), "and after the underflow")
c.ok(not glitchSeen({ strain = 2, waiting = true }), "never while waiting")
c.ok(not glitchSeen({ strain = 2, still = true }), "never at Motion None")

-- ── flow ───────────────────────────────────────────────────────────────
do
    local H = require("sim.harness")
    local F = Stub.font(16)
    local w = H.world({ bankroll = 1e9 })
    local g = w.game
    g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
    g.state_machine = { states = {}, switch = function() end, current = function() return "grind" end }
    local img = { getWidth = function() return 32 end, getHeight = function() return 32 end,
                  getDimensions = function() return 32, 32 end, setFilter = function() end, release = function() end }
    g.sprite_loader = { getSprite = function() return img end, getSpriteFor = function() return img end,
        hasSprite = function() return true end, backColor = function() return { 0.5, 0.5, 0.5 } end,
        setSprite = function() end, itemArt = function() return img end }
    Stub.recorder()
    love.graphics.newFont = function() return F end
    love.graphics.getFont = function() return F end
    love.graphics.newShader = function() return { send = function() end } end
    for _ = 1, 3 do w:open("s001", "zoom") end
    w:tick(1)
    local HoverService = require("services.HoverService")
    local AR = require("services.AnchorRegistry")
    local view = require("views.GrindView"):new(g, w.ctrl)
    g.sim_frozen = true
    local mx, my = -1, -1
    love.mouse.getPosition = function() return mx, my end
    love.mouse.getX = function() return mx end
    love.mouse.getY = function() return my end
    local function frame()
        H.clock = H.clock + 1 / 60
        AR.tick(); HoverService.clear()
        require("services.Tooltip").clear()
        CI.begin()
        view:update(1 / 60); view:draw(nil)
        return CI.marked()
    end
    for _ = 1, 3 do frame() end
    local r = AR.get("buy_runup_pot_control")
    if r then mx, my = r[1] + 10, r[2] + 10 end
    frame()
    c.eq(frame(), "point", "the mouse on an upgrade button: point")
    local header
    for _, hb in ipairs(view.hit_boxes) do if hb.action == "drag_table" then header = hb; break end end
    if header then mx, my = header.x + 2, header.y + header.h * 0.5 end
    frame()
    local k = frame()
    c.ok(header and (k == "open" or k == "point"), "the mouse on a table header: open (or a header button): " .. tostring(k))
end

if c.report("smoke_cursor") > 0 then os.exit(1) end
