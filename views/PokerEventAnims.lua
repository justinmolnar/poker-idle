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
local ChipPile    = require("views.ChipPile")
local FlightSystem = require("services.FlightSystem")
local CardSprites = require("views.CardSprites")
local FeedbackIntensity = require("data.feedback_intensity")
local StakeThemes = require("data.stake_themes")
local Stakes      = require("data.stakes")
local Lookups     = require("utils.lookups")

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

-- Wall-clock seconds until the next scripted event fires, or nil when
-- this is the last one.
--
-- The script's timestamps are in SCRIPT time, which runs at
-- tbl._script_pace × wall time (game-type pace, Energy Drink, and so on).
-- At a fast pace two actions can be a couple of hundred milliseconds
-- apart, and a flight built for a leisurely 0.6s is then still crossing
-- the felt while the next three bets land on top of it. Flights that
-- know their budget can fit inside it.
local function timeToNextEvent(tbl)
    local script = tbl and tbl.script
    local nxt    = script and script[(tbl.script_idx or 0) + 1]
    if not nxt or not nxt.t then return nil end
    local pace = tbl._script_pace or 1
    if pace <= 0 then return nil end
    local left = (nxt.t - (tbl.script_timer or 0)) / pace
    if left <= 0 then return nil end
    return left
end

-- Fly chips for an action's $ amount from the actor's seat into the pot
-- pile. Used by post_blind/call/raise/all_in.
--
-- The pot is a real pile (views/ChipPile), so the chips are RESERVED into
-- it: it grows as they land, not when they launch. When the actor is the
-- player, the chips are taken out of their stack pile too, so the same
-- chips leave one collection and join the other.
local function flyChipsToPot(tbl, seat, amount)
    local seat_pos = seatScreenPos(tbl, seat)
    local pot_key  = Table.anchorKey(tbl, "pot")
    local pot_pos  = Anchors.get(pot_key)
    local is_player = tbl.playback_state and seat == tbl.playback_state.player_seat
    ChipFlight.transfer(seat_pos, pot_pos, {
        amount     = amount,
        stake_id   = tbl.stake_id,
        source_key = is_player and Table.anchorKey(tbl, "you") or nil,
        dest_key   = pot_key,
        -- Land before the next action does.
        budget     = timeToNextEvent(tbl),
    })
end

-- The panel this table is drawn in, as { w, h }, off the size TablePanel
-- stamps on its center anchor. Effects belonging to one table scale to it
-- instead of to the screen. nil before the panel's first draw.
local function panelSize(tbl)
    local c = Anchors.get(Table.anchorKey(tbl, "center"))
    if c and c[3] and c[4] then return { c[3], c[4] } end
    return nil
end

-- Where a pot the player just won actually ENDS UP, in order, for a burst
-- that splits between piles.
--
-- A cash table can only hold its buy-in. A pot bigger than the headroom
-- left in the stack fills the stack to the cap and the remainder lands in
-- the bankroll — so the chips have two destinations, and the burst has to
-- show that rather than pouring everything into the stack and then
-- re-emitting the excess a beat later.
--
-- The cap arithmetic mirrors GrindController's resolution branch
-- (new_stack > cap → overflow), read off the same running stack the panel
-- is displaying. This decides where chips FLY; the controller stays
-- authoritative for the money, and a disagreement just means the piles
-- reconcile, which is what they're for.
--
-- Chip-stack tournaments have no cap — a winning seat can hold the whole
-- pool — so everything goes to the stack. tbl.seat_stacks is the same
-- signal TablePanel uses to tell the two table kinds apart.
-- Returns the dests list and the player's committed chips, which the
-- caller needs to size the burst: winning gets you your own contribution
-- BACK on top of the net delta, and the two land in different piles.
local function potDestinations(tbl, seat_pos)
    local you = { key = Table.anchorKey(tbl, "you"), xy = seat_pos }
    local ps        = tbl.playback_state
    local seat      = ps and ps.player_seat
    local committed = (seat and ps.per_seat_total and ps.per_seat_total[seat]) or 0
    if tbl.seat_stacks then return { you }, committed end

    local stake = Lookups.findById(Stakes, tbl.stake_id)
    local cap   = (stake and stake.buy_in) or 0
    if cap <= 0 then return { you }, committed end

    local running   = math.max(0, (tbl.stack or 0) - committed)
    you.amount      = math.max(0, cap - running)

    local bank_xy = Anchors.get("bankroll")
    if not bank_xy then return { you }, committed end
    return { you, { key = "bankroll", xy = bank_xy } }, committed
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
        if Decks.systemUnlocked(game.state) then
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

    -- Pot push to the winner. The pot pile is emptied INTO the winner —
    -- every chip departs the slot it was occupying in the pot, and when
    -- the winner is the player each one is inserted into their stack at
    -- the pixel its flight ended. Reads ev.amount (snapshot of ws.pot
    -- taken by HandScript BEFORE the applicator zeroes it) so the take
    -- matches the pile the player is looking at.
    pot_push = function(ev, tbl, _game)
        if not ev.seat or not ev.amount or ev.amount <= 0 then return end
        local pot_key    = Table.anchorKey(tbl, "pot")
        local pot_pos    = Anchors.get(pot_key)
        local target_pos = seatScreenPos(tbl, ev.seat)
        if not target_pos then return end
        local is_player = (ev.seat == tbl.playback_state.player_seat)

        -- Jackpot win: the pot doesn't get carried over, it DETONATES —
        -- and then the debris regroups into your stack, so the spectacle
        -- and the payout are the same chips. Decided here rather than from
        -- the controller's pot_explode_pending flag because that flag
        -- arrives at settling, a beat after this event has already emptied
        -- the pot pile; by then there'd be nothing left to blow apart.
        -- Same tier data the controller reads, so the two can't disagree.
        -- Needs a pile with visible chips to come apart. A surface too
        -- small to draw one (mini panels register no pot pile at all)
        -- falls through to the ordinary carry-over below rather than
        -- losing the payout to an explosion with nothing to explode.
        local intensity = FeedbackIntensity[tbl.outcome_tier or ""]
        if is_player and intensity and intensity.chip_burst and not tbl.pot_exploded then
            local debris = ChipPile.takeAll(pot_key)
            if debris then
                local stake_theme = StakeThemes[tbl.stake_id]
                tbl.pot_exploded = true
                -- Same fabrication as the ordinary push below: what comes
                -- apart is the real pot, what regroups is the real payout.
                local payout = math.abs(tbl.outcome_delta or 0)
                local dests, committed = potDestinations(tbl, target_pos)
                ChipFlight.explodeTaken(debris, {
                    tint         = stake_theme and stake_theme.chip_tint,
                    scale        = ChipPile.scale(pot_key),
                    dests        = dests,
                    within       = panelSize(tbl),
                    fabricate    = payout + committed,
                    gather_sound = "chip_land_you",
                })
                return
            end
        end

        -- The payout, not the pot. Late-game multipliers mean a $2 pot can
        -- settle for four figures; the pot itself stays honest all hand
        -- (see drawPotLabel) and the difference is fabricated HERE, at the
        -- moment it becomes real. outcome_delta is the same number the
        -- controller applies a beat later, so the chips and the money
        -- agree.
        local payout = math.abs(tbl.outcome_delta or 0)
        local dests, committed
        if is_player then dests, committed = potDestinations(tbl, target_pos) end
        -- What actually moves. outcome_delta is the NET result, so a win
        -- also hands back the chips you put in: the stack refills to the
        -- cap by `committed` and the bankroll takes the delta. That's
        -- exactly what the controller's resolution does to the numbers a
        -- beat later, so the chips and the money can't disagree.
        local moving = math.max(ev.amount, payout + (committed or 0))
        ChipFlight.transfer(pot_pos, target_pos, {
            amount        = moving,
            fabricate     = moving > ev.amount,
            stake_id      = tbl.stake_id,
            tier          = tbl.outcome_tier,
            source_key    = pot_key,
            -- Split across the stack and the bankroll: a payout past the
            -- table's buy-in cap lands in both, and flying it all into the
            -- stack only to spill it out again a moment later is a lie.
            dests         = dests,
            arrival_sound = is_player and "chip_land_you" or "chip_land_pot",
        })
    end,

    -- check / deal_flop / deal_turn / deal_river / showdown_reveal are
    -- pure state mutations on the table model (community_count /
    -- opp_revealed). Their visible effects are driven elsewhere —
    -- community cards reveal at the right counts via TablePanel's
    -- draw, hole cards flip on opp_revealed. No per-event flight here.
}

return PokerEventAnims
