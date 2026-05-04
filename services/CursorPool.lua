-- services/CursorPool.lua
--
-- Stateless module — autonomous-cursor swarm. Mirrors the HoverService
-- convention: no instance, no constructor; module-private state lives in
-- file-local upvalues; callers invoke `update` and `draw` once per frame.
--
-- Lifecycle:
--   1. Each frame, the active state's update calls
--      CursorPool.update(dt, hit_boxes, ctx, dispatcher).
--   2. The pool sizes itself to ctx.cursor_count (gated by
--      ctx.cursor_unlocked); each cursor's state machine advances; on
--      click-arrival, dispatcher(hit_box) is invoked — the same path mouse
--      clicks use.
--   3. The active view's draw calls CursorPool.draw() last so cursors
--      render above panels and sidebars.
--
-- Engine-agnostic: this service sees a hit_box list with an `action`
-- string. It targets only `action == "deal"` for v1, but the constant
-- could be parameterized later. No knowledge of poker.

local Cursor       = require("models.Cursor")
local Theme        = require("views.Theme")
local SoundService = require("services.SoundService")

local CursorPool = {}

-- Module-private state.
local _cursors = {}               -- list of Cursor instances
local _last_W, _last_H = 1280, 720  -- last seen screen dimensions, for spawn-on-grow

-- ── Tuning constants ───────────────────────────────────────────────────
-- Speed expressed as a fraction of the screen diagonal per second so the
-- visual feel is consistent across resolutions.
local BASE_CURSOR_SPEED = 0.10    -- ~10s diagonal cross at L0 (deliberately
                                  -- slow at first cursor — Cursor Speed
                                  -- run-upgrade is what makes the swarm fly)

-- ── Public API ─────────────────────────────────────────────────────────

-- Wipe pool. Called on F6/F7 fullReset and prestige to avoid dangling state.
function CursorPool.reset()
    _cursors = {}
end

-- Per-frame update. dispatcher(hb) fires when a cursor reaches the center
-- of its claimed hit-box.
function CursorPool.update(dt, hit_boxes, ctx, dispatcher)
    local W, H = love.graphics.getDimensions()
    _last_W, _last_H = W, H

    -- Gate: catalog unlock + nonzero count.
    local unlocked = ctx and ctx.cursor_unlocked
    local desired  = (ctx and math.max(0, math.floor(ctx.cursor_count or 0))) or 0
    if not unlocked then desired = 0 end

    -- Resize pool toward `desired`.
    while #_cursors < desired do
        local cx = W * (0.3 + math.random() * 0.4)
        local cy = H * (0.3 + math.random() * 0.4)
        _cursors[#_cursors + 1] = Cursor:new(cx, cy)
    end
    while #_cursors > desired do
        _cursors[#_cursors] = nil
    end

    if desired == 0 then return end

    -- Build the map of claimable hit-boxes (by idx) — skip muted tables.
    -- DEAL is always cursor-clickable; REBUY only when the catalog perk
    -- is owned (ctx.cursor_rebuy_unlocked) and the per-table rebuy-mute
    -- flag isn't set. A given table only ever has one of DEAL / REBUY
    -- visible at a time, so keying by idx is unambiguous.
    local rebuy_unlocked = ctx and ctx.cursor_rebuy_unlocked
    local deal_hbs = {}
    if hit_boxes then
        for _, hb in ipairs(hit_boxes) do
            if hb.action == "deal" and not hb.cursor_muted and hb.idx then
                deal_hbs[hb.idx] = hb
            elseif rebuy_unlocked and hb.action == "rebuy"
                   and not hb.cursor_rebuy_muted and hb.idx then
                deal_hbs[hb.idx] = hb
            end
        end
    end

    -- Pre-validate each seeking cursor's claim against this frame's hit-boxes,
    -- and seed the claims map. Stale targets (table now busy / removed /
    -- muted) get released so the cursor can re-scan.
    local claims = {}
    for _, c in ipairs(_cursors) do
        if c.state == "seeking" and c.target_idx then
            if deal_hbs[c.target_idx] then
                claims[c.target_idx] = true
            else
                c:releaseTarget()
            end
        end
    end

    -- Compute speed in px/sec from screen diagonal × ctx multiplier.
    local diag       = math.sqrt(W * W + H * H)
    local speed_frac = BASE_CURSOR_SPEED * ((ctx and ctx.cursor_speed_mult) or 1)
    local speed_px   = speed_frac * diag

    for _, c in ipairs(_cursors) do
        c:update(dt, deal_hbs, claims, speed_px, W, H, dispatcher)
        -- Play the cursor-tap sound for cursors that just dispatched. The
        -- flag is set inside Cursor:update at the click site; consume here
        -- so it only fires once per click.
        if c._just_dispatched then
            c._just_dispatched = nil
            SoundService.playNamed("cursor_tap")
        end
    end
end

-- Arrow-cursor polygon (clockwise from tip). Top-left point is the
-- click hotspot — translated to the cursor's (x, y). Real OS cursors
-- don't rotate with motion, so neither do these. Sized ~1.3× a classic
-- 12×18 OS arrow so the swarm reads visibly bigger than the player's
-- own mouse pointer (additional differentiator: warm Theme.fg.heading
-- fill instead of system white).
local CURSOR_POLY = {
    0,  0,    -- tip
    15, 15,   -- arrow-head bottom-right corner
    8,  15,   -- inner notch where tail begins
    12, 23,   -- tail outer-right corner
    9,  24,   -- tail outer-left corner
    5,  16,   -- tail inner meets body
    0,  21,   -- body bottom-left
}
-- Pre-triangulated for fill (the polygon is concave — love2d's
-- polygon("fill", ...) requires convex). Lines render the closed poly
-- directly so the outline traces the silhouette, not the seams.
local CURSOR_TRIS = love.math.triangulate(CURSOR_POLY)

local function drawShape(c, mode)
    love.graphics.push()
    love.graphics.translate(c.x, c.y)
    if mode == "fill" then
        for _, tri in ipairs(CURSOR_TRIS) do
            love.graphics.polygon("fill", tri)
        end
    else
        love.graphics.polygon("line", CURSOR_POLY)
    end
    love.graphics.pop()
end

function CursorPool.draw()
    if #_cursors == 0 then return end
    -- Fill pass — warm cream so cursors pop above the felt green and
    -- read distinctly from the player's white OS mouse pointer.
    Theme.setColor(Theme.fg.heading, 0.95)
    for _, c in ipairs(_cursors) do
        drawShape(c, "fill")
    end
    -- Outline pass for contrast.
    Theme.setColor(Theme.border.strong, 1.0)
    love.graphics.setLineWidth(1)
    for _, c in ipairs(_cursors) do
        drawShape(c, "line")
    end
end

return CursorPool
