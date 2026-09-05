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

function HintCtx.build(deps)
    local g   = deps.game
    local sm  = g.state_machine
    local cur = sm and sm.current_state
    local sv  = cur and cur.view
    local screen = sm and sm:current() or nil
    local is_shove = screen == "shove"
    local grind = g.grind
    return {
        state            = g.state,
        pool             = grind and grind.pool,
        grind            = grind,
        screen           = screen,
        shove_phase      = is_shove and sv and sv.phase or nil,
        shove_hold       = is_shove and sv and sv.hold_id or nil,
        shove_cheats     = is_shove and sv and sv.cheatsDealt and sv:cheatsDealt() or 0,
        -- Every chip of the buildup's pour has landed on the pot.
        shove_pot_landed = is_shove and sv and sv.buildup_chips ~= nil
                           and (sv.buildup_arrived_count or 0) >= #sv.buildup_chips
                           and #sv.buildup_chips > 0 or false,
        catalog_open     = cur and (cur.catalog_modal ~= nil) or false,
        -- The deck flyer: open (either screen), or landed folded on the felt.
        deck_flyer_open   = cur and ((cur.deck_flyer and cur.deck_flyer:isOpen())
                                  or (cur.deck_roster_modal and cur.deck_roster_modal:isOpen())) or false,
        deck_flyer_landed = cur and cur.deck_flyer ~= nil and cur.deck_flyer:isLanded() or false,
        anchor_fresh     = deps.anchor_fresh,
    }
end

return HintCtx
