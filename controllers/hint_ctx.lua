-- controllers/hint_ctx.lua
--
-- The ctx that condition kinds (models/hint_rules.lua) evaluate against:
-- the game state, the grind's pool, and the screen-level facts no
-- controller owns (which screen is up, where the shove's beat machine is,
-- whether a modal that doubles as a teaching surface is open). Built once
-- per tick by main.lua and handed to BOTH the story director and the hint
-- controller, so a beat and a popup always read the same frame.
--
-- deps = { game, anchor_fresh = fn(name) -> bool }

local HintCtx = {}

-- Fill `ctx` in place and return it. main.lua keeps one ctx table and one
-- deps table for the process: every field is written every tick (a field
-- that is absent this tick is written nil), so a reader always sees this
-- frame and nothing allocates. The story director keeps the latest ctx
-- for a line said outside the script; it only reads `screen` off it, so
-- the shared table is what it wants.
function HintCtx.fill(ctx, deps)
    local g   = deps.game
    local sm  = g.state_machine
    local cur = sm and sm.current_state
    local sv  = cur and cur.view
    local screen = sm and sm:current() or nil
    local is_shove = screen == "shove"
    local grind = g.grind
    ctx.state            = g.state
    ctx.pool             = grind and grind.pool
    ctx.grind            = grind
    ctx.screen           = screen
    ctx.shove_phase      = is_shove and sv and sv.phase or nil
    ctx.shove_hold       = is_shove and sv and sv.hold_id or nil
    ctx.shove_cheats     = is_shove and sv and sv.cheatsDealt and sv:cheatsDealt() or 0
    -- Every chip of the buildup's pour has landed on the pot.
    ctx.shove_pot_landed = is_shove and sv and sv.buildup_chips ~= nil
                           and (sv.buildup_arrived_count or 0) >= #sv.buildup_chips
                           and #sv.buildup_chips > 0 or false
    -- The book: OPEN (the spread, either screen), or landed closed on the
    -- felt (the beat that points at it). A book thrown but still shut is
    -- not open: the lesson about its pages waits for the click.
    ctx.catalog_open     = cur and cur.catalog_modal ~= nil and cur.catalog_modal:isOpen() or false
    ctx.catalog_landed   = cur and cur.catalog_modal ~= nil and cur.catalog_modal.isLanded ~= nil
                           and cur.catalog_modal:isLanded() or false
    -- The deck flyer: open (either screen), or landed folded on the felt.
    ctx.deck_flyer_open   = cur and ((cur.deck_flyer and cur.deck_flyer:isOpen())
                                  or (cur.deck_roster_modal and cur.deck_roster_modal:isOpen())) or false
    ctx.deck_flyer_landed = cur and cur.deck_flyer ~= nil and cur.deck_flyer:isLanded() or false
    ctx.anchor_fresh     = deps.anchor_fresh
    return ctx
end

-- A fresh ctx (the sims, and anything that wants its own copy).
function HintCtx.build(deps)
    return HintCtx.fill({}, deps)
end

return HintCtx
