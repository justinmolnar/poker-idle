-- views/ChipPile.lua
--
-- A pile of chips is a COLLECTION, not a number.
--
-- Every other pile in this codebase was a scalar re-derived every frame —
-- `Chips.drawStack(x, y, Denoms.breakdown(value))`. A chip in the air was a
-- transient with no relationship to any pile: when its flight ended it was
-- destroyed, and independently the pile's scalar re-broke-down. Nothing
-- ever moved between them, which is why chips read as teleporting no
-- matter how good the flight was.
--
-- Here a pile owns an ordered list of chips. A chip LEAVES that list when
-- it takes off (`take`) and is INSERTED into the destination list at the
-- exact pixel its flight ends (`reserve` → `accept`). There is no frame
-- where a chip exists in neither place or in both.
--
-- The cost: a pile shows the chips that actually arrived, not the ideal
-- composition. $70 that arrived as fourteen $5s stays fourteen $5s even
-- though the breakdown would now prefer $10s. It tidies with a visible
-- settle animation at quiet moments (see `tidy`), which is what a dealer
-- squaring up a stack looks like anyway.
--
-- Keyed-singleton service, matching the uniform pattern the codebase
-- already uses (RollingValue, ClickFlash, Pop, AnchorRegistry): module-local
-- table, opaque string keys, update(dt), clear(). Keys reuse the anchor
-- keys (`Table.anchorKey(tbl, "pot")`, `"bankroll"`) so a pile and the
-- anchor flights aim at can't drift apart.
--
-- Engine-agnostic in the same sense views/Chips is: denominations are
-- opaque indices into a caller-supplied ladder, keys are opaque strings,
-- no poker anywhere.
--
-- ─── Usage ──────────────────────────────────────────────────────────────
--   draw side, every frame:
--       ChipPile.place(key, x, y, { align = ..., max_w = ..., scale = ... })
--       ChipPile.sync(key, value, { palette = ..., tier = ... })
--       ChipPile.draw(key)
--   flight side (see views/ChipFlight.transfer):
--       local taken = ChipPile.take(src_key, amount)
--       local slots = ChipPile.reserve(dst_key, denoms_of(taken))
--       ... fly slot to slot, on_arrive → ChipPile.accept(dst_key, slot.chip)
--
-- ─── What a pile keeps between frames ───────────────────────────────────
-- Its LAYOUT is a flat record (views/Chips.stackLayoutInto): parallel
-- arrays, one entry per settled chip in draw order, solved only when the
-- collection or a layout-shaping placement field changes. A landing chip
-- whose column has room is inserted into the record directly, so the
-- ordinary case — a bet's chips arriving one after another — never
-- re-solves the pile at all.
--
-- Its PICTURE is one SpriteBatch on the chip atlas, rebuilt from the
-- record only when the record, the tint, the atlas or the sub-pixel
-- placement changed. A resting pile is one texture draw a frame, whatever
-- it holds; the hundreds of immediate-mode chips a full board used to draw
-- are gone. Headless, or with the atlas off, the same record draws a chip
-- at a time through views/Chips as before.

local Chips    = require("views.Chips")
local Denoms   = require("services.DenominationBreakdown")
local ChipData = require("data.chips")
local Perf     = require("services.Perf")

local ChipPile = {}

-- key -> {
--   chips   = { { d = denom_idx, air = true|nil }, ... }  -- ordered, the truth
--   n_air   = count of chips currently in flight toward this pile
--   gen     = generation stamp; bumped by clear() so a late arrival from a
--             previous life is discarded instead of resurrecting a chip
--   place   = { x, y, align, max_w, scale }  -- last draw placement
--   tint    = per-stake chip tint from the last place()
--   want    = last synced scalar, reconciled in update()
--   settle  = in-progress tidy animation
--   idle    = seconds since the key was last touched (GC)
--   wrong_t = seconds the pile has disagreed with `want` (debounce)
--   since_take  = seconds since chips last left (refill lockout)
--   since_place = seconds since a draw path last placed it (liveness)
--   rev / L / layout_rev    the layout revision, the settled record, and
--                           the revision it was solved at
--   frozen / frozen_L / frozen_rev   the Low-motion snapshot and its record
--   batch / batch_*         the SpriteBatch and the keys it was built on
-- }
local _piles = {}

-- ── Tunables ────────────────────────────────────────────────────────
local SETTLE_DUR      = 0.22   -- seconds for a tidy animation
-- A pile must disagree with its scalar for this long before it tidies.
-- Without the debounce a single frame where the model credits a win
-- before the chips are reserved would snap the pile up and the chips
-- would then land on top of growth that already happened.
local RECONCILE_DELAY = 0.35
local SYNC_FRESH      = 0.25   -- a `want` older than this is stale; ignore it
-- A pile that has just paid chips out must not refill from its scalar
-- while they are still in the air. The scalar behind a pile is often
-- zeroed a frame or two AFTER the chips leave (the pot snapshot is taken
-- before the applicator empties it), and without this lockout the pot
-- would re-materialise at full size in the same instant it pushed.
local TAKE_LOCKOUT    = 1.0
-- A pile only takes part in a transfer while something is actively
-- placing it. Surfaces that draw no pile at all (mini panels have no pot
-- pile, tournament tables no stack pile) must not silently accumulate
-- chips nobody ever renders — those transfers fall back to plain
-- point-to-point flights, which is what they were before.
local PLACE_FRESH     = 0.5
-- How long a chip may claim to be in the air before the pile stops
-- believing it.
--
-- n_air gates EVERY reconcile path — sync, tidy, the empty-pile refill.
-- As an exact counter it is also a single point of failure: one chip that
-- never reports its arrival (a flight dropped somewhere it can't call
-- back, a chip list swapped underneath it) and the pile is frozen for the
-- rest of the session, silently accumulating whatever is reserved into it
-- next. services/PendingChips released on a timer for exactly this reason
-- and said so; replacing it with exact bookkeeping threw that away.
--
-- So the count is DERIVED from the chips each frame rather than tracked,
-- and a chip that overstays lands itself. Worst case a pile completes a
-- little early. Always prefer the failure that corrects itself.
local AIR_TTL         = 4.0
local GC_SECONDS      = 30     -- drop keys nothing has touched (closed tables)
local TIDY_FACTOR     = 2      -- tidy once the pile exceeds N× its tier target
-- The most chips a pile holds, settled and airborne together, as a
-- multiple of its tier's chip target: the reconcile snaps a pile past it,
-- and reserve adds no record past it (the flight is still given a landing
-- spot; its chip is absorbed on arrival). Without the cap on reservations
-- a pile every payout flies to (the bankroll's, on a busy board, which is
-- never quiet long enough for the reconcile to run) grew by every chip
-- that ever landed in it, fifty thousand in a minute of thirty-six Zooms,
-- and each landing re-solved the lot: the board that got slower the longer
-- it was open.
local CAP_FACTOR      = 3
local EPS             = 1e-9
-- Sprites a pile's batch starts with. A table pile is a few columns; the
-- bankroll can be twenty. Both grow on demand (views/Chips.Batch:add).
local BATCH_CAP_TABLE    = 128
local BATCH_CAP_BANKROLL = 512

local MAX_PER_COLUMN = Chips.MAX_PER_COLUMN

-- ── Helpers ─────────────────────────────────────────────────────────
-- ─── The layout revision ───────────────────────────────────────────────
-- ChipPile.draw was re-solving every pile's stack layout every frame:
-- building a denomination list, grouping it, sorting the groups, and
-- allocating a table per placed chip — for a bankroll pile of 120 chips,
-- 36 pot piles and 36 stack piles. The layout only moves when the chips or
-- the layout-shaping place fields change, so both bump this and the solve
-- is reused until then.
--
-- Deliberately NOT bumped by place.x / place.y: the solve is in local
-- coordinates and the screen offset is applied at draw, so a pile that is
-- merely moving (a dragged panel, a shaking table) keeps its cached layout.
local function touch(e)
    e.rev = (e.rev or 0) + 1
end

local function denomValue(d)
    local e = ChipData.denominations[d]
    return (e and e.value) or 0
end

-- The batch is GPU memory; it goes with the pile, not with the sweep.
local function dropBatch(e)
    if e.batch then
        Chips.releaseBatch(e.batch)
        e.batch = nil
    end
end

-- The registry is bounded as well as swept: a session that opens and
-- closes tables faster than GC_SECONDS can never hold more than a board's
-- worth of piles plus a margin. Past the bound the idlest quiet pile goes.
local MAX_PILES = 2 * 36 + 8
local _n_piles  = 0
local function evictIdlest()
    local worst, worst_key = -1, nil
    for k, e in pairs(_piles) do
        if e.n_air == 0 and not e.settle and e.idle > worst then
            worst, worst_key = e.idle, k
        end
    end
    if worst_key then
        dropBatch(_piles[worst_key])
        _piles[worst_key] = nil
        _n_piles = _n_piles - 1
    end
end

local function entry(key)
    local e = _piles[key]
    if not e then
        if _n_piles >= MAX_PILES then evictIdlest() end
        e = { chips = {}, n_air = 0, gen = 1, idle = 0, wrong_t = 0, rev = 0,
              since_take = math.huge, since_place = math.huge,
              L = Chips.newLayoutRecord(), layout_rev = -1 }
        _piles[key] = e
        _n_piles = _n_piles + 1
    end
    e.idle = 0
    return e
end

-- Is this key a pile a transfer can hand chips to / take them from? Only
-- while a draw path is still placing it every frame.
local function live(key)
    local e = key and _piles[key]
    if not e or not e.place then return nil end
    if e.since_place > PLACE_FRESH then return nil end
    return e
end

local function pileValue(e)
    local sum = 0
    for _, c in ipairs(e.chips) do sum = sum + denomValue(c.d) end
    return sum
end

-- Same CONTENTS, not same order. The pile is drawn sorted by
-- denomination, so two lists holding the same chips render identically no
-- matter what order they arrived in — and comparing them positionally made
-- the pile re-settle to rearrange something the player cannot see.
local function sameChips(chips, target)
    if #chips ~= #target then return false end
    local counts = {}
    for _, c in ipairs(chips) do counts[c.d] = (counts[c.d] or 0) + 1 end
    for _, c in ipairs(target) do
        local n = counts[c.d]
        if not n or n == 0 then return false end
        counts[c.d] = n - 1
    end
    return true
end

local function smallestIn(palette)
    local best
    for _, d in ipairs(palette or ChipData.full_palette) do
        local v = denomValue(d)
        if v > 0 and (not best or v < best) then best = v end
    end
    return best or 0.01
end

-- ── Layout ──────────────────────────────────────────────────────────
-- Piles are always laid out at the ORIGIN and mapped through the
-- placement afterwards. Callers that draw inside a love.graphics.scale()
-- (the pot pile and your stack both do on small panels) would otherwise
-- compute slots in unscaled space and every chip would depart from the
-- wrong place. One implementation, here, for pile rendering AND for
-- everything that needs to know where an individual chip sits.
--
-- Solver scratch, module-wide and reused: the flat denomination list the
-- solver eats and, beside it, each entry's index in e.chips so the record
-- comes back keyed on the pile's own positions. Two spare records for the
-- solves that are read once and dropped (a reserve's targets, a tidy's
-- before and after).
local _list = {}
local _pos  = {}
local _opts = {}
local _S1   = Chips.newLayoutRecord()
local _S2   = Chips.newLayoutRecord()
local _claimed = {}

-- `settled_only` drops airborne chips. That's what the pile DRAWS: a
-- chip that hasn't landed yet has no business occupying a slot, and
-- holding one open leaves a gap in the stack that reads as a rendering
-- fault rather than as anticipation. The full list is still what an
-- ARRIVAL is measured against — a chip in the air needs to know where it
-- will sit once it's part of the pile.
local function fillList(e, settled_only)
    local n = 0
    local chips = e.chips
    for i = 1, #chips do
        local c = chips[i]
        if not (settled_only and c.air) then
            n = n + 1
            _list[n] = c.d
            _pos[n]  = i
        end
    end
    return n
end

-- The solver options for a placement, in a reused table.
local function solveOpts(place)
    local s  = place.scale or 1
    local mw = place.max_w
    if mw and s ~= 1 then mw = mw / s end
    _opts.align    = place.align or "center"
    _opts.max_w    = mw
    -- Column caps are in COLUMNS, not pixels, so unlike max_w they do
    -- not get divided by the scale.
    _opts.max_cols = place.max_cols
    _opts.max_rows = place.max_rows
    -- A pile placed with labels = false (tournament chips are not money
    -- and must not say "1c") masks them at the single source every
    -- consumer reads labels from — draw, settle parts, takeAll debris.
    _opts.labels   = place.labels
    return _opts
end

-- Solve the pile into record L, keyed on e.chips positions.
local function solveInto(L, e, settled_only)
    if not e.place then
        return Chips.stackLayoutInto(L, _list, 0, nil, _pos)
    end
    local n = fillList(e, settled_only)
    return Chips.stackLayoutInto(L, _list, n, solveOpts(e.place), _pos)
end

-- Solve a plain denomination list (a tidy's target) into L.
local function solveList(L, list, place)
    if not place then return Chips.stackLayoutInto(L, list, 0, nil) end
    return Chips.stackLayoutInto(L, list, #list, solveOpts(place))
end

-- The settled record, re-solved only when the revision moved.
local function currentLayout(e)
    if e.layout_rev ~= e.rev then
        solveInto(e.L, e, true)
        e.layout_rev = e.rev
    end
    return e.L
end

-- The Low-motion snapshot's record (see ChipPile.freeze), likewise.
local function frozenLayout(e)
    if e.frozen_rev ~= e.rev then
        solveList(e.frozen_L, e.frozen, e.place)
        e.frozen_rev = e.rev
    end
    return e.frozen_L
end

local function toScreen(place, lx, ly)
    local s = place.scale or 1
    return place.x + lx * s, place.y + ly * s
end

-- `shade` and `depth` come from the placement: how far down its column the
-- chip sits. `s` is handed to drawChip as well as applied as a transform,
-- because the chip's REAL on-screen size is what decides how much anatomy
-- resolves — a pile on a 146px panel draws at 0.3 and full detail there is
-- mud.
local function drawChipLocal(place, tint, lx, ly, d, alpha, label, shade, depth, rot)
    local s = place.scale or 1
    local sx, sy = toScreen(place, lx, ly)
    if s == 1 then
        Chips.drawChip(sx, sy, d, alpha, label, tint, shade, depth, 1, rot)
    else
        love.graphics.push()
        love.graphics.translate(sx, sy)
        love.graphics.scale(s, s)
        Chips.drawChip(0, 0, d, alpha, label, tint, shade, depth, s, rot)
        love.graphics.pop()
    end
end

-- A whole column as one shape (views/Chips.drawColumn), for a pile placed
-- with detail = "micro". Same transform rule as drawChipLocal: the scale
-- goes on the stack AND into the call, so the outline stays a screen pixel.
local function drawColumnLocal(place, tint, lx, ly, d, alpha, n_above)
    local s = place.scale or 1
    local sx, sy = toScreen(place, lx, ly)
    if s == 1 then
        Chips.drawColumn(sx, sy, d, n_above, alpha, tint, 1)
    else
        love.graphics.push()
        love.graphics.translate(sx, sy)
        love.graphics.scale(s, s)
        Chips.drawColumn(0, 0, d, n_above, alpha, tint, s)
        love.graphics.pop()
    end
end

-- Cast shadow under a column base, in the pile's own placement space.
local function drawShadowLocal(place, lx, ly, alpha)
    local s = place.scale or 1
    local sx, sy = toScreen(place, lx, ly)
    Chips.drawShadow(sx, sy, alpha, s)
end

-- Snap a running settle to its end state. Any structural change (take,
-- reserve) has to land on a settled pile or the animation would be
-- interpolating toward a composition that no longer exists.
local function finishSettle(e)
    if not e.settle then return end
    e.chips  = e.settle.chips
    e.settle = nil
    touch(e)
end

-- ── Public: layout for callers with no pile ─────────────────────────
-- Same origin-then-transform rule, exposed for one-shot piles that were
-- never registered here (views/ChipFlight.explodeStack lays out a
-- breakdown it was handed). Returns screen-space { x, y, idx, with_label }.
function ChipPile.layoutAt(x, y, chip_indices, opts)
    opts = opts or {}
    local s  = opts.scale or 1
    local mw = opts.max_w
    if mw and s ~= 1 then mw = mw / s end
    local placed = Chips.stackLayout(0, 0, chip_indices, {
        align    = opts.align or "center",
        max_w    = mw,
        max_cols = opts.max_cols,
        max_rows = opts.max_rows,
        labels   = opts.labels,
    })
    for _, p in ipairs(placed) do
        p.x, p.y = x + p.x * s, y + p.y * s
    end
    return placed
end

-- ── Placement ───────────────────────────────────────────────────────
-- Record where this pile draws, so anything that needs a chip's exact
-- pixel can ask without re-deriving the caller's transform. Call it every
-- frame from the draw path, BEFORE sync/draw, and call it even when the
-- pile is empty — a flight that arrives while the pile is at zero still
-- needs to know where the pile is.
function ChipPile.place(key, x, y, opts)
    if not key then return end
    local e = entry(key)
    opts = opts or {}
    -- Written in place: this is called once per pile per frame from the
    -- draw path, and a fresh table each time was pure garbage. Only a
    -- change to a field the SOLVE depends on bumps the revision — x and y
    -- are applied at draw, so moving a pile does not re-solve it.
    local p = e.place
    if not p then
        p = {}
        e.place = p
        touch(e)
    end
    local align = opts.align or "center"
    local scale = opts.scale or 1
    if p.align ~= align or p.max_w ~= opts.max_w or p.scale ~= scale
       -- How wide/deep this pile may grow, in columns. The caller knows
       -- what its pile would run into; the pile does not.
       or p.max_cols ~= opts.max_cols or p.max_rows ~= opts.max_rows
       -- false = no denomination labels, ever (see solveOpts).
       or p.labels ~= opts.labels then
        p.align, p.max_w, p.scale  = align, opts.max_w, scale
        p.max_cols, p.max_rows     = opts.max_cols, opts.max_rows
        p.labels                   = opts.labels
        touch(e)
    end
    p.x, p.y      = x, y
    -- Draw-only, like x and y: the layout does not read it, so a tier flip
    -- (the grid repacking) must not throw the solved layout away.
    p.detail      = opts.detail
    e.tint        = opts.tint
    e.since_place = 0
end

function ChipPile.scale(key)
    local e = _piles[key]
    return (e and e.place and e.place.scale) or 1
end

-- With a key: how many chips that pile holds (the felt's stack readouts).
-- Without one: how many piles the registry holds (tests, the HUD). The
-- two used to be separate definitions of the same name and the second
-- silently replaced the first.
function ChipPile.count(key)
    if key == nil then return _n_piles end
    local e = _piles[key]
    return e and #e.chips or 0
end

-- The in-progress settle's parts, or nil when the pile is at rest. A read
-- seam for measuring how far a settle actually moves chips.
function ChipPile.debugSettleParts(key)
    local e = _piles[key]
    return e and e.settle and e.settle.parts or nil
end

-- The slots the pile is DRAWING right now, in draw order and screen space:
-- { x, y, idx, depth, with_label, col_base, rot }. From the record the
-- draw reads, so a check can hold it against a fresh layout of the same
-- chips. nil mid-settle, when there is no single layout.
function ChipPile.debugSlots(key)
    local e = _piles[key]
    if not e or not e.place or e.settle then return nil end
    local L = e.frozen and frozenLayout(e) or currentLayout(e)
    local out = {}
    for k = 1, L.n do
        local sx, sy = toScreen(e.place, L.x[k], L.y[k])
        out[k] = { x = sx, y = sy, idx = L.idx[k], depth = L.depth[k],
                   with_label = L.label[k], col_base = L.base[k], rot = L.rot[k] }
    end
    return out
end

-- The footprint (Chips.stackFootprint) of what the pile holds, airborne
-- chips included, with no list built: the panel reads it every render.
local _fp_list = {}
function ChipPile.footprint(key)
    local e = key and _piles[key]
    if not e then return 0, 0 end
    local n = 0
    for _, c in ipairs(e.chips) do n = n + 1; _fp_list[n] = c.d end
    return Chips.stackFootprint(_fp_list, n)
end

-- The denominations this pile currently holds, in order. A read-only view
-- for anything that needs to reason about the pile's composition rather
-- than just its total. `settled_only` leaves out the chips still in the
-- air, which is the list the pile draws.
function ChipPile.denominations(key, settled_only)
    local e = _piles[key]
    if not e then return {} end
    local out = {}
    for _, c in ipairs(e.chips) do
        if not (settled_only and c.air) then out[#out + 1] = c.d end
    end
    return out
end

function ChipPile.value(key)
    local e = _piles[key]
    return e and pileValue(e) or 0
end

-- ── Sync: tracking a scalar the pile receives no flights for ────────
-- Records the value this pile is meant to represent. The reconciliation
-- itself happens in update(), and only while the pile is QUIET — no
-- chips in the air, no settle running, and the disagreement has persisted
-- past RECONCILE_DELAY. Mid-flight the chips are the truth and the scalar
-- waits its turn.
--
-- The one thing sync does immediately is populate an empty pile: a pile
-- appearing for the first time has nothing to animate from.
function ChipPile.sync(key, value, opts)
    local e = entry(key)
    opts = opts or {}
    value = value or 0
    e.want     = value
    e.palette  = opts.palette or e.palette or ChipData.full_palette
    e.tier     = opts.tier or e.tier or "medium"
    -- A chip target of the caller's own (the bankroll's is its band's
    -- width); nil keeps the tier's.
    e.target   = opts.chip_target
    e.want_age = 0

    if #e.chips == 0 and e.n_air == 0 and not e.settle and value > 0
       and e.since_take > TAKE_LOCKOUT then
        e.chips = ChipPile.compose(value, e.palette, e.tier, e.target)
        e.wrong_t = 0
        touch(e)
    end
end

-- The most chips a composition holds: the tier's target times
-- TIDY_FACTOR, which is also where the reconcile starts calling a pile
-- too full. A breakdown past the top of the ladder (a bankroll of 1e22
-- against a 1e20 chip) runs to the breakdown's own cap, and a pile built
-- that big was over this module's ceiling the moment it was composed, so
-- the reconcile rebuilt it every frame, forever.
local function composeCap(target)
    return target * TIDY_FACTOR
end

-- Breakdown → the chip records this module stores. Largest first, so the
-- truncation at the cap drops the change tail. `target` overrides the
-- tier's chip target (sync's chip_target).
local _tt = {}
function ChipPile.compose(value, palette, tier, target)
    tier = tier or "medium"
    local tt = ChipData.tier_chip_target
    if target then
        for k in pairs(_tt) do _tt[k] = nil end
        _tt[tier] = target
        tt = _tt
    end
    local list = Denoms.breakdown(value, ChipData.denominations,
                                  palette or ChipData.full_palette, tt, tier)
    local n = math.min(#list, composeCap(target or (ChipData.tier_chip_target[tier]) or 12))
    local out = {}
    for i = 1, n do out[i] = { d = list[i] } end
    return out
end

-- ── Minimal adjustment toward a value ───────────────────────────────
-- The difference between "make this pile worth $2.01" and "make this pile
-- worth $2.01 by adding a nickel to the one already worth $1.96".
--
-- Recomposing from the breakdown is correct but it is a whole new pile:
-- a different primary denomination, different counts, different column
-- widths, so every chip slides somewhere new to represent a five-cent
-- change. Across a table of piles all doing that on their own schedule it
-- reads as the whole felt fidgeting.
--
-- So this keeps the chips that are already there and moves only the
-- difference: add the largest palette chips that fit the shortfall, or
-- pull the chips that cover the excess. Returns nil when the pile can't
-- reach the value that way — a value that needs a chip smaller than any it
-- holds — and the caller falls back to a full recompose, which is what
-- keeps this converging.
local function adjustToward(e, want, palette)
    local tol  = smallestIn(palette) - EPS
    local out  = {}
    local pv   = 0
    for i, c in ipairs(e.chips) do
        out[i] = { d = c.d }
        pv = pv + denomValue(c.d)
    end

    -- Palette values, largest first.
    local vals = {}
    for _, idx in ipairs(palette) do
        vals[#vals + 1] = { idx = idx, v = denomValue(idx) }
    end
    table.sort(vals, function(a, b) return a.v > b.v end)

    local guard = 0
    while want - pv > tol do
        guard = guard + 1
        if guard > 256 then return nil end
        local added = false
        for _, entry in ipairs(vals) do
            if entry.v > 0 and entry.v <= (want - pv) + EPS then
                out[#out + 1] = { d = entry.idx }
                pv = pv + entry.v
                added = true
                break
            end
        end
        if not added then return nil end
    end

    while pv - want > tol do
        guard = guard + 1
        if guard > 256 then return nil end
        -- Drop the largest chip that doesn't overshoot, so the pile keeps
        -- its shape instead of being whittled from the small end.
        local best, best_v = nil, -1
        for i, c in ipairs(out) do
            local v = denomValue(c.d)
            if v <= (pv - want) + EPS and v > best_v then best, best_v = i, v end
        end
        if not best then return nil end
        table.remove(out, best)
        pv = pv - best_v
    end

    if math.abs(pv - want) > tol then return nil end
    return out
end

-- ── Tidy: the settle animation ──────────────────────────────────────
-- Re-compose toward `value` and slide every chip from where it is to
-- where it belongs, matching old to new by denomination and cross-fading
-- the remainder. Skipped (snapped) when the pile has never been drawn or
-- the caller asks for instant.
function ChipPile.tidy(key, value, opts)
    local e = _piles[key]
    if not e or e.n_air > 0 then return end
    opts = opts or {}
    finishSettle(e)

    local palette = opts.palette or e.palette or ChipData.full_palette
    local tier    = opts.tier    or e.tier    or "medium"

    -- Adjust in place where possible; recompose only when the pile has
    -- genuinely lost its shape. `rebuild` is set by the caller for the
    -- cases that have to start over: a pile carrying far too many chips,
    -- or one grossly out of step with its scalar.
    local target
    if not value or value <= 0 then
        target = {}
    elseif opts.rebuild or #e.chips == 0 then
        target = ChipPile.compose(value, palette, tier, e.target)
    else
        target = adjustToward(e, value, palette)
              or ChipPile.compose(value, palette, tier, e.target)
    end

    -- The pile is ALREADY the ideal composition. Something asked for a
    -- tidy that has nothing to tidy — a value whose last fraction of a
    -- cent no chip can represent, or a breakdown whose change tail
    -- legitimately runs past the tier's chip target. Animating it would
    -- slide every chip zero pixels and then be asked again a moment
    -- later, forever. This is the guard that makes settling converge.
    if sameChips(e.chips, target) then
        e.chips = target
        return
    end
    touch(e)

    if not e.place or opts.instant then
        e.chips = target
        return
    end

    -- Before and after, as two scratch records. `from` is what is on the
    -- felt now; `to` is the target list laid out the same way.
    local from = solveInto(_S1, e, true)
    for i, c in ipairs(target) do _list[i] = c.d end
    local to = Chips.stackLayoutInto(_S2, _list, #target, solveOpts(e.place))

    -- Pair by denomination, NEAREST FIRST: a $5 already on the felt slides
    -- to the closest place a $5 is wanted. Only the surplus fades.
    --
    -- This used to pop the last source off the list for the first target,
    -- which paired the two lists in opposite orders — the chip on the far
    -- right was sent to the far left and vice versa. Every settle therefore
    -- dealt the pile out again, and three identical stacks visibly traded
    -- places while being, chip for chip, exactly what they were before.
    -- Nothing about the pile had changed; the animation moved them anyway.
    for k = 1, from.n do _claimed[k] = false end

    local parts = {}
    for k2 = 1, to.n do
        local idx, tx, ty = to.idx[k2], to.x[k2], to.y[k2]
        -- Closest unclaimed source of this denomination, or none.
        local best, best_d2 = nil, math.huge
        for k1 = 1, from.n do
            if not _claimed[k1] and from.idx[k1] == idx then
                local dx, dy = from.x[k1] - tx, from.y[k1] - ty
                local d2 = dx * dx + dy * dy
                if d2 < best_d2 then best, best_d2 = k1, d2 end
            end
        end
        if best then _claimed[best] = true end
        parts[#parts + 1] = {
            d     = idx,
            label = to.label[k2],
            x0    = best and from.x[best] or tx,
            y0    = best and from.y[best] or ty,
            x1    = tx, y1 = ty,
            mode  = best and "move" or "in",
            -- A settling chip can change depth on the way. Interpolating
            -- the shade is what stops the whole pile flattening for the
            -- settle and popping back at the end.
            sh0   = best and from.shade[best] or to.shade[k2],
            sh1   = to.shade[k2],
            -- Where the chip was buried BEFORE the settle, and where it
            -- will be after. The draw picks between them: a chip on the
            -- move is a whole chip until it lands (see ChipPile.draw).
            depth0 = best and from.depth[best] or to.depth[k2],
            depth = to.depth[k2],
            base  = to.base[k2],
            rot   = to.rot[k2],
        }
    end
    for k1 = 1, from.n do
        if not _claimed[k1] then
            parts[#parts + 1] = {
                d     = from.idx[k1],
                label = from.label[k1],
                x0    = from.x[k1], y0 = from.y[k1],
                x1    = from.x[k1], y1 = from.y[k1],
                mode  = "out",
                sh0   = from.shade[k1], sh1 = from.shade[k1],
                depth0 = from.depth[k1],
                depth = from.depth[k1],
                base  = from.base[k1],
                rot   = from.rot[k1],
            }
        end
    end

    e.settle = {
        t     = 0,
        dur   = opts.settle_duration or SETTLE_DUR,
        parts = parts,
        chips = target,
    }
end

-- ── Take: chips leave this pile ─────────────────────────────────────
-- Removes chips worth `amount` and returns them as { { d, x, y }, ... }
-- in departure order, each carrying the screen pixel it was occupying.
-- The pile visibly shrinks NOW; the returned chips are what flies.
--
-- Where the pile holds no chip small enough, it MAKES CHANGE — a $5 is
-- swapped for five $1s and the $1 leaves. That keeps the pile's value
-- exact instead of overshooting, at the cost of a scruffier composition,
-- which is precisely what tidy() exists to clean up later.
local function breakChip(e, chip)
    local v = denomValue(chip.d)
    -- Break into the NEXT smaller denomination only. Breaking all the way
    -- down would let a $1M chip become 100 million $0.01s.
    local next_v, next_d
    for _, d in ipairs(e.palette or ChipData.full_palette) do
        local dv = denomValue(d)
        if dv < v - EPS and (not next_v or dv > next_v) then next_v, next_d = dv, d end
    end
    if not next_v or next_v <= 0 then return false end
    local n  = v / next_v
    local ni = math.floor(n + 0.5)
    if math.abs(n - ni) > 1e-6 or ni < 2 or ni > 64 then return false end

    for i, c in ipairs(e.chips) do
        if c == chip then
            table.remove(e.chips, i)
            for j = 1, ni do
                table.insert(e.chips, i + j - 1, { d = next_d })
            end
            touch(e)
            return true
        end
    end
    return false
end

-- The screen slot of e.chips[i] in the settled record, or the pile's own
-- anchor for a chip the width budget clipped.
local function slotOf(e, L, i)
    local k = L.k_of_pos[i]
    if k then return toScreen(e.place, L.x[k], L.y[k]) end
    return e.place and e.place.x, e.place and e.place.y
end

function ChipPile.take(key, amount)
    local e = live(key)
    if not e or not amount or amount <= 0 or #e.chips == 0 then return nil end
    e.idle = 0
    finishSettle(e)

    local need, mark, guard = amount, {}, 0
    while need > EPS and guard < 400 do
        guard = guard + 1
        local best, best_v, over, over_v
        for _, c in ipairs(e.chips) do
            if not c.air and not mark[c] then
                local v = denomValue(c.d)
                if v <= need + EPS then
                    if not best_v or v > best_v then best, best_v = c, v end
                elseif not over_v or v < over_v then
                    over, over_v = c, v
                end
            end
        end
        if best then
            mark[best] = true
            need = need - best_v
        elseif over and breakChip(e, over) then
            -- loop again; the change is now in the pile
        else
            break
        end
    end

    -- Positions are read AFTER any change-making, so a chip departs from
    -- where it is actually sitting at this instant — the drawn layout,
    -- not the one that includes chips still on their way here.
    local L = currentLayout(e)
    local taken = {}
    for i = #e.chips, 1, -1 do
        local c = e.chips[i]
        if mark[c] then
            local sx, sy = slotOf(e, L, i)
            table.insert(taken, 1, { d = c.d, x = sx, y = sy })
            table.remove(e.chips, i)
        end
    end
    e.wrong_t    = 0
    e.since_take = 0
    touch(e)
    if #taken == 0 then return nil end
    return taken
end

-- Everything VISIBLE, for a pile that is coming apart rather than paying
-- out (the stack detonation). Same return shape as take.
--
-- Airborne chips are left out: a chip still being carried here by its own
-- flight would otherwise be drawn twice at once, once by that flight and
-- once as debris. They're dropped with the pile — their flights complete
-- against a bumped generation and are discarded — so the pile can end up
-- worth slightly less than the scalar behind it until it reconciles.
--
-- Returns nil, and leaves the pile alone, when there is nothing visible to
-- take, so a caller can fall back to whatever it does without a pile.
function ChipPile.takeAll(key)
    local e = _piles[key]
    if not e or #e.chips == 0 then return nil end
    finishSettle(e)
    local L = currentLayout(e)
    local taken = {}
    for i, c in ipairs(e.chips) do
        if not c.air then
            local sx, sy = slotOf(e, L, i)
            taken[#taken + 1] = { d = c.d, x = sx, y = sy }
        end
    end
    if #taken == 0 then return nil end
    ChipPile.clear(key)
    e.since_take = 0
    return taken
end

-- ── Reserve / accept: chips arrive at this pile ─────────────────────
-- reserve() appends the incoming chips and marks them airborne. They
-- occupy their slots in the FULL layout — so the chips already on the
-- felt sit where they will still be sitting once the flight lands — but
-- the settled record the pile draws is untouched: the airborne chips are
-- simply not in it, and the flight fills the hole at exactly the pixel it
-- ends on.
--
-- Returns { { chip, x, y, with_label }, ... }, one per requested chip.
-- Hand `chip` back to accept() from the flight's on_arrive.
-- The pile's chip target: its own (sync's chip_target, the bankroll's
-- width) or its tier's.
local function tierTarget(e)
    return e.target or (ChipData.tier_chip_target[e.tier or "medium"]) or 12
end

local function pileCap(e)
    return tierTarget(e) * CAP_FACTOR
end

function ChipPile.reserve(key, denom_indices)
    if not denom_indices or #denom_indices == 0 then return nil end
    local e = live(key)
    if not e then return nil end
    e.idle = 0
    finishSettle(e)

    -- Records for as many chips as the pile has room for (CAP_FACTOR);
    -- the rest are given a landing spot and no record.
    local base  = #e.chips
    local n_rec = math.min(#denom_indices, math.max(0, pileCap(e) - base))
    local refs  = {}
    for i = 1, n_rec do
        local c = { d = denom_indices[i], air = true, gen = e.gen, ttl = AIR_TTL }
        e.chips[base + i] = c
        refs[i] = c
    end
    e.n_air   = e.n_air + n_rec
    e.wrong_t = 0

    -- Measured against the FULL layout, in a scratch record: an arriving
    -- chip aims for where it will sit once everything in the air has
    -- landed, so it doesn't have to shuffle after touching down. The
    -- drawn layout did not change, so the revision is left alone.
    local T   = solveInto(_S1, e, false)
    local out = {}
    for i, c in ipairs(refs) do
        local k = T.k_of_pos[base + i]
        local sx, sy, label
        if k then
            sx, sy = toScreen(e.place, T.x[k], T.y[k])
            label  = T.label[k]
        end
        out[i] = { chip = c, x = sx, y = sy, with_label = label }
    end
    if n_rec < #denom_indices then
        -- An absorbed chip (ChipPile.accept with no chip is a no-op) lands
        -- on any chip the pile already shows, a different one each: every
        -- payout funnelling to one pixel read as a drain. The base when
        -- nothing is placed.
        local n = T.n or 0
        for i = n_rec + 1, #denom_indices do
            local sx, sy
            if n > 0 then
                local k = love.math.random(1, n)
                sx, sy = toScreen(e.place, T.x[k], T.y[k])
            else
                sx, sy = toScreen(e.place, 0, 0)
            end
            out[i] = { chip = nil, x = sx, y = sy, with_label = false }
        end
    end
    return out
end

-- A chip has landed: it joins the settled record. If the record is
-- current, the pile is neither frozen nor settling, and the last column of
-- the chip's denomination has room, the chip is INSERTED at that column's
-- top — the numeric tail shifts up one, the entries below it are re-buried
-- by one, and the column's bookkeeping grows — which is exactly what a
-- fresh solve would produce, because a new chip only ever extends the last
-- column of its denomination and every other column stays where it was.
-- Otherwise (a new column, a full one, a stale record) the revision moves
-- and the next draw solves the pile whole.
local function landChip(e, chip)
    chip.air = nil
    e.n_air  = math.max(0, e.n_air - 1)
    e.idle   = 0

    local L = e.L
    if e.layout_rev ~= e.rev or e.frozen or e.settle or not e.place or L.n_cols == 0 then
        touch(e)
        return
    end

    -- Which column of this denomination is last, and this chip's position.
    local d, ci = chip.d, nil
    for c = 1, L.n_cols do
        if L.col_idx[c] == d then ci = c end
    end
    if not ci or L.col_n[ci] >= MAX_PER_COLUMN then
        touch(e)
        return
    end
    local pos
    local chips = e.chips
    for i = 1, #chips do
        if chips[i] == chip then pos = i; break end
    end
    if not pos then
        touch(e)
        return
    end

    local Lx, Ly, Lidx, Lpos, Ldepth = L.x, L.y, L.idx, L.pos, L.depth
    local Llabel, Lbase, Lrot, Lshade, Lrow, Lcol = L.label, L.base, L.rot, L.shade, L.row, L.col
    local kop = L.k_of_pos
    local n   = L.n
    local top = L.col_top_k[ci]
    local ins = top + 1

    -- Shift the tail up one entry.
    for k = n, ins, -1 do
        local j = k + 1
        Lx[j], Ly[j], Lidx[j], Lpos[j], Ldepth[j] = Lx[k], Ly[k], Lidx[k], Lpos[k], Ldepth[k]
        Llabel[j], Lbase[j], Lrot[j], Lshade[j], Lrow[j], Lcol[j] =
            Llabel[k], Lbase[k], Lrot[k], Lshade[k], Lrow[k], Lcol[k]
        kop[Lpos[j]] = j
    end
    for c = 1, L.n_cols do
        if L.col_top_k[c] >= ins then L.col_top_k[c] = L.col_top_k[c] + 1 end
    end

    -- The chips below the new top are one deeper, and the label moves up.
    local cn = L.col_n[ci]
    for k = top - cn + 1, top do
        local depth = Ldepth[k] + 1
        Ldepth[k] = depth
        Lshade[k] = Chips.shadeFor(depth)
        Llabel[k] = false
    end

    local kk = cn + 1
    Lx[ins]     = L.col_x[ci]
    Ly[ins]     = L.col_y[ci] + (kk - 1) * Chips.stackStep()
    Lidx[ins]   = d
    Lpos[ins]   = pos
    Ldepth[ins] = 0
    Llabel[ins] = (e.place.labels ~= false)
    Lbase[ins]  = false
    Lrot[ins]   = Chips.slotRotation(d, ci, kk)
    Lshade[ins] = Chips.shadeFor(0)
    Lrow[ins]   = L.col_row[ci]
    Lcol[ins]   = ci
    kop[pos]    = ins
    if pos > L.k_of_pos_n then L.k_of_pos_n = pos end
    L.col_n[ci]     = kk
    L.col_top_k[ci] = ins
    L.n = n + 1

    -- The picture changed, the solve did not: both revisions move together
    -- so the batch rebuilds and the layout is not re-solved.
    touch(e)
    e.layout_rev = e.rev
end

-- The chip has landed. A chip whose generation no longer matches (its
-- pile was cleared, or the table closed and the key was recycled) is
-- silently dropped — it belongs to a pile that no longer exists.
function ChipPile.accept(key, chip)
    local e = _piles[key]
    if not e or not chip or not chip.air then return end
    if chip.gen ~= e.gen then return end
    landChip(e, chip)
end

-- ── Freeze ──────────────────────────────────────────────────────────
-- Low motion: a pile that must not fidget draws a snapshot of its settled
-- chips while the real collection keeps taking and accepting underneath.
-- views/TablePanel freezes the pot and the player's stack for a street and
-- thaws them at the next street and at settle, so the felt's chips change
-- a few times a hand instead of on every bet. The snapshot has its own
-- record, solved under the revision like the live one.
function ChipPile.freeze(key)
    local e = _piles[key]
    if not e then return end
    e.frozen = ChipPile.denominations(key, true)
    e.frozen_L = e.frozen_L or Chips.newLayoutRecord()
    e.frozen_rev = -1
    touch(e)
end

function ChipPile.thaw(key)
    local e = _piles[key]
    if e then e.frozen = nil; touch(e) end
end

-- ── Draw ────────────────────────────────────────────────────────────
-- The pile's batch, made on first use and remade when the atlas changes
-- generation (a resize, a font). nil headless or with the atlas off, and
-- the record draws a chip at a time instead.
local function pileBatch(e, key)
    local B   = e.batch
    local gen = Chips.atlasGen()
    if B and B.gen ~= gen then
        Chips.releaseBatch(B)
        B = nil
        e.batch = nil
    end
    if not B then
        B = Chips.newBatch((key == "bankroll") and BATCH_CAP_BANKROLL or BATCH_CAP_TABLE)
        e.batch = B
    end
    return B
end

-- Does the batch need rebuilding for this frame? The record's revision,
-- the tint and the atlas are the obvious keys; the sub-pixel part of the
-- placement is the quiet one — labels are snapped to whole screen pixels
-- when they are added (views/Chips), so a pile that slides by a fraction
-- has to re-add them. A pile that moves by whole pixels does not.
local function batchStale(e, B, place, tint, s)
    local fx, fy = place.x - math.floor(place.x), place.y - math.floor(place.y)
    if e.batch_rev == e.rev and e.batch_tint == tint and e.batch_gen == B.gen
       and e.batch_fx == fx and e.batch_fy == fy and e.batch_s == s then
        return false
    end
    e.batch_rev, e.batch_tint, e.batch_gen = e.rev, tint, B.gen
    e.batch_fx, e.batch_fy, e.batch_s = fx, fy, s
    return true
end

-- The record's chips into the batch: shadows first, then chips in draw
-- order. Same two passes as the immediate draw, for the same reason — a
-- shadow is wider than its chip and would land on the neighbour's column.
local function fillBatch(B, L, place, tint, s)
    Chips.batchClear(B)
    Chips.batchOrigin(B, place.x, place.y, s)
    for k = 1, L.n do
        if L.base[k] then Chips.addShadow(B, L.x[k], L.y[k], 1, 1) end
    end
    for k = 1, L.n do
        Chips.addChip(B, L.x[k], L.y[k], L.idx[k], 1, L.label[k], tint,
                      L.shade[k], L.depth[k], L.rot[k], s, 1)
    end
    Perf.count("pile_batch")
end

-- Draw a record: the micro tier as vector columns, otherwise the batch or,
-- without one, a chip at a time.
local function drawRecord(e, key, L, micro)
    local place, tint = e.place, e.tint
    local s = place.scale or 1
    if micro then
        -- "micro": one shape per column and no shadows. The column is drawn
        -- from its BASE entry, whose depth is the number of chips above it;
        -- every other entry in that column is skipped.
        for k = 1, L.n do
            if L.base[k] then
                drawColumnLocal(place, tint, L.x[k], L.y[k], L.idx[k], 1, L.depth[k])
            end
        end
        return
    end
    local B = pileBatch(e, key)
    if B then
        if batchStale(e, B, place, tint, s) then fillBatch(B, L, place, tint, s) end
        Chips.drawBatch(B, place.x, place.y, s)
        return
    end
    -- Shadows are their own pass, always. One is wider than the chip it
    -- belongs to and columns sit two pixels apart, so interleaved they
    -- would land on the neighbouring column's chips.
    for k = 1, L.n do
        if L.base[k] then drawShadowLocal(place, L.x[k], L.y[k], 1) end
    end
    for k = 1, L.n do
        drawChipLocal(place, tint, L.x[k], L.y[k], L.idx[k], 1, L.label[k],
                      L.shade[k], L.depth[k], L.rot[k])
    end
end

local function partAlpha(p, ease)
    if p.mode == "in"  then return ease end
    if p.mode == "out" then return 1 - ease end
    return 1
end

-- How buried to draw a settling part. Drawn at its DESTINATION depth from
-- the first frame, a top chip bound for the middle of a column slid across
-- the felt as the bottom crescent of a cylinder wall with nothing on top of
-- it: the flash of "another kind of chip" a settle used to show. A chip in
-- motion is a whole chip until it lands; one that stays put is covered only
-- while it is covered both before and after, so a column being uncovered
-- shows the full chip as the one above leaves, and one being covered stays
-- whole until the arrival is actually on it.
local function partDepth(p, ease)
    if ease >= 1 then return p.depth end
    if p.x0 ~= p.x1 or p.y0 ~= p.y1 then return 0 end
    return math.min(p.depth0 or p.depth, p.depth)
end

-- A settle in progress: every part interpolated. The batch is rebuilt
-- every frame from the parts — a settle is a fifth of a second on one pile.
local function drawSettle(e, key, micro)
    local place, tint = e.place, e.tint
    local s     = place.scale or 1
    local parts = e.settle.parts
    local k     = math.min(1, e.settle.t / e.settle.dur)
    local ease  = k * k * (3 - 2 * k)

    if micro then
        for _, p in ipairs(parts) do
            local a = partAlpha(p, ease)
            -- A settling column rides its base part; a bet is exactly when
            -- the per-chip cost would matter most.
            if a > 0.01 and p.base then
                drawColumnLocal(place, tint,
                                p.x0 + (p.x1 - p.x0) * ease,
                                p.y0 + (p.y1 - p.y0) * ease,
                                p.d, a, p.depth)
            end
        end
        return
    end

    local B = pileBatch(e, key)
    if B then
        Chips.batchClear(B)
        Chips.batchOrigin(B, place.x, place.y, s)
        for _, p in ipairs(parts) do
            local a = partAlpha(p, ease)
            -- A shadow at full strength under a chip fading out is a
            -- smudge with nothing on top of it.
            if p.base and a > 0.01 then
                Chips.addShadow(B, p.x0 + (p.x1 - p.x0) * ease,
                                   p.y0 + (p.y1 - p.y0) * ease, a, 1)
            end
        end
        for _, p in ipairs(parts) do
            local a = partAlpha(p, ease)
            if a > 0.01 then
                local sh = (p.sh0 or 1) + ((p.sh1 or 1) - (p.sh0 or 1)) * ease
                Chips.addChip(B, p.x0 + (p.x1 - p.x0) * ease,
                                 p.y0 + (p.y1 - p.y0) * ease,
                                 p.d, a, p.label, tint, sh, partDepth(p, ease), p.rot, s, 1)
            end
        end
        Perf.count("pile_batch")
        e.batch_rev = nil   -- the next resting frame rebuilds from the record
        Chips.drawBatch(B, place.x, place.y, s)
        return
    end

    for _, p in ipairs(parts) do
        local a = partAlpha(p, ease)
        if p.base and a > 0.01 then
            drawShadowLocal(place,
                            p.x0 + (p.x1 - p.x0) * ease,
                            p.y0 + (p.y1 - p.y0) * ease, a)
        end
    end
    for _, p in ipairs(parts) do
        local a = partAlpha(p, ease)
        if a > 0.01 then
            local sh = (p.sh0 or 1) + ((p.sh1 or 1) - (p.sh0 or 1)) * ease
            drawChipLocal(place, tint,
                          p.x0 + (p.x1 - p.x0) * ease,
                          p.y0 + (p.y1 - p.y0) * ease,
                          p.d, a, p.label, sh, partDepth(p, ease), p.rot)
        end
    end
end

function ChipPile.draw(key)
    local e = _piles[key]
    if not e or not e.place then return end
    e.idle = 0
    local micro = e.place.detail == "micro"

    if e.frozen then
        drawRecord(e, key, frozenLayout(e), micro)
        return
    end
    if e.settle then
        drawSettle(e, key, micro)
        return
    end
    -- Settled chips only, laid out compactly. Airborne ones are drawn by
    -- their flight and are simply not in this layout, so the pile is
    -- always a solid stack — never a stack with slots punched out of it
    -- waiting to be filled. It shifts a little when an arrival tips a
    -- column over its limit, which reads as the stack making room.
    drawRecord(e, key, currentLayout(e), micro)
end

-- ── Lifecycle ───────────────────────────────────────────────────────
function ChipPile.update(dt)
    for key, e in pairs(_piles) do
        e.idle        = e.idle + dt
        e.want_age    = (e.want_age or math.huge) + dt
        e.since_take  = e.since_take + dt
        e.since_place = e.since_place + dt

        if e.settle then
            e.settle.t = e.settle.t + dt
            if e.settle.t >= e.settle.dur then
                touch(e)
                e.chips  = e.settle.chips
                e.settle = nil
            end
        end

        -- Re-derive how much is actually in the air, and land anything
        -- that has overstayed. This is what stops a single lost arrival
        -- from wedging the pile forever: the count can only be as large
        -- as the chips that are really still marked airborne, and none of
        -- them can stay marked for more than AIR_TTL.
        if e.n_air > 0 then
            local still = 0
            for _, c in ipairs(e.chips) do
                if c.air then
                    c.ttl = (c.ttl or AIR_TTL) - dt
                    if c.ttl <= 0 then c.air = nil; touch(e) else still = still + 1 end
                end
            end
            e.n_air = still
        end

        -- Reconcile toward the synced scalar, but only while quiet and
        -- only for a pile something is still drawing.
        if e.want and e.want_age <= SYNC_FRESH and e.n_air == 0 and not e.settle then
            if e.want <= 0 then
                if #e.chips > 0 then e.chips = {}; touch(e) end
                e.wrong_t = 0
            elseif #e.chips == 0 then
                -- An empty pile fills in one step; there is nothing to
                -- animate from. Except right after it paid out — those
                -- chips are still in the air and the scalar behind them
                -- has not caught up yet.
                if e.since_take > TAKE_LOCKOUT then
                    e.chips = ChipPile.compose(e.want, e.palette, e.tier, e.target)
                    touch(e)
                end
                e.wrong_t = 0
            else
                -- Tolerance is ONE of the smallest chip in the palette,
                -- not half. A breakdown's greedy fill always leaves a
                -- remainder smaller than that — a bankroll carrying a
                -- fraction of a cent, a stake palette whose smallest chip
                -- is $500 — and no arrangement of chips can ever close
                -- that gap. Anything under a chip is not a disagreement.
                local target = tierTarget(e)
                local tol    = smallestIn(e.palette) - EPS
                local pv     = pileValue(e)
                -- A pile as full as a composition gets cannot show more
                -- than it does: falling short of its scalar is not a
                -- disagreement for it (exceeding it still is).
                local saturated = #e.chips >= target * TIDY_FACTOR

                -- HARD CEILING. A pile may lag its scalar — that's the
                -- whole design, chips are the truth while they're moving
                -- — but it may never grossly EXCEED it. Anything that
                -- leaves chips behind (a hand boundary that doesn't
                -- clear, an arrival credited twice, a take that removed
                -- less than it sent) accumulates silently otherwise, and
                -- the debounced settle below is too polite to catch it:
                -- it waits, then animates, and the next hand's chips land
                -- on top before it finishes.
                --
                -- So a pile worth half again what it should be, or three
                -- times as many chips as its tier asks for, snaps. No
                -- debounce, no animation — it is already wrong on screen
                -- and the honest thing is to stop showing it.
                if pv > e.want * 1.5 + tol or #e.chips > target * CAP_FACTOR then
                    ChipPile.tidy(key, e.want, { instant = true, rebuild = true })
                    e.wrong_t = 0
                elseif pv > e.want + tol
                       or (pv < e.want - tol and not saturated)
                       or #e.chips > target * TIDY_FACTOR then
                    e.wrong_t = e.wrong_t + dt
                    if e.wrong_t >= RECONCILE_DELAY then
                        -- Too many chips is a shape problem and needs a
                        -- real recompose; being off by a chip's worth of
                        -- value only needs that chip.
                        ChipPile.tidy(key, e.want,
                                      { rebuild = (#e.chips > target * TIDY_FACTOR) })
                        e.wrong_t = 0
                    end
                else
                    e.wrong_t = 0
                end
            end
        else
            e.wrong_t = 0
        end

        -- Keys for closed tables stop being touched and go away. Nothing
        -- in flight is stranded: a late arrival fails the generation check.
        if e.idle > GC_SECONDS and e.n_air == 0 then
            dropBatch(e)
            _piles[key] = nil
            _n_piles = _n_piles - 1
        end
    end
end

-- Empty the pile but keep its placement — a new hand at the same table
-- draws in the same spot, so its batch stays too and is simply refilled.
-- Bumps the generation so chips still in the air toward the old contents
-- can't land in the new one.
function ChipPile.clear(key)
    local e = _piles[key]
    if not e then return end
    if #e.chips == 0 and e.n_air == 0 and not e.settle then return end
    e.chips      = {}
    e.n_air      = 0
    e.gen        = e.gen + 1
    e.settle     = nil
    e.wrong_t    = 0
    touch(e)
    -- An explicit clear is a statement that the pile is empty AND quiet,
    -- so the next value it is synced to can fill it in one step.
    e.since_take = math.huge
end

-- Drop one key now (a closed table's pot and stack), instead of waiting
-- GC_SECONDS for the sweep. Chips still in the air toward it fail the
-- generation check exactly as they do after the sweep. Its batch goes
-- with it.
function ChipPile.forget(key)
    local e = key and _piles[key]
    if not e then return end
    dropBatch(e)
    _piles[key] = nil
    _n_piles = _n_piles - 1
end

-- Does the registry hold this key (tests).
function ChipPile.has(key) return _piles[key] ~= nil end

-- The pile's revision (nil for a key never placed): bumped by every change
-- to what the pile holds or how it is laid out, so a cache of its picture
-- (the panel cache, views/TablePanel) can key on one number.
function ChipPile.rev(key)
    local e = _piles[key]
    return e and e.rev or nil
end

-- Is the pile's picture still: no settle playing, nothing in the air, not
-- frozen? Still, it can be painted once and blitted; moving, it is drawn
-- live over the blit. A key never placed is quiet (there is nothing to
-- draw).
function ChipPile.quiet(key)
    local e = _piles[key]
    if not e then return true end
    return not e.settle and e.n_air == 0 and not e.frozen
end

-- Drop everything. Call alongside FlightSystem.clear so a state teardown
-- can't leave a pile holding chips whose flights were just discarded.
function ChipPile.clearAll()
    for _, e in pairs(_piles) do dropBatch(e) end
    _piles = {}
    _n_piles = 0
end

return ChipPile
