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

local Cursor = require("models.Cursor")
local Theme  = require("views.Theme")

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

    -- Build the map of claimable DEAL hit-boxes (by idx) — skip muted tables.
    local deal_hbs = {}
    if hit_boxes then
        for _, hb in ipairs(hit_boxes) do
            if hb.action == "deal" and not hb.cursor_muted and hb.idx then
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
    end
end

function CursorPool.draw()
    if #_cursors == 0 then return end
    -- Fill pass — bright primary so cursors pop above the felt green.
    Theme.setColor(Theme.fg.heading, 0.95)
    for _, c in ipairs(_cursors) do
        c:drawFill()
    end
    -- Outline pass for contrast.
    Theme.setColor(Theme.border.strong, 1.0)
    love.graphics.setLineWidth(1)
    for _, c in ipairs(_cursors) do
        c:drawOutline()
    end
end

return CursorPool
