-- views/PokerEventAnims.lua
--
-- Per-event-kind visual handlers for the poker theater. Kind → fn table.
-- Each handler takes (event, tbl, game) and emits whatever visible
-- effect that event represents. Indexed by kind, so the dispatch is a
-- single table lookup with no if/elseif chain on event.kind.
--
-- The script writer (models/HandScript.lua) generates an ordered event
-- list at deal time; views/TablePanel.draw drains newly-fired events
-- each frame (using tbl.view_event_cursor as a watermark) and routes
-- each event through this table.
--
-- Animations on offer:
--   * post_blind / call / raise / all_in → chips fly from actor seat
--     into the pot (pot label grows via playback_state.pot in tandem).
--   * fold → the seat's two hole cards visibly muck downward and fade.
--   * pot_push → chips fly from the pot to the winner's seat. Replaces
--     the controller's resolution burst when poker theater is on.
--
-- Events without an entry here are no-ops on the view side — the
-- registry-side state mutation (community_count / pot / in_seats /
-- opp_revealed / winner) still fires.

local Anchors     = require("services.AnchorRegistry")
local Table       = require("models.Table")
local Constants   = require("data.constants")
local Decks       = require("models.Decks")
local ChipFlight  = require("views.ChipFlight")
local FlightSystem = require("services.FlightSystem")
local CardSprites = require("views.CardSprites")

-- Card render size for the muck-fold animation. Matches the typical
-- opponent hole-card draw size in TablePanel; tunable.
local MUCK_CARD_W = 24
local MUCK_CARD_H = 32

-- Map a logical script seat (1..n_seats, including the player's seat)
-- to the screen-space anchor position. Player → "you" anchor; opponents
-- → "opp_<visual_idx>" where visual_idx is the 1-based position in
-- tbl.opponents (which excludes the player). The mapping is shifted
-- around the player_seat: opp_idx = seat for seats below player, and
-- seat - 1 for seats above.
local function seatScreenPos(tbl, seat)
    if not tbl or not tbl.playback_state or not seat then return nil end
    local player_seat = tbl.playback_state.player_seat
    local key
    if seat == player_seat then
        key = Table.anchorKey(tbl, "you")
    else
        local opp_idx
        if seat < player_seat then opp_idx = seat
        else                       opp_idx = seat - 1 end
        key = Table.anchorKey(tbl, "opp_" .. opp_idx)
    end
    return Anchors.get(key)
end

-- Convenience wrapper: fly chips for an action's $ amount from the
-- actor's seat into the pot anchor. Used by post_blind/call/raise/all_in.
local function flyChipsToPot(tbl, seat, amount)
    local seat_pos = seatScreenPos(tbl, seat)
    local pot_pos  = Anchors.get(Table.anchorKey(tbl, "pot"))
    ChipFlight.fly(seat_pos, pot_pos, amount, tbl.stake_id, {})
end

local PokerEventAnims = {

    -- Blinds posted at the start of the hand. Same chip-fly as a normal
    -- bet — SB and BB visibly push their forced contributions in.
    post_blind = function(ev, tbl, _game)
        flyChipsToPot(tbl, ev.seat, ev.amount)
    end,

    -- Calling / matching a bet. Fly the delta into the pot.
    call = function(ev, tbl, _game)
        flyChipsToPot(tbl, ev.seat, ev.amount)
    end,

    -- Raising. Same as call from the visual side — chips fly in for the
    -- delta. The pot label updates live from playback_state.pot, so the
    -- player sees the pile grow with each landed bet.
    raise = function(ev, tbl, _game)
        flyChipsToPot(tbl, ev.seat, ev.amount)
    end,

    all_in = function(ev, tbl, _game)
        flyChipsToPot(tbl, ev.seat, ev.amount)
    end,

    -- Folding seat: the two hole cards visibly slide down off the seat
    -- and fade out via FlightSystem's natural duration→alpha curve.
    -- The wider seat dim (seat_alpha * 0.30 in TablePanel) still kicks
    -- in for the rest of the cinematic — that's what conveys "this seat
    -- is out of the hand"; the muck is the moment of folding.
    fold = function(ev, tbl, game)
        if not ev.seat then return end
        local seat_pos = seatScreenPos(tbl, ev.seat)
        if not seat_pos then return end
        -- Destination: below the seat, off the felt. No arc — a quick
        -- straight slide reads as "discarded" rather than "thrown."
        local muck_dest = { seat_pos[1], seat_pos[2] + 60 }
        local sl = game and game.sprite_loader
        if not sl then return end
        local back_sprite
        if Constants.FEATURES and Constants.FEATURES.DECKS then
            back_sprite = Decks.activeSprite(game.state)
        end
        back_sprite = back_sprite
                      or (Constants.GAUNTLET and Constants.GAUNTLET.CARD_BACK_SPRITE)
        if not back_sprite then return end
        local card_render = function(x, y)
            CardSprites.back(sl, back_sprite, x, y, MUCK_CARD_W, MUCK_CARD_H, 1)
        end
        FlightSystem.emitBurst(seat_pos, muck_dest, { card_render, card_render }, {
            duration   = 0.25,
            arc_height = 0,
        })
    end,

    -- Pot push to the winner. Reads ev.amount (snapshot of ws.pot taken
    -- by HandScript BEFORE the applicator zeroes it) so the burst size
    -- matches the visible pot pile right when the chips start flying.
    pot_push = function(ev, tbl, _game)
        if not ev.seat or not ev.amount or ev.amount <= 0 then return end
        local pot_pos    = Anchors.get(Table.anchorKey(tbl, "pot"))
        local target_pos = seatScreenPos(tbl, ev.seat)
        if not pot_pos or not target_pos then return end
        local arrival = (ev.seat == tbl.playback_state.player_seat)
                        and "chip_land_you" or "chip_land_pot"
        ChipFlight.fly(pot_pos, target_pos, ev.amount, tbl.stake_id, {
            tier          = tbl.outcome_tier,
            arrival_sound = arrival,
        })
    end,

    -- check / deal_flop / deal_turn / deal_river / showdown_reveal are
    -- pure state mutations on the table model (community_count /
    -- opp_revealed). Their visible effects are driven elsewhere —
    -- community cards reveal at the right counts via TablePanel's
    -- draw, hole cards flip on opp_revealed. No per-event flight here.
}

return PokerEventAnims
