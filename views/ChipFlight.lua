-- views/ChipFlight.lua
--
-- Unified chip-flight helper. Composes (denomination breakdown, burst
-- options, pile bookkeeping) and dispatches chip records to FlightSystem.
-- Single seam for "chips fly from anchor A to anchor B" — used by both
-- the script's per-event handlers (views/PokerEventAnims) and the
-- view-side queue drain that consumes GrindController._emit*Chips
-- bursts (views/GrindView).
--
-- Entry points, in order of how much the caller already knows:
--   * transfer(source, dest, options)
--       THE ONE THAT MOVES CHIPS BETWEEN PILES. Chips leave the source
--       pile's collection and are inserted into the destination pile's,
--       slot to slot. Everything else here is decoration by comparison.
--   * fly(source, dest, amount, stake_id, options)
--       Convenience for "I have a $ amount, fly the right chips" where
--       neither end is a registered pile.
--   * flyChipsList(source, dest, chip_indices, options)
--       For paths that already broke down the amount (controller queue,
--       where the breakdown happens at queue-push time so the controller
--       isn't pulling in views/Chips).
--
-- All honor options.arrival_sound / max_per_event / chip_tint / tier.
-- Engine-side bookkeeping (capping, staggering, bezier arc) stays in
-- services/FlightSystem; pile bookkeeping stays in views/ChipPile.
--
-- A chip in flight is a RECORD, not a closure: FlightSystem.emitChip takes
-- the denomination, label, tint, scale and a tumble preset as arguments
-- and views/Chips.flightRenderer (registered here, once) draws every chip
-- in the air as one batch. The old path built two closures and seven
-- tables per chip, and a busy board launched a thousand a second.

local FlightSystem = require("services.FlightSystem")
local Tumble       = require("services.Tumble")
local ChipPile     = require("views.ChipPile")
local Chips        = require("views.Chips")
local Denoms       = require("services.DenominationBreakdown")
local ChipData     = require("data.chips")

local ChipFlight = {}

-- The renderer chip records draw through. FlightSystem never requires a
-- view; this is the one place the two are introduced.
FlightSystem.setChipRenderer(Chips.flightRenderer)

local function _palette(stake_id)
    return ChipData.stake_palettes[stake_id] or ChipData.full_palette
end

-- Payout-aware palette (see DenominationBreakdown.paletteForAmount).
-- Matters here because pot_push asks for the whole payout, and if the
-- pot pile can't supply the chips this is what composes them.
local function _paletteForAmount(stake_id, amount)
    return Denoms.paletteForAmount(ChipData, stake_id, amount)
end

-- Lay a pile out and return its chip slots in SCREEN space. One
-- implementation, in views/ChipPile — a pile and anything acting on its
-- individual chips have to agree to the pixel.
local function _layoutAt(x, y, chip_indices, align, max_w, scale)
    return ChipPile.layoutAt(x, y, chip_indices,
                             { align = align, max_w = max_w, scale = scale })
end

-- ── 4. The handover. The chip stops being a flight and becomes part of
-- the pile at the pixel it stopped on. Module-level, with the pile key and
-- the reserved chip riding the record as its two arrival values, so a
-- transfer makes no closure per chip.
local function _landInPile(_x, _y, _rec, key, chip)
    ChipPile.accept(key, chip)
end

-- ── Splitting a burst across destinations ────────────────────────────
-- `dests` is an ordered list of { key, xy [, amount] }: chips fill the
-- first destination until its amount is used up, then spill into the
-- next; the last has no limit. That's what a win bigger than the table's
-- buy-in cap actually does — the stack takes what it can hold and the
-- rest is yours — so the chips visibly split up in the air rather than
-- all landing in one pile and quietly re-emitting the excess.
local function _assignDests(taken, dests)
    local out, di, filled = {}, 1, 0
    for i, t in ipairs(taken) do
        local d = ChipData.denominations[t.d]
        local v = (d and d.value) or 0
        while di < #dests and dests[di].amount
              and (filled + v) > dests[di].amount + 1e-9 do
            di, filled = di + 1, 0
        end
        out[i] = di
        filled = filled + v
    end
    return out
end

-- Assign, then reserve each destination's share in its own pile, all
-- before a single chip flies. Returns taken-index → dest entry and
-- taken-index → reserved slot. Shared by transfer and explodeTaken so
-- the two can't drift on how a split burst is booked.
local function _reserveAcross(taken, dests)
    local dest_of, slot_of = {}, {}
    if not dests or #dests == 0 then return dest_of, slot_of end

    local assign, grouped = _assignDests(taken, dests), {}
    for i = 1, #taken do
        local d = assign[i]
        dest_of[i] = dests[d]
        local g = grouped[d]
        if not g then g = { idx = {}, den = {} }; grouped[d] = g end
        g.idx[#g.idx + 1] = i
        g.den[#g.den + 1] = taken[i].d
    end
    for d, g in pairs(grouped) do
        local reserved = dests[d].key and ChipPile.reserve(dests[d].key, g.den)
        if reserved then
            for j, ti in ipairs(g.idx) do slot_of[ti] = reserved[j] end
        end
    end
    return dest_of, slot_of
end

-- A directed burst of chip records from one point to another: the same
-- plan, sampling, stagger, landing scatter and duration jitter
-- FlightSystem.emitBurst gives closures, chip by chip. Directed flights
-- get the gentle `toss` character: a chip carried to your stack should
-- have some life in it without cartwheeling like it's been launched.
-- `tumble = false` flies it flat.
local function _burst(source, dest, chips, options)
    local count, step, stagger, duration, land_spread, dur_jitter =
        FlightSystem.burstPlan(#chips, options)
    if count == 0 then
        if options.arrival_sound then FlightSystem.scheduleSound(options.arrival_sound, 0) end
        return
    end
    local tint   = options.chip_tint
    local tumble = (options.tumble ~= false) and (options.tumble_opts or Tumble.PRESETS.toss) or false
    for i = 1, count do
        local src, delay, dur, dx, dy =
            FlightSystem.burstParams(i, step, stagger, duration, land_spread, dur_jitter,
                                     dest[1], dest[2])
        FlightSystem.emitChip(source[1], source[2], dx, dy, chips[src], true, tint, 1, 1,
                              tumble, delay, dur, nil, nil, nil, nil, options.motion)
    end
    FlightSystem.burstSound(options.arrival_sound, count, stagger, duration)
end

-- Compose a burst from a dollar amount. Picks a chip-tier (used for
-- denomination weighting) from options.tier or by inferring from the
-- amount. Bails silently if breakdown is empty.
function ChipFlight.fly(source, dest, amount, stake_id, options)
    if not source or not dest then return end
    if not amount or amount <= 0 then return end
    options = options or {}
    local palette = _paletteForAmount(stake_id, amount)
    local tier    = options.tier or Denoms.tierFromAmount(amount)
    local chips   = Denoms.breakdown(amount, ChipData.denominations,
                                     palette, ChipData.tier_chip_target, tier)
    if not chips or #chips == 0 then return end
    _burst(source, dest, chips, options)
end

-- Burst from a pre-broken-down chip-index list (the controller queue
-- pushes these). Caller has already done Denoms.breakdown.
function ChipFlight.flyChipsList(source, dest, chip_indices, options)
    if not source or not dest then return end
    if not chip_indices or #chip_indices == 0 then return end
    _burst(source, dest, chip_indices, options or {})
end

-- ── Transfer: pile to pile ───────────────────────────────────────────
-- The chips a player watches leave one pile are the chips that arrive at
-- the other. Not lookalikes streaming between two abstract points — the
-- same collection, handed over:
--
--   1. take() removes them from the source pile, which shrinks NOW, and
--      hands back the pixel each one was occupying
--   2. reserve() appends them to the destination pile as airborne, which
--      holds their slots open without drawing them
--   3. one flight per chip, its departure slot → its reserved slot
--   4. on_arrive fills that slot with the chip that just landed
--
-- Either end may be a plain point instead of a pile. With no source pile
-- the chips are composed from `amount` (or taken from `options.chips`)
-- and all depart from `source`; with no destination pile they all land
-- on `dest` and evaporate as before.
--
-- options:
--   source_key / dest_key — views/ChipPile keys. Omit either end.
--   amount                — $ to move. Required when the source has no pile.
--   chips                 — pre-broken-down denomination list, used
--                           instead of breaking down `amount`
--   stake_id / palette / tier — how to compose when there's no source pile
--   budget                — real seconds this burst has before whatever
--                           comes next; the flight time and stagger are
--                           scaled down together to fit inside it
--   labels                — false to drop denomination labels (tournament
--                           chips are not money and must not say "$1")
--   tumble / tumble_opts / chip_tint / arrival_sound / duration / stagger
--   plus FlightSystem.emit options (arc_height)
--
-- The burst is NOT capped. A capped transfer would leave the destination
-- short by every chip it declined to carry — conservation is the whole
-- point. FlightSystem's own MAX_IN_FLIGHT is the backstop, and it deposits
-- what it drops.
local TRANSFER_SPREAD = 0.35   -- seconds the whole column takes to launch
local MIN_FLIGHT      = 0.14   -- below this a flight reads as a teleport
local BUDGET_USE      = 0.85   -- land a little before the next thing happens

function ChipFlight.transfer(source, dest, options)
    options = options or {}
    local tint     = options.tint or options.chip_tint
    local duration = options.duration or 0.6

    -- ── 1. Chips leave the source.
    local taken
    if options.source_key then
        taken = ChipPile.take(options.source_key, options.amount)
    end
    if not taken then
        if not source then return end
        local chips = options.chips
        if not chips or #chips == 0 then
            local amount = options.amount
            if not amount or amount <= 0 then return end
            local palette = options.palette
                            or _paletteForAmount(options.stake_id, amount)
            local tier    = options.tier or Denoms.tierFromAmount(amount)
            chips = Denoms.breakdown(amount, ChipData.denominations, palette,
                                     ChipData.tier_chip_target, tier)
        end
        if not chips or #chips == 0 then return end
        taken = {}
        for i, d in ipairs(chips) do
            taken[i] = { d = d, x = source[1], y = source[2] }
        end
    end

    -- ── 1b. Fabrication. A payout can be worth far more than the chips
    -- that were physically on the table — late-game multipliers turn a
    -- $2.44 pot into a four-figure win — and the pot must NOT be inflated
    -- during the hand to hint at that. So the shortfall is conjured HERE,
    -- at the moment of the payout, and flies alongside the real chips.
    --
    -- It composes off the full ladder rather than the stake's four-chip
    -- window: the stake palette exists to keep a table's chips legible,
    -- and forcing a four-figure sum through a $1 top denomination is what
    -- produces a hundred identical chips.
    if options.fabricate and options.amount then
        local have = 0
        for _, t in ipairs(taken) do
            local d = ChipData.denominations[t.d]
            have = have + ((d and d.value) or 0)
        end
        local short = options.amount - have
        if short > 0 then
            local pal   = options.fab_palette or ChipData.full_palette
            local extra = Denoms.breakdown(short, ChipData.denominations, pal,
                                           ChipData.tier_chip_target,
                                           options.tier or Denoms.tierFromAmount(short))
            local sx = (source and source[1]) or taken[1] and taken[1].x
            local sy = (source and source[2]) or taken[1] and taken[1].y
            for _, d in ipairs(extra or {}) do
                taken[#taken + 1] = { d = d, x = sx, y = sy }
            end
        end
    end

    -- ── 2. Slots open at the destination(s). A payout bigger than the
    -- table's buy-in cap lands in two piles, so this takes the same
    -- ordered dests list the detonation does; dest_key is the shorthand
    -- for the ordinary single-destination case.
    local dests = options.dests
    if not dests and options.dest_key then
        dests = { { key = options.dest_key, xy = dest } }
    end
    local dest_of, slot_of = _reserveAcross(taken, dests)
    if not dests and not dest then return end

    -- Chips render at the scale of the pile they're joining — they're
    -- about to become part of it.
    local scale = options.scale
                  or (dests and dests[1] and dests[1].key and ChipPile.scale(dests[1].key))
                  or (options.source_key and ChipPile.scale(options.source_key))
                  or 1

    -- ── 3. One flight per chip.
    --
    -- The burst is (last chip's launch delay) + (one flight) long, and
    -- `budget` is how many real seconds it has before whatever comes next
    -- — the next action in the hand, usually. Overrunning it means chips
    -- still crossing the felt while the thing they represent is over, so
    -- the flight time and the stagger are scaled DOWN together to fit,
    -- keeping the burst's character instead of just truncating it.
    --
    -- Never below MIN_FLIGHT: past that it stops reading as travel and
    -- becomes the teleport this whole system exists to get rid of.
    local n       = #taken
    local spread  = math.min(0.03 * math.max(0, n - 1), TRANSFER_SPREAD)
    if options.budget then
        local avail = math.max(MIN_FLIGHT, options.budget * BUDGET_USE)
        local want  = duration + spread
        if want > avail then
            local k  = avail / want
            duration = math.max(MIN_FLIGHT, duration * k)
            spread   = spread * k
        end
    end
    local stagger = options.stagger or ((n > 1) and (spread / (n - 1)) or 0)
    local tumble  = (options.tumble ~= false) and (options.tumble_opts or Tumble.PRESETS.toss) or false
    for i = 1, n do
        local t  = taken[i]
        local s  = slot_of[i]
        local d  = dest_of[i]
        local sx = t.x or (source and source[1]) or (dest and dest[1])
        local sy = t.y or (source and source[2]) or (dest and dest[2])
        local dx = (s and s.x) or (d and d.xy and d.xy[1]) or (dest and dest[1]) or sx
        local dy = (s and s.y) or (d and d.xy and d.xy[2]) or (dest and dest[2]) or sy

        -- A pile that has never been drawn has no slots and a seat whose
        -- panel hasn't rendered yet has no anchor. Skip the flight rather
        -- than launching from nowhere — but still complete the handover,
        -- or the destination would sit permanently one chip short.
        if not (sx and sy and dx and dy) then
            if s then ChipPile.accept(d and d.key, s.chip) end
        else
            local with_label = (options.labels ~= false)
                               and ((s and s.with_label) ~= false)
            FlightSystem.emitChip(sx, sy, dx, dy, t.d, with_label, tint, scale, 1, tumble,
                                  (i - 1) * stagger, duration, options.arc_height,
                                  s and _landInPile or nil, d and d.key, s and s.chip,
                                  options.motion)
        end
    end

    if options.arrival_sound then
        FlightSystem.scheduleSound(options.arrival_sound,
            (n - 1) * stagger + duration - 0.04)
    end
end

-- Explosion tunables. Declared up here because the gather leg below
-- reads them.
local SCATTER_DURATION = 1.1    -- outward leg; this IS the beat before the turn
local GATHER_DURATION  = 0.6    -- the run home
local GATHER_JIT       = 0.18   -- ± fraction, so they don't arrive in lockstep

-- The tumbles of a gathering explosion, as two reused option tables.
-- Whole numbers of flips and spins from phase 0 on BOTH legs, which means
-- each leg begins and ends face-on and upright: the chip tumbles
-- continuously through the turn and is flat when it merges into the pile.
-- The counts are re-rolled into the table before each roll, so a burst
-- does not move as one body.
local _OUT_TUMBLE = { phase = 0, loft = { 0.45, 0.80 } }
-- Lower loft than the launch — this is a return, not a detonation — and it
-- lands at exactly 1.0, which is what lets the chip merge into the pile
-- without changing size.
local _BACK_TUMBLE = { phase = 0, spins = 1, min_squash = 0.30, loft = { 0.25, 0.45 } }

-- Second leg of a gathering explosion: the chip reaches the top of its
-- arc at (lx, ly) and turns for the pile it belongs to. Module-level; the
-- turning point arrives as the landing position and everything else about
-- the chip rides its record and one small context per chip.
--
-- It does NOT stop. A chip that parks reads as a bug — the object has to
-- stay in motion and simply change its mind about where it's going. The
-- turn is the whole gesture.
--
-- The outward leg's record carries its tumble axis and spin direction so
-- this one can continue it rather than restart it: same axis, same spin
-- direction, whole turns on both legs.
local function _gatherLeg(lx, ly, rec, ctx)
    local slot, dest = ctx.slot, ctx.dest
    local dx = (slot and slot.x) or (dest.xy and dest.xy[1])
    local dy = (slot and slot.y) or (dest.xy and dest.xy[2])
    if not (dx and dy) then
        if slot then ChipPile.accept(dest.key, slot.chip) end
        return
    end
    -- Below Full motion the outward leg landed on the spot with no record;
    -- the run home then rolls its own axis.
    _BACK_TUMBLE.axis     = rec and rec.tb_axis or nil
    _BACK_TUMBLE.spin_dir = rec and rec.tb_dir or nil
    _BACK_TUMBLE.flips    = love.math.random(1, 2)
    FlightSystem.emitChip(lx, ly, dx, dy, ctx.d, (slot and slot.with_label) ~= false,
                          ctx.tint, ctx.scale, 1, _BACK_TUMBLE,
                          0, ctx.duration * (1 + (love.math.random() * 2 - 1) * GATHER_JIT), nil,
                          slot and _landInPile or nil, dest.key, slot and slot.chip)
end

-- Scale a scatter to the box it happens inside, rather than to a handful
-- of absolute pixel constants. `options.within` is { w, h } — a table
-- panel, a modal, whatever the effect belongs to. FlightSystem's own
-- defaults throw debris up to 300px out, which reads fine over one big
-- table and absurd over a panel a quarter that wide when the player has
-- twelve of them open.
--
-- Everything keys off the SHORTER side: vertical overflow is what makes an
-- explosion look like it escaped its table. Slightly larger than the panel
-- is the intent — debris should spill over the edges, not blanket the
-- neighbours. Any spread the caller pins explicitly is left alone.
local function _scatterWithin(options)
    local within = options.within
    local m = within and math.min(within[1] or 0, within[2] or 0) or 0
    if m <= 0 then return end
    options.max_spread = options.max_spread or m * 0.60
    options.min_spread = options.min_spread or m * 0.18
    options.rise       = options.rise       or m * 0.22
    options.arc_min    = options.arc_min    or m * 0.18
    options.arc_max    = options.arc_max    or m * 0.45
end

-- ── Explode a pile in place ──────────────────────────────────────────
-- THE PILE ITSELF COMES APART. Not a burst of lookalikes spawned over
-- it: this lays the pile out with views/Chips.stackLayout — the exact
-- same call drawStack makes — and launches each chip from the position
-- it was occupying, drawn by the same atlas cells with the same label and
-- tint rules. A chip in the air is visually continuous with the chip that
-- was sitting in the stack, because it IS that chip.
--
-- The caller is responsible for no longer drawing the pile once this
-- fires (see views/TablePanel:drawPotLabel), or the pile and its own
-- debris are on screen together.
--
-- Reusable for any "flip the table" moment: the stack pot, a shove
-- win, a bankroll milestone.
--
-- Arguments mirror Chips.drawStack so a caller can hand over exactly
-- what it was drawing:
--   x, y          — same anchor drawStack was given
--   chip_indices  — same breakdown
--   options.align / .tint / .max_w — same as drawStack
--   options.scale — the caller's chip_scale, if it was drawing inside a
--                   love.graphics.scale() transform (the pot pile on
--                   small panels does). Positions and chips are both
--                   scaled to match.
--   options.labels      — false to drop denomination labels. Default on:
--                         a loose chip isn't buried, so it shows its
--                         value even though the pile only labelled its
--                         top chips.
--   options.tumble      — false to fly flat. Default on: a detonating
--                         pile should tumble.
--   options.tumble_opts — a services/Tumble preset or opts (spins, flips,
--                         axis, min_squash) to pin the motion instead of
--                         randomising it per chip.
--   options.within      — { w, h } of the box this explosion belongs
--                         inside (a table panel). Sizes the scatter to it
--                         rather than to fixed pixels, so the same call
--                         reads right at any panel size.
--   plus anything FlightSystem.scatterParams accepts (min_spread,
--   max_spread, rise, duration, arc_min, arc_max, stagger,
--   arrival_sound).
function ChipFlight.explodeStack(x, y, chip_indices, options)
    if not chip_indices or #chip_indices == 0 then return end
    options = options or {}
    local tint   = options.tint or options.chip_tint
    local s      = options.scale or 1
    local placed = _layoutAt(x, y, chip_indices, options.align, options.max_w, s)
    if #placed == 0 then return end

    -- stackLayout labels only the TOP chip of each column, because in a
    -- pile the rest are buried under it. Nothing is buried once the pile
    -- comes apart — every chip is loose in open space — so the whole burst
    -- gets its denomination back. Pass labels = false to suppress.
    local labels = (options.labels ~= false)
    -- Chips thrown off a flipped table tumble; `tumble = false` drops it.
    local tumble = (options.tumble ~= false) and (options.tumble_opts or Tumble.PRESETS.throw) or false

    _scatterWithin(options)
    local n_fly    = FlightSystem.scatterCount(#placed, options)
    local duration = options.duration or 1.1
    for i = 1, n_fly do
        local p = placed[i]
        local dx, dy, arc, delay = FlightSystem.scatterParams(p.x, p.y, options)
        FlightSystem.emitChip(p.x, p.y, dx, dy, p.idx, labels or p.with_label, tint, s, 1,
                              tumble, delay, duration, arc, nil, nil, nil, options.motion)
    end
    if n_fly == 0 then
        if options.arrival_sound then FlightSystem.scheduleSound(options.arrival_sound, 0) end
        return
    end
    FlightSystem.scatterSound(options)
end

-- The same detonation for a pile that already tracks its own chips
-- (views/ChipPile). `taken` is what ChipPile.takeAll handed back —
-- { { d, x, y }, ... } already in screen space — so the pile that comes
-- apart is literally the collection that was sitting there, chip for chip,
-- rather than a breakdown recomputed at the moment of the explosion.
--
-- ── The gather ──────────────────────────────────────────────────────
-- Give it destinations and the explosion gets a second act: the chips fly
-- out, and at the top of the arc each one turns and runs for the pile it
-- belongs to. That makes a detonation the actual payout rather than
-- decoration over one — the chips you watched come off the pot are the
-- chips that end up in your stack.
--
-- Chips do NOT all share a destination. A win past the table's buy-in cap
-- splits: the stack takes what it can hold, the rest is bankroll. So the
-- burst splits in the air, which is the honest picture of where the money
-- went and reads far better than one pile filling and then re-emitting.
--
-- With no destinations it stays a one-act scatter that evaporates, which
-- is right for spectacle layered over a payout that already flew (the
-- tournament win).
--
-- options: scale / tint / labels / tumble / tumble_opts, plus
--   dests           — ordered { { key, xy [, amount] }, ... }. Chips fill
--                     each in turn; the last one is unlimited.
--   dest_key / dest — shorthand for a single unlimited destination
--   within          — { w, h } of the box this belongs inside; sizes the
--                     scatter to it instead of to fixed pixels
--   gather_duration — seconds of the run home
--   gather_sound    — one arrival thunk as the regroup lands
--   plus anything FlightSystem.scatterParams accepts.
function ChipFlight.explodeTaken(taken, options)
    if not taken or #taken == 0 then return end
    options = options or {}
    local tint   = options.tint or options.chip_tint
    local s      = options.scale or 1
    local labels = (options.labels ~= false)

    -- Fabrication, as in transfer: the pile that comes apart is the real
    -- pot, but what regroups is the real PAYOUT, which late-game
    -- multipliers can push orders of magnitude higher. The extra chips
    -- join the burst from inside the pile's own footprint so they come
    -- apart with it instead of appearing beside it.
    if options.fabricate then
        local have, base_n = 0, #taken
        for _, t in ipairs(taken) do
            local d = ChipData.denominations[t.d]
            have = have + ((d and d.value) or 0)
        end
        local short = options.fabricate - have
        if short > 0 then
            local extra = Denoms.breakdown(short, ChipData.denominations,
                                           options.fab_palette or ChipData.full_palette,
                                           ChipData.tier_chip_target,
                                           Denoms.tierFromAmount(short))
            for _, d in ipairs(extra or {}) do
                local src = taken[love.math.random(1, base_n)]
                taken[#taken + 1] = { d = d, x = src.x, y = src.y }
            end
        end
    end

    local dests = options.dests
    if not dests and (options.dest_key or options.dest) then
        dests = { { key = options.dest_key, xy = options.dest } }
    end
    local gathering = (dests ~= nil) and (#dests > 0)
    local gather_d  = options.gather_duration or GATHER_DURATION

    -- Reserve the landing slots NOW, before a single chip has flown, each
    -- in its own destination pile. Those piles hold the slots open for the
    -- whole explosion, so neither can complete itself while its chips are
    -- still in the air.
    local dest_of, slot_of = _reserveAcross(taken, gathering and dests or nil)

    if gathering then
        options.duration = options.duration or SCATTER_DURATION
        if options.gather_sound then
            FlightSystem.scheduleSound(options.gather_sound,
                options.duration + gather_d - 0.04)
        end
    end
    _scatterWithin(options)
    local duration = options.duration or 1.1

    -- Which chips fly at this motion level; the rest land where they are
    -- (their gather leg runs from the pile's own footprint).
    local n_vis = 0
    for _, t in ipairs(taken) do if t.x and t.y then n_vis = n_vis + 1 end end
    local n_fly = FlightSystem.scatterCount(n_vis, options)
    local flown = 0
    for i, t in ipairs(taken) do
        local slot = slot_of[i]
        local dest = dest_of[i]
        -- A chip the pile's width budget had clipped has no slot; it was
        -- never on screen, so it has nothing to come apart from.
        if not (t.x and t.y) then
            if slot then ChipPile.accept(dest.key, slot.chip) end
        else
            local ctx
            if gathering then
                -- The run home renders at the scale of the pile it's
                -- joining: a chip has to be indistinguishable from the
                -- pile chip it becomes.
                ctx = { slot = slot, dest = dest, tint = tint, d = t.d,
                        scale = (dest.key and ChipPile.scale(dest.key)) or s,
                        duration = gather_d }
            end
            flown = flown + 1
            if flown > n_fly then
                -- Landed on the spot: the turn happens from here.
                if ctx then _gatherLeg(t.x, t.y, nil, ctx) end
            else
                local tumble
                if options.tumble == false then
                    tumble = false
                elseif gathering then
                    _OUT_TUMBLE.flips = love.math.random(1, 3)
                    _OUT_TUMBLE.spins = love.math.random(1, 3)
                    tumble = _OUT_TUMBLE
                else
                    tumble = options.tumble_opts or Tumble.PRESETS.throw
                end
                local dx, dy, arc, delay = FlightSystem.scatterParams(t.x, t.y, options)
                FlightSystem.emitChip(t.x, t.y, dx, dy, t.d, labels, tint, s, 1, tumble,
                                      delay, duration, arc,
                                      ctx and _gatherLeg or nil, ctx, nil, options.motion)
            end
        end
    end

    if n_fly == 0 then
        if options.arrival_sound then FlightSystem.scheduleSound(options.arrival_sound, 0) end
        return
    end
    FlightSystem.scatterSound(options)
end

-- Convenience: form a pile out of a dollar amount at (x, y) and blow it
-- apart immediately. For celebrations with no pile already on screen
-- (the tournament win, whose pot slot holds the hand counter instead).
-- The chip count is whatever the breakdown produces — never padded, so
-- this is still the real chips and not a multiplied copy.
function ChipFlight.explodeAmount(x, y, amount, stake_id, options)
    if not amount or amount <= 0 then return end
    options = options or {}
    local tier  = options.tier or Denoms.tierFromAmount(amount)
    local chips = Denoms.breakdown(amount, ChipData.denominations,
                                   _paletteForAmount(stake_id, amount),
                                   ChipData.tier_chip_target, tier)
    if not chips or #chips == 0 then return end
    ChipFlight.explodeStack(x, y, chips, options)
end

return ChipFlight
