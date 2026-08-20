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

local Chips    = require("views.Chips")
local Denoms   = require("services.DenominationBreakdown")
local ChipData = require("data.chips")

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
local EPS             = 1e-9

-- ── Helpers ─────────────────────────────────────────────────────────
local function denomValue(d)
    local e = ChipData.denominations[d]
    return (e and e.value) or 0
end

local function entry(key)
    local e = _piles[key]
    if not e then
        e = { chips = {}, n_air = 0, gen = 1, idle = 0, wrong_t = 0,
              since_take = math.huge, since_place = math.huge }
        _piles[key] = e
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

-- Flat denomination-index list, which is what Chips.stackLayout eats,
-- plus the e.chips index each entry came from.
--
-- `settled_only` drops airborne chips. That's what the pile DRAWS: a
-- chip that hasn't landed yet has no business occupying a slot, and
-- holding one open leaves a gap in the stack that reads as a rendering
-- fault rather than as anticipation. The full list is still what an
-- ARRIVAL is measured against — a chip in the air needs to know where it
-- will sit once it's part of the pile.
local function denomList(e, settled_only)
    local list, from = {}, {}
    for i, c in ipairs(e.chips) do
        if not (settled_only and c.air) then
            list[#list + 1] = c.d
            from[#list]     = i
        end
    end
    return list, from
end

-- Same chips in the same order? Breakdown is deterministic, so a straight
-- sequence compare is enough to answer "is this pile already tidy".
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
local function layoutLocal(chip_indices, place)
    if not place then return {} end
    local s  = place.scale or 1
    local mw = place.max_w
    if mw and s ~= 1 then mw = mw / s end
    return Chips.stackLayout(0, 0, chip_indices, {
        align    = place.align or "center",
        max_w    = mw,
        -- Column caps are in COLUMNS, not pixels, so unlike max_w they do
        -- not get divided by the scale.
        max_cols = place.max_cols,
        max_rows = place.max_rows,
    })
end

local function toScreen(place, lx, ly)
    local s = place.scale or 1
    return place.x + lx * s, place.y + ly * s
end

-- Screen-space slot per position in e.chips. Positions clipped out by the
-- max_w budget simply have no entry.
--
-- `settled_only` picks which layout to measure against: where chips are
-- actually DRAWN right now (departures), or where they will sit once
-- everything in the air has landed (arrivals).
local function slotsByPos(e, settled_only)
    local out = {}
    if not e.place then return out end
    local list, from = denomList(e, settled_only)
    for _, p in ipairs(layoutLocal(list, e.place)) do
        if p.src and from[p.src] then
            local sx, sy = toScreen(e.place, p.x, p.y)
            out[from[p.src]] = { x = sx, y = sy, with_label = p.with_label }
        end
    end
    return out
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
end

-- ── Public: layout for callers with no pile ─────────────────────────
-- Same origin-then-transform rule, exposed for one-shot piles that were
-- never registered here (views/ChipFlight.explodeStack lays out a
-- breakdown it was handed). Returns screen-space { x, y, idx, with_label }.
function ChipPile.layoutAt(x, y, chip_indices, opts)
    opts = opts or {}
    local place = {
        x = x, y = y,
        align = opts.align, max_w = opts.max_w, scale = opts.scale or 1,
        max_cols = opts.max_cols, max_rows = opts.max_rows,
    }
    local placed = layoutLocal(chip_indices, place)
    for _, p in ipairs(placed) do
        p.x, p.y = toScreen(place, p.x, p.y)
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
    e.place = {
        x = x, y = y,
        align = opts.align or "center",
        max_w = opts.max_w,
        scale = opts.scale or 1,
        -- How wide/deep this pile may grow, in columns. The caller knows
        -- what its pile would run into; the pile does not.
        max_cols = opts.max_cols,
        max_rows = opts.max_rows,
    }
    e.tint        = opts.tint
    e.since_place = 0
end

function ChipPile.scale(key)
    local e = _piles[key]
    return (e and e.place and e.place.scale) or 1
end

function ChipPile.count(key)
    local e = _piles[key]
    return e and #e.chips or 0
end

-- The in-progress settle's parts, or nil when the pile is at rest. A read
-- seam for measuring how far a settle actually moves chips.
function ChipPile.debugSettleParts(key)
    local e = _piles[key]
    return e and e.settle and e.settle.parts or nil
end

-- The denominations this pile currently holds, in order. A read-only view
-- for anything that needs to reason about the pile's composition rather
-- than just its total.
function ChipPile.denominations(key)
    local e = _piles[key]
    if not e then return {} end
    local out = {}
    for i, c in ipairs(e.chips) do out[i] = c.d end
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
    e.want_age = 0

    if #e.chips == 0 and e.n_air == 0 and not e.settle and value > 0
       and e.since_take > TAKE_LOCKOUT then
        e.chips = ChipPile.compose(value, e.palette, e.tier)
        e.wrong_t = 0
    end
end

-- Breakdown → the chip records this module stores.
function ChipPile.compose(value, palette, tier)
    local list = Denoms.breakdown(value, ChipData.denominations,
                                  palette or ChipData.full_palette,
                                  ChipData.tier_chip_target, tier or "medium")
    local out = {}
    for i, d in ipairs(list) do out[i] = { d = d } end
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
        target = ChipPile.compose(value, palette, tier)
    else
        target = adjustToward(e, value, palette)
              or ChipPile.compose(value, palette, tier)
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

    if not e.place or opts.instant then
        e.chips = target
        return
    end

    local target_denoms = {}
    for i, c in ipairs(target) do target_denoms[i] = c.d end

    local from = layoutLocal(denomList(e, true), e.place)
    local to   = layoutLocal(target_denoms, e.place)

    -- Pair by denomination, NEAREST FIRST: a $5 already on the felt slides
    -- to the closest place a $5 is wanted. Only the surplus fades.
    --
    -- This used to pop the last source off the list for the first target,
    -- which paired the two lists in opposite orders — the chip on the far
    -- right was sent to the far left and vice versa. Every settle therefore
    -- dealt the pile out again, and three identical stacks visibly traded
    -- places while being, chip for chip, exactly what they were before.
    -- Nothing about the pile had changed; the animation moved them anyway.
    local pool = {}
    for _, p in ipairs(from) do
        local b = pool[p.idx]
        if not b then b = {}; pool[p.idx] = b end
        b[#b + 1] = p
    end

    -- Closest unclaimed source of this denomination, or nil if none is left.
    local function takeNearest(idx, tx, ty)
        local b = pool[idx]
        if not b or #b == 0 then return nil end
        local best, best_d2 = nil, math.huge
        for i, p in ipairs(b) do
            local dx, dy = p.x - tx, p.y - ty
            local d2 = dx * dx + dy * dy
            if d2 < best_d2 then best, best_d2 = i, d2 end
        end
        return table.remove(b, best)
    end

    local parts = {}
    for _, p in ipairs(to) do
        local src = takeNearest(p.idx, p.x, p.y)
        parts[#parts + 1] = {
            d     = p.idx,
            label = p.with_label,
            x0    = src and src.x or p.x,
            y0    = src and src.y or p.y,
            x1    = p.x, y1 = p.y,
            mode  = src and "move" or "in",
            -- A settling chip can change depth on the way. Interpolating
            -- the shade is what stops the whole pile flattening for the
            -- settle and popping back at the end.
            sh0   = (src and src.shade) or p.shade,
            sh1   = p.shade,
            depth = p.depth,
            base  = p.col_base,
            rot   = p.rot,
        }
    end
    for _, b in pairs(pool) do
        for _, p in ipairs(b) do
            parts[#parts + 1] = {
                d     = p.idx,
                label = p.with_label,
                x0    = p.x, y0 = p.y,
                x1    = p.x, y1 = p.y,
                mode  = "out",
                sh0   = p.shade, sh1 = p.shade,
                depth = p.depth,
                base  = p.col_base,
                rot   = p.rot,
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
            return true
        end
    end
    return false
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
    local slots = slotsByPos(e, true)
    local taken = {}
    for i = #e.chips, 1, -1 do
        local c = e.chips[i]
        if mark[c] then
            local s = slots[i]
            table.insert(taken, 1, {
                d = c.d,
                x = s and s.x or (e.place and e.place.x),
                y = s and s.y or (e.place and e.place.y),
            })
            table.remove(e.chips, i)
        end
    end
    e.wrong_t    = 0
    e.since_take = 0
    if #taken == 0 then return nil end
    return taken
end

-- Everything VISIBLE, for a pile that is coming apart rather than paying
-- out (the jackpot detonation). Same return shape as take.
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
    local slots = slotsByPos(e, true)
    local taken = {}
    for i, c in ipairs(e.chips) do
        if not c.air then
            local s = slots[i]
            taken[#taken + 1] = {
                d = c.d,
                x = s and s.x or (e.place and e.place.x),
                y = s and s.y or (e.place and e.place.y),
            }
        end
    end
    if #taken == 0 then return nil end
    ChipPile.clear(key)
    e.since_take = 0
    return taken
end

-- ── Reserve / accept: chips arrive at this pile ─────────────────────
-- reserve() appends the incoming chips and marks them airborne. They
-- occupy their slots in the LAYOUT immediately — so the chips already on
-- the felt sit where they will still be sitting once the flight lands —
-- but draw() skips them, leaving a hole. The flight fills that hole at
-- exactly the pixel it ends on.
--
-- Returns { { chip, x, y, with_label }, ... }, one per requested chip.
-- Hand `chip` back to accept() from the flight's on_arrive.
function ChipPile.reserve(key, denom_indices)
    if not denom_indices or #denom_indices == 0 then return nil end
    local e = live(key)
    if not e then return nil end
    e.idle = 0
    finishSettle(e)

    local base = #e.chips
    local refs = {}
    for i, d in ipairs(denom_indices) do
        local c = { d = d, air = true, gen = e.gen, ttl = AIR_TTL }
        e.chips[base + i] = c
        refs[i] = c
    end
    e.n_air   = e.n_air + #refs
    e.wrong_t = 0

    -- Measured against the FULL layout: an arriving chip aims for where
    -- it will sit once everything in the air has landed, so it doesn't
    -- have to shuffle after touching down.
    local slots = slotsByPos(e, false)
    local out   = {}
    for i, c in ipairs(refs) do
        local s = slots[base + i]
        out[i] = {
            chip       = c,
            x          = s and s.x,
            y          = s and s.y,
            with_label = s and s.with_label,
        }
    end
    return out
end

-- The chip has landed. A chip whose generation no longer matches (its
-- pile was cleared, or the table closed and the key was recycled) is
-- silently dropped — it belongs to a pile that no longer exists.
function ChipPile.accept(key, chip)
    local e = _piles[key]
    if not e or not chip or not chip.air then return end
    if chip.gen ~= e.gen then return end
    chip.air = nil
    e.n_air  = math.max(0, e.n_air - 1)
    e.idle   = 0
end

-- ── Draw ────────────────────────────────────────────────────────────
function ChipPile.draw(key)
    local e = _piles[key]
    if not e or not e.place then return end
    e.idle = 0
    local place, tint = e.place, e.tint

    -- Shadows are their own pass, always. One is wider than the chip it
    -- belongs to and columns sit two pixels apart, so interleaved they
    -- would land on the neighbouring column's chips.
    if e.settle then
        local k = math.min(1, e.settle.t / e.settle.dur)
        local ease = k * k * (3 - 2 * k)
        local function partAlpha(p)
            if p.mode == "in"  then return ease end
            if p.mode == "out" then return 1 - ease end
            return 1
        end
        for _, p in ipairs(e.settle.parts) do
            local a = partAlpha(p)
            -- A shadow at full strength under a chip fading out is a
            -- smudge with nothing on top of it.
            if p.base and a > 0.01 then
                drawShadowLocal(place,
                                p.x0 + (p.x1 - p.x0) * ease,
                                p.y0 + (p.y1 - p.y0) * ease, a)
            end
        end
        for _, p in ipairs(e.settle.parts) do
            local a = partAlpha(p)
            if a > 0.01 then
                local sh = (p.sh0 or 1) + ((p.sh1 or 1) - (p.sh0 or 1)) * ease
                drawChipLocal(place, tint,
                              p.x0 + (p.x1 - p.x0) * ease,
                              p.y0 + (p.y1 - p.y0) * ease,
                              p.d, a, p.label, sh, p.depth, p.rot)
            end
        end
        return
    end

    -- Settled chips only, laid out compactly. Airborne ones are drawn by
    -- their flight and are simply not in this layout, so the pile is
    -- always a solid stack — never a stack with slots punched out of it
    -- waiting to be filled. It shifts a little when an arrival tips a
    -- column over its limit, which reads as the stack making room.
    local placed = layoutLocal(denomList(e, true), place)
    for _, p in ipairs(placed) do
        if p.col_base then drawShadowLocal(place, p.x, p.y, 1) end
    end
    for _, p in ipairs(placed) do
        drawChipLocal(place, tint, p.x, p.y, p.idx, 1, p.with_label,
                      p.shade, p.depth, p.rot)
    end
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
                    if c.ttl <= 0 then c.air = nil else still = still + 1 end
                end
            end
            e.n_air = still
        end

        -- Reconcile toward the synced scalar, but only while quiet and
        -- only for a pile something is still drawing.
        if e.want and e.want_age <= SYNC_FRESH and e.n_air == 0 and not e.settle then
            if e.want <= 0 then
                if #e.chips > 0 then e.chips = {} end
                e.wrong_t = 0
            elseif #e.chips == 0 then
                -- An empty pile fills in one step; there is nothing to
                -- animate from. Except right after it paid out — those
                -- chips are still in the air and the scalar behind them
                -- has not caught up yet.
                if e.since_take > TAKE_LOCKOUT then
                    e.chips = ChipPile.compose(e.want, e.palette, e.tier)
                end
                e.wrong_t = 0
            else
                -- Tolerance is ONE of the smallest chip in the palette,
                -- not half. A breakdown's greedy fill always leaves a
                -- remainder smaller than that — a bankroll carrying a
                -- fraction of a cent, a stake palette whose smallest chip
                -- is $500 — and no arrangement of chips can ever close
                -- that gap. Anything under a chip is not a disagreement.
                local target = (ChipData.tier_chip_target[e.tier or "medium"]) or 12
                local tol    = smallestIn(e.palette) - EPS
                local pv     = pileValue(e)

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
                if pv > e.want * 1.5 + tol or #e.chips > target * 3 then
                    ChipPile.tidy(key, e.want, { instant = true, rebuild = true })
                    e.wrong_t = 0
                elseif math.abs(pv - e.want) > tol
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
            _piles[key] = nil
        end
    end
end

-- Empty the pile but keep its placement — a new hand at the same table
-- draws in the same spot. Bumps the generation so chips still in the air
-- toward the old contents can't land in the new one.
function ChipPile.clear(key)
    local e = _piles[key]
    if not e then return end
    if #e.chips == 0 and e.n_air == 0 and not e.settle then return end
    e.chips      = {}
    e.n_air      = 0
    e.gen        = e.gen + 1
    e.settle     = nil
    e.wrong_t    = 0
    -- An explicit clear is a statement that the pile is empty AND quiet,
    -- so the next value it is synced to can fill it in one step.
    e.since_take = math.huge
end

-- Drop everything. Call alongside FlightSystem.clear so a state teardown
-- can't leave a pile holding chips whose flights were just discarded.
function ChipPile.clearAll()
    _piles = {}
end

return ChipPile
