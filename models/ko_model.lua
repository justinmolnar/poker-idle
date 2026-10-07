-- models/ko_model.lua
--
-- A tournament's chip rules, and the readout they add up to.
--
-- KoModel.settleHand is THE rule for who pays whom in a tournament hand:
-- models/Table:deal calls it for every hand a KO table plays, and
-- KoModel.run plays the same rule a couple of thousand times for the
-- readout (finish odds, length). One function, so the number on the felt
-- is what the table does.
--
--   * every seat sits down with `depth` big blinds (gtype.starting_stack_bb);
--   * the player is in `involve` of the hands (gtype.player_in_hand); the
--     rest two live opponents play at a loss-sized pot (settleFieldHand);
--   * wc / wd / ld arrive squeezed toward a coinflip (OutcomeMath.koSqueeze);
--   * each hand the player wins with `wc`, at a tier drawn from wd / ld, a
--     magnitude from the game type's pot bands, times that tier's
--     multiplier, in the tournament's big blind (average live stack /
--     depth, doubled every `level_hands` hands: the blind clock);
--   * settleHand moves the chips: the pot is multiway. A win (capped by the
--     seats rule, seats x the player's stack) is paid half each by two live
--     opponents, then by the biggest stacks. A loss (capped by the player's
--     stack) goes to one live opponent, and a second opponent in the pot
--     pays that winner as much again (the field busts each other too);
--   * seats at zero are out; the player's finish is the seats still in
--     (plus those out in the same hand holding more) plus one.
--
-- The readout is deterministic: a fixed-seed generator, so the same inputs
-- always read the same and two readouts compared side by side (an
-- upgrade's now and next) differ by the change, not by noise. Memoised.

local KoModel = {}

local RUNS      = 2000
local MAX_HANDS = 400
local TIERS     = { "small", "medium", "large", "stack" }

-- One hand's chips. stacks[seat] and alive[seat] (true = still in) for
-- seats 1..n; `amount` is what the hand is worth (the outcome's chips,
-- multipliers in); rnd() returns [0, 1). Returns the per-seat deltas and
-- the seats in the pot. Does not touch `stacks`.
function KoModel.settleHand(stacks, alive, player, n, won, amount, seats_rule, rnd)
    local deltas, involved = {}, { [player] = true }
    for s = 1, n do deltas[s] = 0 end
    local opps = {}
    for s = 1, n do
        if s ~= player and alive[s] then opps[#opps + 1] = s end
    end
    if #opps == 0 then return deltas, involved end
    local fi = 1 + math.floor(rnd() * #opps)
    local first = opps[fi]
    local second
    if #opps > 1 then
        local si = 1 + math.floor(rnd() * (#opps - 1))
        if si >= fi then si = si + 1 end
        second = opps[si]
    end
    involved[first] = true
    if second then involved[second] = true end
    local mine = stacks[player] or 0
    local function left_of(s) return (stacks[s] or 0) + deltas[s] end

    if won then
        local amt  = math.min(amount, (seats_rule or 1) * mine)
        local owed = amt
        for _, s in ipairs(second and { first, second } or { first }) do
            local take = math.min(second and amt / 2 or amt, left_of(s))
            deltas[s] = deltas[s] - take
            owed = owed - take
        end
        if owed > 1e-9 then
            table.sort(opps, function(a, b) return left_of(a) > left_of(b) end)
            for _, s in ipairs(opps) do
                if owed <= 1e-9 then break end
                local take = math.min(owed, left_of(s))
                if take > 0 then
                    deltas[s] = deltas[s] - take
                    owed = owed - take
                    involved[s] = true
                end
            end
        end
        deltas[player] = amt - math.max(0, owed)
    else
        local amt = math.min(amount, mine)
        deltas[player] = -amt
        deltas[first]  = deltas[first] + amt
        if second then
            local take = math.min(amt, left_of(second))
            deltas[second] = deltas[second] - take
            deltas[first]  = deltas[first] + take
        end
    end
    return deltas, involved
end

-- A hand the player sits out: two live opponents play it, one wins
-- `amount` off the other (capped by what the loser holds). Same return
-- shape as settleHand; the player is not in the pot.
function KoModel.settleFieldHand(stacks, alive, player, n, amount, rnd)
    local deltas, involved = {}, {}
    for s = 1, n do deltas[s] = 0 end
    local opps = {}
    for s = 1, n do
        if s ~= player and alive[s] then opps[#opps + 1] = s end
    end
    if #opps < 2 then return deltas, involved end
    local wi = 1 + math.floor(rnd() * #opps)
    local li = 1 + math.floor(rnd() * (#opps - 1))
    if li >= wi then li = li + 1 end
    local w, l = opps[wi], opps[li]
    local take = math.min(amount, stacks[l] or 0)
    deltas[l], deltas[w] = -take, take
    involved[w], involved[l] = true, true
    return deltas, involved
end

-- Park-Miller: exact in doubles, the same on LuaJIT and PUC Lua.
local seed
local function rnd()
    seed = (seed * 16807) % 2147483647
    return seed / 2147483647
end

local function pick(dist)
    local r, acc = rnd(), 0
    for _, t in ipairs(TIERS) do
        acc = acc + (dist[t] or 0)
        if r < acc then return t end
    end
    return "small"
end

local memo, memo_n = {}, 0

-- in = { wc, wd, ld, win_mult = {tier = m}, loss_mult = {tier = m},
--        bands = { win = {tier = {lo, hi}}, loss = {...} },
--        n_seats, depth, seats_rule, level_hands, key }
-- -> { pos_probs = {1..n}, exp_hands }
-- Inputs are rounded to half a percent before they key the memo and the
-- run, so a readout whose odds tick by a hair (a heater landing, an item's
-- count moving) reuses its result instead of playing the field again.
local function q(v) return math.floor((v or 0) * 200 + 0.5) / 200 end

function KoModel.run(inp)
    local wd, ld, wm, lm = {}, {}, {}, {}
    for _, t in ipairs(TIERS) do
        wd[t], ld[t] = q(inp.wd[t]), q(inp.ld[t])
        wm[t], lm[t] = q(inp.win_mult[t] or 1), q(inp.loss_mult[t] or 1)
    end
    inp = { wc = q(inp.wc), wd = wd, ld = ld, win_mult = wm, loss_mult = lm,
            bands = inp.bands, n_seats = inp.n_seats, depth = inp.depth,
            seats_rule = inp.seats_rule, level_hands = inp.level_hands, key = inp.key,
            involve = inp.involve }
    local parts = { ("%.3f"):format(inp.wc), inp.n_seats, inp.depth, inp.seats_rule, inp.level_hands,
                    inp.involve or 1 }
    for _, t in ipairs(TIERS) do
        parts[#parts + 1] = ("%.3f/%.3f/%.3f/%.3f"):format(wd[t], ld[t], wm[t], lm[t])
    end
    parts[#parts + 1] = inp.key or ""
    local key = table.concat(parts, "|")
    local hit = memo[key]
    if hit then return hit end

    seed = 12345
    local n, depth = inp.n_seats, inp.depth
    local finishes, hands_total = {}, 0
    for f = 1, n do finishes[f] = 0 end
    local stacks, alive, pre = {}, {}, {}
    for _ = 1, RUNS do
        for s = 1, n do stacks[s] = depth; alive[s] = true end
        local n_alive, hands, finish = n, 0, nil
        while not finish and hands < MAX_HANDS do
            hands = hands + 1
            local total = 0
            for s = 1, n do if alive[s] then total = total + stacks[s] end end
            local bb = math.max(1, total / n_alive / depth)
                     * 2 ^ ((hands - 1) / inp.level_hands)
            for s = 1, n do pre[s] = stacks[s] end
            local deltas
            if n_alive > 2 and rnd() >= (inp.involve or 1) then
                -- The player sits this one out: the field plays it, at the
                -- size of a hand the player loses (their dist, no mults).
                local tier = pick(inp.ld)
                local band = inp.bands.loss[tier]
                local mag  = band and (band.lo + (band.hi - band.lo) * rnd()) or 1
                deltas = KoModel.settleFieldHand(stacks, alive, 1, n, mag * bb, rnd)
            else
                local won  = rnd() < inp.wc
                local tier = pick(won and inp.wd or inp.ld)
                local band = (won and inp.bands.win or inp.bands.loss)[tier]
                local mag  = band and (band.lo + (band.hi - band.lo) * rnd()) or 1
                local mult = (won and inp.win_mult or inp.loss_mult)[tier] or 1
                deltas = KoModel.settleHand(stacks, alive, 1, n, won,
                                            mag * bb * mult, inp.seats_rule, rnd)
            end
            for s = 1, n do stacks[s] = stacks[s] + deltas[s] end
            local out_now = {}
            for s = 2, n do
                if alive[s] and stacks[s] <= 1e-9 then
                    alive[s] = false
                    n_alive = n_alive - 1
                    out_now[#out_now + 1] = s
                end
            end
            if stacks[1] <= 1e-9 then
                local ahead = 0
                for _, s in ipairs(out_now) do if pre[s] > pre[1] then ahead = ahead + 1 end end
                finish = (n_alive - 1) + ahead + 1
            elseif n_alive == 1 then
                finish = 1
            end
        end
        finish = finish or n_alive
        finishes[finish] = finishes[finish] + 1
        hands_total = hands_total + hands
    end
    local out = { pos_probs = {}, exp_hands = hands_total / RUNS }
    for f = 1, n do out.pos_probs[f] = finishes[f] / RUNS end

    memo_n = memo_n + 1
    if memo_n > 512 then memo, memo_n = {}, 0 end
    memo[key] = out
    return out
end

return KoModel
