-- models/ko_model.lua
--
-- A tournament's chip rules, and the readout they add up to.
--
-- Every tournament hand is two live seats, drawn at random from everyone
-- still in, playing heads-up for effective stacks (nobody wins more off a
-- seat than they risked against it). The player is just one of the seats:
-- when they are drawn it is their hand (their odds, sizes and multipliers
-- decide it); when they are not, the other two play it at even odds. So a
-- player with no edge finishes every place about equally often, and only
-- their edge moves that. models/Table:deal plays these rules every hand;
-- KoModel.run plays them a couple of thousand times for the readout
-- (finish odds, length). One set of functions, so the number on the felt
-- is what the table does.
--
--   * every seat sits down with `depth` big blinds (gtype.starting_stack_bb);
--   * pickPair draws the hand's two seats (the player always, when a punch
--     is owed to them);
--   * the player's hand: wins with `wc`, a tier from wd / ld, a magnitude
--     from the pot bands, times that tier's multiplier, in the
--     tournament's big blind (average live stack / depth, doubled every
--     `level_hands` hands);
--   * the field's hand: a fair flip at the size of a hand from ld, times
--     `field_mult` (gtype.field_pot_mult: the field gambles, the player
--     grinds, so the finishes peak in the middle);
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

-- The hand's two seats, drawn from the live ones. `force` (a seat) is
-- always one of them. Returns a, b (a == force when given).
function KoModel.pickPair(alive, n, rnd, force)
    local live = {}
    for s = 1, n do if alive[s] and s ~= force then live[#live + 1] = s end end
    if force then
        if #live == 0 then return force, nil end
        return force, live[1 + math.floor(rnd() * #live)]
    end
    if #live < 2 then return live[1], nil end
    local ai = 1 + math.floor(rnd() * #live)
    local bi = 1 + math.floor(rnd() * (#live - 1))
    if bi >= ai then bi = bi + 1 end
    return live[ai], live[bi]
end

-- One heads-up hand's chips: `winner` takes `amount` off `loser`, capped
-- by both stacks (effective stacks). Returns per-seat deltas (1..n) and
-- the two seats in the pot. Does not touch `stacks`.
function KoModel.settle(stacks, n, winner, loser, amount)
    local deltas = {}
    for s = 1, n do deltas[s] = 0 end
    local take = math.min(amount, stacks[winner] or 0, stacks[loser] or 0)
    deltas[loser], deltas[winner] = -take, take
    return deltas, { [winner] = true, [loser] = true }
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

-- Inputs are rounded to half a percent before they key the memo and the
-- run, so a readout whose odds tick by a hair (a heater landing, an item's
-- count moving) reuses its result instead of playing the field again.
local function q(v) return math.floor((v or 0) * 200 + 0.5) / 200 end

-- in = { wc, wd, ld, win_mult = {tier = m}, loss_mult = {tier = m},
--        bands = { win = {tier = {lo, hi}}, loss = {...} },
--        n_seats, depth, level_hands, field_mult, key }
-- -> { pos_probs = {1..n}, exp_hands }
function KoModel.run(inp)
    local wd, ld, wm, lm = {}, {}, {}, {}
    for _, t in ipairs(TIERS) do
        wd[t], ld[t] = q(inp.wd[t]), q(inp.ld[t])
        wm[t], lm[t] = q(inp.win_mult[t] or 1), q(inp.loss_mult[t] or 1)
    end
    local wc = q(inp.wc)
    local parts = { ("%.3f"):format(wc), inp.n_seats, inp.depth, inp.level_hands, inp.field_mult or 1 }
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
            local a, b = KoModel.pickPair(alive, n, rnd)
            local deltas
            if a == 1 or b == 1 then
                local opp  = (a == 1) and b or a
                local won  = rnd() < wc
                local tier = pick(won and wd or ld)
                local band = (won and inp.bands.win or inp.bands.loss)[tier]
                local mag  = band and (band.lo + (band.hi - band.lo) * rnd()) or 1
                local mult = (won and wm or lm)[tier] or 1
                deltas = KoModel.settle(stacks, n, won and 1 or opp, won and opp or 1, mag * bb * mult)
            else
                local tier = pick(ld)
                local band = inp.bands.loss[tier]
                local mag  = band and (band.lo + (band.hi - band.lo) * rnd()) or 1
                if rnd() < 0.5 then a, b = b, a end
                deltas = KoModel.settle(stacks, n, a, b, mag * bb * (inp.field_mult or 1))
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
