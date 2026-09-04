-- services/FloatingTextSystem.lua
--
-- Floating text popups ("+$2.40", "-$0.15", "WIN STREAK x3"). Owns the
-- list, update logic, and exposes it for rendering.
--
-- emit(text, x, y, opts) — opts is optional, all fields default to the
-- legacy behavior so old call sites work unchanged. New fields:
--
--   scale    — text size multiplier (1.0 default; stacks use ~1.8)
--   color    — RGB override; nil → auto-detect from text prefix
--   color_token — string key (e.g. "amber", "violet") resolved through
--                 Theme tokens by the renderer; lower priority than `color`
--   font     — font key in game.fonts ("heading" default; "kpi" for big)
--   arc_x    — horizontal drift over lifetime in px (0 = straight up)
--   arc_y    — vertical drift over lifetime in px (negative = up;
--              defaults to Constants.FLOATING_TEXT.DRIFT_Y)
--   lifetime — seconds; defaults to Constants.FLOATING_TEXT.DURATION

local FloatingTextSystem = {}

local Motion         = require("services.Motion")
local Constants      = require("data.constants")
local AnchorRegistry = require("services.AnchorRegistry")

local _texts = {}

function FloatingTextSystem.emit(text, x, y, opts)
    opts = opts or {}
    -- Motion: None shows nothing; Low fades in place, briefly; Medium
    -- doesn't drift.
    local lvl = Motion.level("text")
    if lvl <= Motion.NONE then return end
    local arc_x = opts.arc_x or 0
    local arc_y = opts.arc_y or Constants.FLOATING_TEXT.DRIFT_Y
    local lifetime = opts.lifetime or Constants.FLOATING_TEXT.DURATION
    if lvl <= Motion.MEDIUM then arc_x, arc_y = 0, 0 end
    if lvl <= Motion.LOW then lifetime = math.min(lifetime, 0.9) end
    if #_texts >= Constants.FLOATING_TEXT.MAX_ITEMS then
        table.remove(_texts, 1)
    end
    table.insert(_texts, {
        text     = text,
        x        = x,
        y        = y,
        x0       = x,                                       -- spawn position for arc
        y0       = y,
        timer    = lifetime,
        lifetime = lifetime,
        alpha    = 1,
        scale       = opts.scale or 1.0,
        color       = opts.color,                           -- nil → auto / token
        color_token = opts.color_token,                     -- resolved at draw time
        font        = opts.font or "heading",
        arc_x       = arc_x,
        arc_y       = arc_y,
        table       = opts.table,
        -- Size-clamp only: the renderer fits the text inside this table's
        -- panel, WITHOUT the `table` field's kill-on-next-deal lifecycle.
        -- For floats that should outlive the hand (tournament banners).
        fit_table   = opts.fit_table,
        -- Rest destination for persisted floats: an AnchorRegistry key
        -- (plus offset) the float glides to after its rise completes,
        -- instead of freezing where the pop left it. Anchor-based so it
        -- follows its panel through grid repacks.
        settle_anchor = opts.settle_anchor,
        settle_dx     = opts.settle_dx,
        settle_dy     = opts.settle_dy,
        settle_fx     = opts.settle_fx,
        settle_fy     = opts.settle_fy,
        -- Resting font (the pop plays at `font` × `scale`; the parked
        -- number drops to this real font at scale 1 — text never rests
        -- at a fractional scale) and the panel rect the resting spot is
        -- clamped into.
        settle_font   = opts.settle_font,
        clamp_anchor  = opts.clamp_anchor,
        -- Which hand this float belongs to. Emitted during hand N's
        -- settling, when hands_played still reads N-1; N-1+2 therefore
        -- means "a hand AFTER this float's own has completed". The serial
        -- backstop below removes on that, because a cascade chain can
        -- deal AND resolve a whole hand inside one controller frame —
        -- the state-based check never witnesses the "dealing" it keys on,
        -- and without the serial two hands' floats stack on one felt.
        hand_stamp    = opts.table and opts.table.hands_played or nil,
    })
end

-- Hold-then-fade alpha curve: stay fully opaque for the first chunk of
-- the lifetime, fade only over the tail. So the player has time to
-- actually READ the text before it starts dissolving. With HOLD = 0.6:
-- 60% of lifetime is full alpha, 40% is the linear fade.
local ALPHA_HOLD = 0.6

-- Settle-anchor floats: fraction of the lifetime the pop holds at full
-- size before the glide to the rest spot begins (~0.55s at the default
-- 1.6s lifetime). Read the number, then it gets out of the way.
local SETTLE_HOLD = 0.35

function FloatingTextSystem.update(dt)
    for i = #_texts, 1, -1 do
        local t = _texts[i]
        local tbl = t.table   -- nil for non-resolution floaters

        -- Track whether the floater has ever seen its table reach idle.
        -- The floater spawns during "settling"; _finalizeHand sets the
        -- table to "idle" in the same frame or the next.  We only kill
        -- the floater once it has witnessed idle AND the table then
        -- leaves idle again (a new deal started).
        if tbl and tbl.state == "idle" then
            t.saw_idle = true
        end

        local stale_hand = tbl and t.hand_stamp
            and (tbl.hands_played or 0) >= t.hand_stamp + 2
        if tbl and ((t.saw_idle or t.has_persisted)
                    and tbl.state ~= "idle" and tbl.state ~= "settling"
                    or stale_hand) then
            -- Table was resting (floater landed), now a new hand
            -- started → remove immediately. The settling exception lets
            -- a floater that froze during the settling beat survive into
            -- idle instead of dying on the settling→idle transition.
            -- stale_hand is the serial backstop: a later hand COMPLETED
            -- (however fast), so this float's hand is no longer the one
            -- on the felt.
            table.remove(_texts, i)
        else
            t.timer = t.timer - dt
            local progress = 1 - (t.timer / t.lifetime)      -- 0 → 1

            if tbl then
                -- Table-attached: NO fade — fully opaque, then persisted
                -- for as long as the hand's residue holds the felt (the
                -- last-hand result stays readable until the next deal
                -- sweeps both). Settle-anchor floats persist EARLY: the
                -- pop holds for the first stretch of the lifetime, then
                -- the glide below takes over — pop, then settle, no slow
                -- drift in between. Allowed from settling too: on slower
                -- paces the settling beat outlasts the hold, and expiring
                -- there would drop the number the residue exists to show.
                local persist_at = t.settle_anchor and SETTLE_HOLD or 1.0
                if (tbl.state == "idle" or tbl.state == "settling")
                   and progress >= persist_at then
                    -- Settle floats change size by swapping to the resting
                    -- FONT, once, as the glide starts — moving text masks
                    -- the swap, and the parked number is a crisp raster
                    -- size, never scaled-down text.
                    if not t.has_persisted and t.settle_anchor
                       and t.settle_font then
                        t.font  = t.settle_font
                        t.scale = 1
                    end
                    t.timer = 0.001
                    t.has_persisted = true
                end
                t.alpha = 1.0
            else
                -- Normal floater: hold-then-fade curve.
                if progress < ALPHA_HOLD then
                    t.alpha = 1
                else
                    t.alpha = (1 - progress) / (1 - ALPHA_HOLD)
                end
            end

            if t.has_persisted and t.settle_anchor then
                -- Pop held; now glide fast to the rest spot, already in
                -- the resting font. The anchor is re-read every frame so
                -- a grid repack moves the resting number with its panel.
                -- settle_fx/fy are FRACTIONS of the anchor rect's w/h
                -- (panel-relative — inside the panel by construction);
                -- settle_dx/dy are the older absolute-px offsets.
                local a = AnchorRegistry.get(t.settle_anchor)
                if a then
                    local tx, ty
                    if t.settle_fx and a[3] and a[4] then
                        tx = a[1] + a[3] * t.settle_fx
                        ty = a[2] + a[4] * (t.settle_fy or 0)
                    else
                        tx = a[1] + (t.settle_dx or 0)
                        ty = a[2] + (t.settle_dy or 0)
                    end
                    local k = math.min(1, dt * 10)
                    t.x = t.x + (tx - t.x) * k
                    t.y = t.y + (ty - t.y) * k
                end
            else
                t.x = t.x0 + t.arc_x * math.min(1.0, progress)
                t.y = t.y0 + t.arc_y * math.min(1.0, progress)
            end

            -- Non-persisted texts expire normally when timer hits 0.
            if t.timer <= 0 and not t.has_persisted then
                table.remove(_texts, i)
            end
        end
    end
end

function FloatingTextSystem.getTexts()
    return _texts
end

-- Drop every floater attached to this table. Called when a table is
-- closed: a discarded Table object stays "idle" forever, so a resting
-- floater on it would otherwise never hit its leaves-idle removal.
function FloatingTextSystem.dropForTable(tbl)
    if not tbl then return end
    for i = #_texts, 1, -1 do
        if _texts[i].table == tbl then
            table.remove(_texts, i)
        end
    end
end

function FloatingTextSystem.clear()
    _texts = {}
end

return FloatingTextSystem
