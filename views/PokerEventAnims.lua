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

local Theme       = require("views.Theme")
local Tumble      = require("services.Tumble")
local AnimsData   = require("data.animations")

-- Card render size for the muck-fold animation. Matches the typical
-- opponent hole-card draw size in TablePanel; tunable.
local MUCK_CARD_W = 24
local MUCK_CARD_H = 32

-- ── Tournament chips ────────────────────────────────────────────────────
-- Tournament chips are NOT money, so they must not wear money's clothes:
-- no dollar denominations, no value labels, one flat off-palette color.
-- One chip per big blind, exactly — the pot pile syncs to the same count
-- (TablePanel.drawPotLabel), so the flights and the reconciler agree to
-- the chip. Uncapped like every pile transfer: an all-in IS its whole
-- stack in the air, and FlightSystem's MAX_IN_FLIGHT backstop deposits
-- whatever it declines to fly.
local TOURNEY_CHIP_DENOM = 1    -- near-white base takes the tint cleanly

local function tournamentChips(tbl, amount)
    local stake = Lookups.findById(Stakes, tbl.stake_id)
    local bb = (stake and stake.bb) or 0
    if bb <= 0 or not amount or amount <= 0 then return nil end
    local n = math.max(1, math.floor(amount / bb + 0.5))
    local chips = {}
    for i = 1, n do chips[i] = TOURNEY_CHIP_DENOM end
    return chips
end

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
    -- Chip-stack tournament: tournament chips (one per bb, violet, no
    -- dollar labels), reserved into the pot pile like any bet — the pile
    -- is placed with the same colors (TablePanel.drawPotLabel), so what
    -- lands is what sits there.
    if tbl.seat_stacks then
        ChipFlight.transfer(seat_pos, pot_pos, {
            chips     = tournamentChips(tbl, amount),
            labels    = false,
            chip_tint = Theme.data.violet,
            dest_key  = pot_key,
            budget    = timeToNextEvent(tbl),
        })
        return
    end
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

        -- Chip-stack tournament: the felt pot flies to whoever won it, as
        -- tournament chips. ev.amount ONLY — outcome_delta fabrication is
        -- the cash path's payout trick, and an KO r.delta is
        -- informational (GrindController skips it). No detonation either:
        -- a scheduled bust hand is tier "stack" for the planner, not a
        -- money stack — the KO moment is the seat's, not the pot's.
        if tbl.seat_stacks then
            ChipFlight.transfer(pot_pos, target_pos, {
                chips         = tournamentChips(tbl, ev.amount),
                labels        = false,
                chip_tint     = Theme.data.violet,
                arrival_sound = is_player and "chip_land_you" or nil,
            })
            return
        end

        -- Stack win: the pot doesn't get carried over, it DETONATES —
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

-- ─── The deal ───────────────────────────────────────────────────────────
-- The felt's deal: the previous hand slides off, then the dealer button
-- seat throws backs to every seat in turn, two each, opponents first, the
-- player last; the player's two turn face-up on landing. Board cards fly
-- the same way on each street and turn on landing. views/TablePanel keeps a
-- card's slot empty until its flight lands and draws the turn (tbl._deal_fx,
-- written here), so a card is never in two places.
--
-- Slots are read from the card anchors TablePanel registers per draw
-- ("cards_<seat>_<n>" and "board_<i>"), so the flights land exactly where
-- the cards will draw. Everything is budgeted against timeToNextEvent, as
-- the chip flights are, so a zoom table deals fast and a 6-max deals slow.
local GD = AnimsData.grind_deal or {}

local function visualKey(tbl, seat)
    local ps = tbl.playback_state
    if not (ps and ps.player_seat and seat) then return nil end
    if seat == ps.player_seat then return "you" end
    return "opp_" .. ((seat < ps.player_seat) and seat or (seat - 1))
end

local function scriptSeat(tbl, opp_idx)
    local ps = tbl.playback_state
    if not (ps and ps.player_seat) then return nil end
    return (opp_idx < ps.player_seat) and opp_idx or (opp_idx + 1)
end

local function cardRect(tbl, key, n)
    return Anchors.get(Table.anchorKey(tbl, "cards_" .. key .. "_" .. n))
end

local function backSprite(game)
    local back
    if Decks.systemUnlocked(game.state) then back = Decks.activeSprite(game.state) end
    return back or (Constants.GAUNTLET and Constants.GAUNTLET.CARD_BACK_SPRITE)
end

-- Where the cards come from: the dealer button's seat, else the centre.
local function dealOrigin(tbl)
    local ps  = tbl.playback_state
    local btn = ps and ps.button_visual_seat
    local key
    if btn and btn == (#tbl.opponents + 1) then key = "you"
    elseif btn then key = "opp_" .. btn end
    local a = key and Anchors.get(Table.anchorKey(tbl, key))
    if not a then a = Anchors.get(Table.anchorKey(tbl, "center")) end
    return a and { a[1], a[2] } or nil
end

-- Card flight and stagger for n cards, compressed to fit before the next
-- scripted event, never shorter than the floor.
local function dealBudget(tbl, n)
    local card, stag = GD.card or 0.30, GD.stagger or 0.06
    local total = card + stag * math.max(0, n - 1)
    local left  = timeToNextEvent(tbl)
    if left and left < total then
        local k = math.max(left / total, (GD.floor or 0.08) / card)
        card, stag = card * k, stag * k
    end
    return card, stag
end

local function flyBack(sl, back, from, rect, delay, dur)
    local w, h = rect[3] or MUCK_CARD_W, rect[4] or MUCK_CARD_H
    local render = Tumble.wrap(function(x, y)
        CardSprites.back(sl, back, x - w / 2, y - h / 2, w, h, 1)
    end, Tumble.PRESETS.toss)
    FlightSystem.emit(from, { rect[1] + w / 2, rect[2] + h / 2 }, render, {
        delay = delay, duration = dur, arc_height = GD.arc or 40,
    })
end

-- The previous hand leaves: every card that was on the felt slides down
-- and fades, faces where they were showing, backs elsewhere.
local function muckResidue(tbl, swept, sl, back)
    local dur = GD.muck or 0.25
    local function slide(rect, sprite_name, is_back)
        if not rect then return end
        local w, h = rect[3] or MUCK_CARD_W, rect[4] or MUCK_CARD_H
        local from = { rect[1] + w / 2, rect[2] + h / 2 }
        local render = function(x, y, t)
            local a = 1 - (t or 0)
            if is_back then CardSprites.back(sl, back, x - w / 2, y - h / 2, w, h, a)
            else CardSprites.sprite(sl, sprite_name, x - w / 2, y - h / 2, w, h, 1, a) end
        end
        FlightSystem.emit(from, { from[1], from[2] + 60 }, render, { duration = dur, arc_height = 0 })
    end
    local ps_seat = swept.player_seat
    for i = 1, #tbl.opponents do
        local script = ps_seat and ((i < ps_seat) and i or (i + 1))
        local was_in = not swept.in_seats or not script or swept.in_seats[script]
        if was_in then
            local revealed = swept.opp_revealed and swept.opponent_idx == i and swept.opponent_hole
            for n = 1, 2 do
                local c = revealed and swept.opponent_hole[n]
                slide(cardRect(tbl, "opp_" .. i, n), c and c:spriteName(), not c)
            end
        end
    end
    for n = 1, 2 do
        local c = swept.player_hole and swept.player_hole[n]
        slide(cardRect(tbl, "you", n), c and c:spriteName(), not c)
    end
    for i = 1, (swept.community_count or 0) do
        local c = swept.community and swept.community[i]
        if c then slide(Anchors.get(Table.anchorKey(tbl, "board_" .. i)), c:spriteName(), false) end
    end
end

PokerEventAnims.deal_hole = function(_ev, tbl, game)
    local sl = game and game.sprite_loader
    local ps = tbl.playback_state
    if not (sl and ps) then return end
    local now  = love.timer.getTime()
    local fx   = tbl._deal_fx or { arrive = {}, flip = {} }
    fx.arrive, fx.flip = {}, {}
    tbl._deal_fx = fx
    local back = backSprite(game)

    local muck_d = 0
    if tbl.swept_hand then
        muckResidue(tbl, tbl.swept_hand, sl, back)
        tbl.swept_hand = nil
        muck_d = GD.muck or 0.25
    end

    -- Opponents in the hand, in ring order, then you.
    local order = {}
    for i = 1, #tbl.opponents do
        local script = scriptSeat(tbl, i)
        if script and (not ps.in_seats or ps.in_seats[script]) then
            order[#order + 1] = "opp_" .. i
        end
    end
    order[#order + 1] = "you"

    local card, stag = dealBudget(tbl, #order * 2)
    local from = dealOrigin(tbl)
    local k = 0
    for _, key in ipairs(order) do
        for n = 1, 2 do
            local rect = cardRect(tbl, key, n)
            if from and rect then flyBack(sl, back, from, rect, muck_d + k * stag, card) end
            k = k + 1
        end
        local land = muck_d + (k - 1) * stag + card
        fx.arrive[key] = now + land
        fx.flip[key]   = (key == "you")
        FlightSystem.scheduleSound("card_dealt", land)
    end
end

local function dealBoard(tbl, game, first, last)
    local sl = game and game.sprite_loader
    if not sl then return end
    local now  = love.timer.getTime()
    local fx   = tbl._deal_fx or { arrive = {}, flip = {} }
    tbl._deal_fx = fx
    local back = backSprite(game)
    local card, stag = dealBudget(tbl, last - first + 1)
    local from = dealOrigin(tbl)
    for i = first, last do
        local k    = i - first
        local rect = Anchors.get(Table.anchorKey(tbl, "board_" .. i))
        if from and rect then flyBack(sl, back, from, rect, k * stag, card) end
        fx.arrive["board_" .. i] = now + k * stag + card
        fx.flip["board_" .. i]   = true
    end
    FlightSystem.scheduleSound("card_dealt", (last - first) * stag + card)
end

PokerEventAnims.deal_flop  = function(_ev, tbl, game) dealBoard(tbl, game, 1, 3) end
PokerEventAnims.deal_turn  = function(_ev, tbl, game) dealBoard(tbl, game, 4, 4) end
PokerEventAnims.deal_river = function(_ev, tbl, game) dealBoard(tbl, game, 5, 5) end

return PokerEventAnims
