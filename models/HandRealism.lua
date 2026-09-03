-- models/HandRealism.lua
--
-- Builds the cards a table hand SHOWS, given the outcome it has already
-- been dealt. Money is decided first — models/Table rolls (won, tier)
-- before a single card exists — so this module's whole job is to make the
-- theater agree with the money: a stack that went across the table should
-- look like a hand worth stacking off with.
--
-- Three shapes of hand come through here:
--
--   * Showdown tiers (medium and up). The opponent's cards will be turned
--     over, so the MATCHUP has to read right. We sample a preflop matchup
--     whose equity fits the outcome — a big pot you lost was a hand you
--     were winning (a beat), a jackpot you won was a cooler that paid —
--     then deal boards until one lands on the scripted winner.
--
--   * Small tier. Never reaches showdown (data/hand_structure.lua), so the
--     opponent's cards are never seen and matchup work would be wasted.
--     But the player's hole cards are face-up from the deal, every hand,
--     so those still get a light playability lean on wins.
--
--   * The interrupt re-deal. A heater or tilt flips a live hand mid-script
--     and only the opponent's two cards may change (the player's are
--     already face-up, and rewriting them would read as a cheat).
--
-- Every path is allowed to fail and fall back to `legacyConstructHand`,
-- the original blind rejection sampler, which always produces the right
-- winner even when it produces a silly one. Callers get a `natural` flag
-- exactly as before: false means "we gave up and took what we could get".
--
-- Policy numbers live in data/showdown_realism.lua and are threaded in,
-- never read from a global — the sim swaps candidates in the same way
-- models/HandScript takes data/hand_structure.

local Deck            = require("models.Deck")
local HandEval        = require("models.HandEval")
local HandClass       = require("models.HandClass")
local PreflopEquity   = require("models.PreflopEquity")
local ShowdownRealism = require("data.showdown_realism")

local HandRealism = {}

local CONSTRUCTION_CAP = 200      -- matches the original constructHand cap

-- ─── Policy resolution ─────────────────────────────────────────────────
-- `default` merged with an optional per-gtype override, per key, the same
-- shape data/hand_structure.lua uses. Memoized on (data table, gtype) so
-- a deal never builds a table.

local _policy_cache = setmetatable({}, { __mode = "k" })

local function policyFor(data, gtype_id)
    data = data or ShowdownRealism
    local per_data = _policy_cache[data]
    if not per_data then per_data = {}; _policy_cache[data] = per_data end
    local key = gtype_id or "\0default"
    local hit = per_data[key]
    if hit then return hit end

    local base = data.default or {}
    local out  = {}
    for k, v in pairs(base) do out[k] = v end
    local ov = gtype_id and data.by_gtype and data.by_gtype[gtype_id]
    if ov then for k, v in pairs(ov) do out[k] = v end end
    per_data[key] = out
    return out
end
HandRealism.policyFor = policyFor

-- ─── Shared helpers ────────────────────────────────────────────────────

local function markSeen(seen, cards)
    for _, c in ipairs(cards) do seen[c.suit .. c.rank] = true end
end

-- Best 7-card rank for hole + 5 board, using a scratch table so the
-- board-rejection loop doesn't allocate per attempt.
local function rank7(scratch, hole, board)
    scratch[1], scratch[2] = hole[1], hole[2]
    scratch[3], scratch[4], scratch[5] = board[1], board[2], board[3]
    scratch[6], scratch[7] = board[4], board[5]
    return HandEval.bestFiveOfN(scratch)
end

-- Partial Fisher-Yates over `pool`: shuffles `count` cards into the front
-- positions and leaves them there. HandClass.remainingCards hands back a
-- deck in a fixed suit-then-rank order, so every draw from it has to go
-- through here — taking cards off either end deals the same two cards
-- every hand.
local function drawInto(pool, n_pool, count)
    for s = 1, count do
        local pick = love.math.random(s, n_pool)
        pool[s], pool[pick] = pool[pick], pool[s]
    end
end

-- The five board cards, drawn fresh out of `pool` each call.
local function dealBoard(pool, n_pool, board)
    drawInto(pool, n_pool, 5)
    board[1], board[2], board[3] = pool[1], pool[2], pool[3]
    board[4], board[5] = pool[4], pool[5]
    return board
end

-- Does the finished showdown read right? `floors` may name a minimum
-- category for the winner and/or the loser; `distinct` additionally
-- rejects showdowns whose two hand names come out identical, since those
-- names are the only explanation of the result the felt ever gives.
local function passesFloors(floors, distinct, p_rank, o_rank, won)
    local w_rank = won and p_rank or o_rank
    local l_rank = won and o_rank or p_rank
    if floors then
        if floors.winner and w_rank[1] < floors.winner then return false end
        if floors.loser  and l_rank[1] < floors.loser  then return false end
    end
    if distinct
       and HandEval.describe(w_rank) == HandEval.describe(l_rank) then
        return false
    end
    return true
end

-- ─── The original sampler, kept as the floor under everything ──────────
-- Deal nine cards blind, keep the deal if the right side happens to win.
-- Produces the correct winner and nothing else — it is what we fall back
-- to when a policy cannot be served, and what the small-tier path uses
-- once its own weighting has had its say.

function HandRealism.legacyConstructHand(want_win, cap)
    local p_hole, o_hole, board
    for _ = 1, (cap or CONSTRUCTION_CAP) do
        local deck = Deck:new()
        p_hole = { deck:draw(), deck:draw() }
        o_hole = { deck:draw(), deck:draw() }
        board  = { deck:draw(), deck:draw(), deck:draw(), deck:draw(), deck:draw() }

        local p_cards, o_cards = {}, {}
        for _, c in ipairs(p_hole) do table.insert(p_cards, c) end
        for _, c in ipairs(board)  do table.insert(p_cards, c) end
        for _, c in ipairs(o_hole) do table.insert(o_cards, c) end
        for _, c in ipairs(board)  do table.insert(o_cards, c) end

        local p_rank = HandEval.bestFiveOfN(p_cards)
        local o_rank = HandEval.bestFiveOfN(o_cards)
        local p_wins = HandEval.compare(p_rank, o_rank) > 0
        if p_wins == want_win then
            return p_hole, o_hole, board, true
        end
    end
    return p_hole, o_hole, board, false
end

-- ─── Small tier: the player's hole only ────────────────────────────────
-- Nothing of the opponent is ever shown, so the only card that has to
-- look plausible is the one the player is staring at. Wins lean toward
-- hands worth playing; losses stay a random deal, because folding a bad
-- hand out of a small pot is exactly what small pots are.

function HandRealism.constructWeightedNatural(won, pol)
    local exp = won and (pol.foldout_win_exp or 0) or 0
    if exp == 0 then
        return HandRealism.legacyConstructHand(won)
    end

    local scratch_p, scratch_o = {}, {}
    local board = {}
    for _ = 1, 40 do
        local seen   = {}
        local p_class = PreflopEquity.sampleClass(exp)
        local p_hole  = HandClass.realize(p_class, seen)
        if p_hole then
            -- Seven cards off the same pool: two for the opponent, dealt
            -- blind (nothing of theirs is ever shown at this tier), then
            -- the board.
            local pool   = HandClass.remainingCards(seen)   -- 50 cards
            local n_pool = #pool
            drawInto(pool, n_pool, 7)
            local o_hole = { pool[1], pool[2] }
            board[1], board[2], board[3] = pool[3], pool[4], pool[5]
            board[4], board[5] = pool[6], pool[7]

            local p_rank = rank7(scratch_p, p_hole, board)
            local o_rank = rank7(scratch_o, o_hole, board)
            if (HandEval.compare(p_rank, o_rank) > 0) == won then
                return p_hole, o_hole,
                       { board[1], board[2], board[3], board[4], board[5] },
                       true
            end
        end
    end
    return HandRealism.legacyConstructHand(won)
end

-- ─── Showdown tiers: the matchup carries the story ─────────────────────

-- Pick one of the tier's weighted band shapes.
local function pickBand(bands)
    local total = 0
    for _, b in ipairs(bands) do total = total + (b.w or 1) end
    if total <= 0 then return bands[1] end
    local r, acc = love.math.random() * total, 0
    for _, b in ipairs(bands) do
        acc = acc + (b.w or 1)
        if r <= acc then return b end
    end
    return bands[#bands]
end

-- The main entry. `deps` = { policy, gtype_id } — both optional, both
-- threaded from models/Table.
function HandRealism.constructShowdownHand(won, tier, deps)
    deps = deps or {}
    local pol   = policyFor(deps.policy, deps.gtype_id)
    local bands = pol.bands
        and pol.bands[won and "win" or "loss"]
        and pol.bands[won and "win" or "loss"][tier]

    -- No band for this tier (small): nothing of the opponent is shown.
    if not bands or #bands == 0 then
        return HandRealism.constructWeightedNatural(won, pol)
    end

    local floors     = pol.cat_floors and pol.cat_floors[tier]
    local distinct   = pol.distinct_labels
    local n_matchups = pol.matchup_attempts or 16
    local n_boards   = pol.board_attempts   or 12
    local n_floored  = pol.floor_attempts   or 10
    local exp        = pol.showdown_exp     or 4

    local scratch_p, scratch_o = {}, {}
    local board = {}

    local n_unservable = 0
    for m = 1, n_matchups do
        local band = pickBand(bands)
        local p_class, o_class = PreflopEquity.sampleMatchup(
            band.lo, band.hi, { exp = exp, opp_min_eqvr = band.opp_min_eqvr })

        if not p_class then
            -- The sampler exhausted its own attempts, which means this
            -- band asks for a matchup that barely exists. Retrying it
            -- fifteen more times just burns the deal; take the fallback.
            n_unservable = n_unservable + 1
            if n_unservable >= 2 then break end
        else
            local seen   = {}
            local p_hole = HandClass.realize(p_class, seen)
            local o_hole = p_hole and HandClass.realize(o_class, seen)
            if o_hole then
                local pool   = HandClass.remainingCards(seen)   -- 48 cards
                local n_pool = #pool
                local enforce_floors = (m <= n_floored)

                for _ = 1, n_boards do
                    dealBoard(pool, n_pool, board)
                    local p_rank = rank7(scratch_p, p_hole, board)
                    local o_rank = rank7(scratch_o, o_hole, board)
                    local cmp = HandEval.compare(p_rank, o_rank)
                    -- Ties are rejected outright here: a split pot that
                    -- pays a full stack reads as a bug, not a cooler.
                    if cmp ~= 0 and (cmp > 0) == won then
                        if not enforce_floors
                           or passesFloors(floors, distinct,
                                           p_rank, o_rank, won) then
                            return p_hole, o_hole,
                                   { board[1], board[2], board[3],
                                     board[4], board[5] },
                                   true
                        end
                    end
                end
            end
        end
    end

    return HandRealism.legacyConstructHand(won, 60)
end

-- ─── The interrupt re-deal ─────────────────────────────────────────────
-- A heater or tilt has flipped a live hand's side. The player's cards and
-- the board are already on the felt — possibly already face-up — so only
-- the opponent's two cards may move.
--
-- Among the combinations that produce the required winner, the pick is
-- weighted by playability — an opponent who has just been handed the pot
-- should be holding something worth having played, while one who is about
-- to lose it can still turn over junk, because people do.
--
-- Two hands are drawn at random and kept with probability proportional to
-- that weight, which samples the weighted distribution exactly without
-- ever building the list of 990 combinations. That matters because a
-- proc can put a status on many tables in the same frame, and enumerating
-- for each of them turned a heater into a visible freeze.
--
-- Exhaustive enumeration is still there as the floor, for the case where
-- the required result is rare or impossible — and impossibility has a
-- one-comparison test that catches nearly all of it: if the player's best
-- five ARE the board, every opponent plays that same board too, so the
-- player can never get strictly ahead of anyone.

local REDEAL_TRIES = 200

function HandRealism.redealOpponent(p_hole, board, want_win, deps)
    deps = deps or {}
    local pol = policyFor(deps.policy, deps.gtype_id)
    local exp = want_win and 1 or (pol.showdown_exp or 4)

    local seen = {}
    markSeen(seen, p_hole or {})
    markSeen(seen, board or {})
    local avail   = HandClass.remainingCards(seen)     -- 45 cards
    local n_avail = #avail
    if n_avail < 2 then return nil, false end

    local scratch_p, scratch_o = {}, {}
    local p_rank = rank7(scratch_p, p_hole, board)

    -- Score one candidate pair against the board.
    local function oppRank(ca, cb)
        scratch_o[1], scratch_o[2] = ca, cb
        scratch_o[3], scratch_o[4], scratch_o[5] = board[1], board[2], board[3]
        scratch_o[6], scratch_o[7] = board[4], board[5]
        return HandEval.bestFiveOfN(scratch_o)
    end
    local function weightOf(ca, cb)
        return PreflopEquity.eqVsRandom(HandClass.classIndex(ca, cb)) ^ exp
    end

    -- Does the player merely play the board? Then nobody can be behind
    -- them, and a win is unreachable — skip straight to the chop search.
    local plays_board = want_win
        and HandEval.compare(p_rank, HandEval.rank(board)) == 0

    if not plays_board then
        local w_max = PreflopEquity.maxEqVsRandom() ^ exp
        local found_a, found_b, found_w, n_found = {}, {}, {}, 0
        for _ = 1, REDEAL_TRIES do
            local i = love.math.random(n_avail)
            local j = love.math.random(n_avail - 1)
            if j >= i then j = j + 1 end
            local ca, cb = avail[i], avail[j]
            if (HandEval.compare(p_rank, oppRank(ca, cb)) > 0) == want_win then
                local w = weightOf(ca, cb)
                if love.math.random() * w_max <= w then
                    return { ca, cb }, true
                end
                n_found = n_found + 1
                found_a[n_found], found_b[n_found], found_w[n_found] = ca, cb, w
            end
        end
        -- Nothing cleared the weight test, but valid hands did turn up:
        -- take the best-weighted of what was seen rather than paying for
        -- the full enumeration.
        if n_found > 0 then
            local total = 0
            for k = 1, n_found do total = total + found_w[k] end
            local r, acc = love.math.random() * total, 0
            for k = 1, n_found do
                acc = acc + found_w[k]
                if r <= acc then return { found_a[k], found_b[k] }, true end
            end
            return { found_a[n_found], found_b[n_found] }, true
        end
    else
        -- The player is playing the board, so the best available result
        -- is a chop — and against a board that plays itself most hands
        -- chop, so one turns up in a few draws.
        for _ = 1, REDEAL_TRIES do
            local i = love.math.random(n_avail)
            local j = love.math.random(n_avail - 1)
            if j >= i then j = j + 1 end
            local ca, cb = avail[i], avail[j]
            if HandEval.compare(p_rank, oppRank(ca, cb)) == 0 then
                return { ca, cb }, false
            end
        end
    end

    -- Nothing found by sampling. Enumerate: either the required result is
    -- rare enough that random draws missed it, or it cannot happen at all
    -- and we need the chop.
    local pairs_a, pairs_b, cum = {}, {}, {}
    local n_valid, total = 0, 0
    local ties_a, ties_b, n_ties = {}, {}, 0
    for a = 1, n_avail - 1 do
        local ca = avail[a]
        for b = a + 1, n_avail do
            local cb = avail[b]
            local cmp = HandEval.compare(p_rank, oppRank(ca, cb))
            -- Legacy semantics exactly: a tie is "the player does not win".
            if (cmp > 0) == want_win then
                local w = weightOf(ca, cb)
                n_valid = n_valid + 1
                pairs_a[n_valid], pairs_b[n_valid] = ca, cb
                total = total + w
                cum[n_valid] = total
            elseif cmp == 0 then
                n_ties = n_ties + 1
                ties_a[n_ties], ties_b[n_ties] = ca, cb
            end
        end
    end

    if n_valid == 0 or total <= 0 then
        -- A board that plays itself can make one side impossible: a
        -- broadway straight lying face-up leaves nothing the player can
        -- beat, because every opponent plays the same board. Hand back a
        -- chop if one exists — a split reads far closer to the intended
        -- swing than the opposite result does — and only otherwise fall
        -- back to two arbitrary cards. Either way `natural` is false, so
        -- the caller knows the cards and the money disagree.
        if n_ties > 0 then
            local k = love.math.random(n_ties)
            return { ties_a[k], ties_b[k] }, false
        end
        local i = love.math.random(n_avail)
        local j = love.math.random(n_avail - 1)
        if j >= i then j = j + 1 end
        return { avail[i], avail[j] }, false
    end

    local r = love.math.random() * total
    local lo, hi = 1, n_valid
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if cum[mid] < r then lo = mid + 1 else hi = mid end
    end
    return { pairs_a[lo], pairs_b[lo] }, true
end

return HandRealism
