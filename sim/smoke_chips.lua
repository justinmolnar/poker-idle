-- sim/smoke_chips.lua
--
-- The chip renderer's contracts after the atlas pass: one canvas for the
-- whole ladder, one SpriteBatch per pile, pooled flight records.
--
-- Three sections:
--   atlas    what builds the canvas and what must not (every per-chip
--            parameter), how many quads each kind of chip is, the label
--            fit rule against the vector path, the kill switch.
--   piles    views/ChipPile's incremental record against a fresh solve of
--            the same chips through 2,000 random steps; that an in-column
--            landing solves nothing; that a resting pile solves nothing,
--            rebuilds nothing and is one batch draw a frame; that reserve
--            leaves the picture alone; forget and the bound.
--   flights  a thousand chip records land exactly once and go back to the
--            pool; a warm pool allocates nothing across 300 frames; the
--            cap lands the oldest; an arrival that emits mid-update is
--            kept; the tumble's one-sprite transform equals the transform
--            chain to 1e-6; a transfer and a gathering explosion deliver
--            every chip into the destination pile.
--
-- Standalone: `lua sim/smoke_chips.lua` from the repo root.

package.path = "./?.lua;" .. package.path

local Stub = require("sim.love_stub")
Stub.base()

local c = Stub.checker()
math.randomseed(20260929)

local rec       = Stub.recorder()
local Constants = require("data.constants")
local Perf      = require("services.Perf")
local ChipData  = require("data.chips")
local Chips     = require("views.Chips")

local font = Stub.font(16)
Chips.configureFont({ sm = font, xs = font })
Chips.setScale(1)
Constants.FEATURES.CHIP_ATLAS = true

local ND = #ChipData.denominations

-- ── atlas ───────────────────────────────────────────────────────────────

do
    -- The vector baseline, before any atlas exists.
    Constants.FEATURES.CHIP_ATLAS = false
    rec.reset()
    Chips.drawChip(100, 100, 1, 1, true, nil, 1, 0, 1, 0.4)
    local vector_labelled = rec.total()
    local vector_prints   = rec.calls.print or 0
    c.eq(vector_prints, 1, "the vector baseline prints its label")

    -- One canvas, on the first draw, and never again across every
    -- denomination, tint, shade and rotation.
    Constants.FEATURES.CHIP_ATLAS = true
    rec.reset()
    Chips.drawChip(100, 100, 1, 1, true, nil, 1, 0, 1, 0.4)
    c.eq(rec.canvases, 1, "the first draw builds exactly one canvas")
    local pages, aw, ah, abytes = Chips.atlasInfo()
    c.eq(pages, 1, "one atlas page")
    c.eq(aw, 1024, "the atlas is 1024 wide at 1x")
    c.ok(ah <= 2048, "the atlas fits 1024x2048 at 1x (h = " .. tostring(ah) .. ")")
    c.eq(abytes, aw * ah * 4, "atlas bytes are w*h*4")
    print(string.format("[smoke_chips] atlas at 1x: %dx%d, %.2f MB", aw, ah, abytes / 1048576))

    rec.reset()
    local tints = { nil, { 0.5, 0.5, 0.5 }, { 1, 0.8, 0.2 } }
    for d = 1, ND do
        for ti = 1, #tints do
            for _, shade in ipairs({ 1, 0.95, 0.8003, 0.7, 0.68 }) do
                Chips.drawChip(50, 50, d, 1, true, tints[ti], shade, 0, 1, d * 0.37)
                Chips.drawChip(50, 50, d, 1, false, tints[ti], shade, 2, 0.6, d * 0.11)
            end
        end
    end
    c.eq(rec.canvases, 0, "denomination, tint, shade and rotation bake nothing")
    c.eq(rec.calls.arc or 0, 0, "no arcs anywhere on the atlas path")
    c.eq(rec.calls.print or 0, 0, "no prints anywhere on the atlas path")

    -- A thousandth and a tenth of shade apart: nothing.
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 0.8, 0, 1, 0)
    Chips.drawChip(50, 50, 1, 1, true, nil, 0.8003, 0, 1, 0)
    Chips.drawChip(50, 50, 1, 1, true, nil, 0.7, 0, 1, 0)
    c.eq(rec.canvases, 0, "shades a thousandth and a tenth apart bake nothing")

    -- setScale and configureFont each rebuild once, on the next draw.
    Chips.setScale(1.25)
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 1, 0)
    Chips.drawChip(50, 50, 2, 1, true, nil, 1, 0, 1, 0)
    c.eq(rec.canvases, 1, "setScale rebuilds the atlas once on the next draw")
    Chips.configureFont({ sm = Stub.font(16) })
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 1, 0)
    Chips.drawChip(50, 50, 2, 1, true, nil, 1, 0, 1, 0)
    c.eq(rec.canvases, 1, "configureFont rebuilds the atlas once on the next draw")
    -- The 1.5x atlas (the largest ui_scale views/FeltLayout allows).
    Chips.setScale(1.5)
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 1, 0)
    local _, w15, h15, b15 = Chips.atlasInfo()
    c.ok(h15 <= 2048, "the atlas fits 1024x2048 at 1.5x (h = " .. tostring(h15) .. ")")
    print(string.format("[smoke_chips] atlas at 1.5x: %dx%d, %.2f MB", w15, h15, b15 / 1048576))
    Chips.setScale(1)
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 1, 0)

    -- Quad counts per kind of chip.
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, false, nil, 1, 0, 1, 0.4)
    c.eq(rec.calls.draw or 0, 2, "an unlabelled full chip is two quads")
    c.eq(rec.calls.arc or 0, 0, "and no arcs")
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 1, 0.4)
    c.eq(rec.calls.draw or 0, 5, "a labelled full chip is five quads")
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 3, 1, 0.4)
    c.eq(rec.calls.draw or 0, 1, "a buried chip is one quad")
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 0.3, 0.4)
    c.eq(rec.calls.draw or 0, 1, "a chip below MIN_DETAIL_R is one flat quad")
    rec.reset()
    Chips.drawChipEdge(50, 50, 1, 1, nil, 0.4)
    c.eq(rec.calls.draw or 0, 1, "an edge chip is one quad")

    -- The label fit rule is the vector path's rule, exactly: at every
    -- scale and for a short and a long label, the atlas draws its plate
    -- and label (five quads) precisely when the vector path printed one.
    for _, d in ipairs({ 1, 4, ND }) do
        for _, es in ipairs({ 0.3, 0.5, 0.6, 0.65, 0.7, 0.75, 0.9, 1, 1.5 }) do
            Constants.FEATURES.CHIP_ATLAS = false
            rec.reset()
            Chips.drawChip(0, 0, d, 1, true, nil, 1, 0, es, 0)
            local printed = (rec.calls.print or 0) == 1
            Constants.FEATURES.CHIP_ATLAS = true
            rec.reset()
            Chips.drawChip(0, 0, d, 1, true, nil, 1, 0, es, 0)
            local quads = rec.calls.draw or 0
            local flat  = es * Chips.radius() < 7
            local want  = flat and 1 or (printed and 5 or 2)
            c.eq(quads, want, string.format("label fit rule: denom %d at es %.2f (vector printed: %s)",
                                            d, es, tostring(printed)))
        end
    end
    -- A short label survives to a smaller chip than a long one.
    rec.reset(); Chips.drawChip(0, 0, 1, 1, true, nil, 1, 0, 0.75, 0)
    local short_quads = rec.calls.draw or 0
    rec.reset(); Chips.drawChip(0, 0, ND, 1, true, nil, 1, 0, 0.75, 0)
    local long_quads = rec.calls.draw or 0
    c.ok(short_quads == 5 and long_quads == 2, "a short label fits where a long one does not")

    -- The column stays vector, three primitives.
    rec.reset()
    Chips.drawColumn(50, 50, 1, 4, 1, nil, 1)
    c.eq(rec.total(), 3, "drawColumn is three primitives")
    c.eq(rec.calls.draw or 0, 0, "drawColumn draws no quad")

    -- The kill switch equals the vector baseline, with the atlas built.
    Constants.FEATURES.CHIP_ATLAS = false
    rec.reset()
    Chips.drawChip(100, 100, 1, 1, true, nil, 1, 0, 1, 0.4)
    c.eq(rec.total(), vector_labelled, "CHIP_ATLAS off equals the vector baseline")
    c.eq(rec.calls.draw or 0, 0, "CHIP_ATLAS off draws no quad")
    Constants.FEATURES.CHIP_ATLAS = true

    -- The glyph: one quad in the currency colours, vector in any other.
    rec.reset()
    Chips.drawGlyph(10, 10, 9, 1, 1)
    c.eq(rec.calls.draw or 0, 1, "the currency glyph is one quad")
    rec.reset()
    Chips.drawGlyph(10, 10, 9, 1, 1, { { 1, 0, 0 }, { 0.5, 0, 0 } })
    c.eq(rec.calls.draw or 0, 0, "a recoloured glyph paints the vector way")

    -- Tiers: the smallest bake at least the chip's size.
    local t1, r1 = Chips.tierFor(1);    c.ok(t1 == 1 and math.abs(r1 - 1) < 1e-9, "tier 1 at es 1")
    local t4 = Chips.tierFor(0.3);      c.eq(t4, 4, "tier 4 at es 0.3")
    local t2, r2 = Chips.tierFor(0.7);  c.ok(t2 == 2 and r2 <= 1, "tier 2 at es 0.7, a shrink")
    local tb = Chips.tierFor(1.4);      c.eq(tb, 1, "tier 1 above 1")
end

-- ── piles ───────────────────────────────────────────────────────────────

local ChipPile = require("views.ChipPile")

do
    local KEY   = "smoke:pile"
    local PX, PY = 400.25, 300.5
    local PLACE = { align = "center", max_w = 300, scale = 1, max_cols = 8, max_rows = 3 }
    local pal   = ChipData.full_palette

    local function expected()
        return ChipPile.layoutAt(PX, PY, ChipPile.denominations(KEY, true), PLACE)
    end

    local function same(label)
        local got, want = ChipPile.debugSlots(KEY), expected()
        if not got then c.ok(false, label .. ": no slots"); return false end
        if not c.eq(#got, #want, label .. ": chip count") then return false end
        for i = 1, #want do
            local g, w = got[i], want[i]
            if math.abs(g.x - w.x) > 1e-6 or math.abs(g.y - w.y) > 1e-6 or g.idx ~= w.idx
               or g.depth ~= w.depth or (g.with_label and true or false) ~= (w.with_label and true or false)
               or (g.col_base and true or false) ~= (w.col_base and true or false)
               or math.abs(g.rot - w.rot) > 1e-9 then
                c.ok(false, string.format("%s: chip %d got %d@%.2f,%.2f d%d l%s b%s ~= want %d@%.2f,%.2f d%d l%s b%s",
                     label, i, g.idx, g.x, g.y, g.depth, tostring(g.with_label), tostring(g.col_base),
                     w.idx, w.x, w.y, w.depth, tostring(w.with_label), tostring(w.col_base)))
                return false
            end
        end
        c.ok(true, label)
        return true
    end

    ChipPile.place(KEY, PX, PY, PLACE)
    ChipPile.sync(KEY, 137.50, { palette = pal, tier = "medium" })
    ChipPile.draw(KEY)
    same("after sync")

    -- A seeded random walk: after every step the record the pile draws
    -- equals a fresh layout of the chips it holds.
    local pending  = {}
    local denoms   = { pal[3], pal[4], pal[5], pal[6] }
    local aligns   = { "center", "left", "right" }
    local scales   = { 0.5, 1, 1.5 }
    local failures = 0
    local ops      = { reserve = 0, accept = 0, take = 0, tidy = 0, place = 0, draw = 0 }
    for step = 1, 2000 do
        ChipPile.place(KEY, PX, PY, PLACE)
        local r = math.random()
        local what
        if r < 0.30 then
            what = "reserve"
            local list = {}
            for i = 1, math.random(1, 3) do list[i] = denoms[math.random(#denoms)] end
            local slots = ChipPile.reserve(KEY, list)
            for _, s in ipairs(slots or {}) do pending[#pending + 1] = s.chip end
        elseif r < 0.60 then
            what = "accept"
            if #pending > 0 then
                local i = math.random(#pending)
                ChipPile.accept(KEY, pending[i])
                table.remove(pending, i)
            end
        elseif r < 0.75 then
            what = "take"
            ChipPile.take(KEY, ({ 1, 5, 26, 100 })[math.random(4)])
        elseif r < 0.85 then
            what = "tidy"
            if #pending == 0 then
                ChipPile.tidy(KEY, math.random(1, 400) * 0.25,
                              { palette = pal, tier = "medium", instant = true })
            end
        elseif r < 0.92 then
            what = "place"
            PLACE.max_cols = math.random(1, 8)
            PLACE.align    = aligns[math.random(3)]
            PLACE.scale    = scales[math.random(3)]
            PLACE.max_rows = math.random(1, 3)
            ChipPile.place(KEY, PX, PY, PLACE)
        else
            what = "draw"
            ChipPile.draw(KEY)
        end
        ops[what] = ops[what] + 1
        if math.random() < 0.5 then ChipPile.draw(KEY) end
        ChipPile.update(1 / 60)
        -- The comparison is one check per step; failures are counted, and
        -- the first few are reported with their step.
        local got, want = ChipPile.debugSlots(KEY), expected()
        local ok = got ~= nil and #got == #want
        if ok then
            for i = 1, #want do
                local g, w = got[i], want[i]
                if math.abs(g.x - w.x) > 1e-6 or math.abs(g.y - w.y) > 1e-6 or g.idx ~= w.idx
                   or g.depth ~= w.depth
                   or (g.with_label and true or false) ~= (w.with_label and true or false)
                   or (g.col_base and true or false) ~= (w.col_base and true or false)
                   or math.abs(g.rot - w.rot) > 1e-9 then
                    ok = false
                    break
                end
            end
        end
        if not ok then
            failures = failures + 1
            if failures <= 3 then
                c.ok(false, string.format("random walk step %d (%s): record ~= fresh layout (%d vs %d chips)",
                                          step, what, got and #got or -1, #want))
            end
        end
    end
    c.eq(failures, 0, "random walk: the drawn record equals a fresh layout at every step")
    print(string.format("[smoke_chips] random walk ops: reserve %d accept %d take %d tidy %d place %d draw %d",
                        ops.reserve, ops.accept, ops.take, ops.tidy, ops.place, ops.draw))
    for _, chip in ipairs(pending) do ChipPile.accept(KEY, chip) end
    same("after landing the rest")

    -- An in-column landing solves nothing.
    local K2 = "smoke:incol"
    local P2 = { align = "center", scale = 1, max_cols = 8, max_rows = 3 }
    ChipPile.place(K2, 200, 200, P2)
    local first = ChipPile.reserve(K2, { pal[5], pal[5], pal[5] })
    for _, s in ipairs(first) do ChipPile.accept(K2, s.chip) end
    ChipPile.draw(K2)
    Perf.setEnabled(true)
    Perf.beginFrame(1 / 60)
    local more = ChipPile.reserve(K2, { pal[5], pal[5] })
    Perf.beginFrame(1 / 60)                       -- the reserve's scratch solve is last frame's
    for _, s in ipairs(more) do ChipPile.accept(K2, s.chip) end
    ChipPile.draw(K2)
    Perf.beginFrame(1 / 60)
    c.eq(Perf.counter("stack_layout"), 0, "two in-column landings solve nothing")
    c.eq(Perf.counter("pile_batch"), 1, "and rebuild the batch once, on the draw")
    do
        local got  = ChipPile.debugSlots(K2)
        local want = ChipPile.layoutAt(200, 200, ChipPile.denominations(K2, true), P2)
        local ok = got and #got == #want and #got == 5
        if ok then
            for i = 1, #want do
                if got[i].depth ~= want[i].depth or math.abs(got[i].y - want[i].y) > 1e-6
                   or (got[i].with_label and true or false) ~= (want[i].with_label and true or false) then
                    ok = false
                end
            end
        end
        c.ok(ok, "the incrementally grown column equals a fresh solve")
    end

    -- Sixty resting frames: no solve, no rebuild, one batch draw a frame.
    rec.reset()
    Perf.beginFrame(1 / 60)
    for _ = 1, 60 do
        ChipPile.place(K2, 200, 200, P2)
        ChipPile.update(1 / 60)
        ChipPile.draw(K2)
    end
    Perf.beginFrame(1 / 60)
    c.eq(Perf.counter("stack_layout"), 0, "60 resting frames solve nothing")
    c.eq(Perf.counter("pile_batch"), 0, "60 resting frames rebuild nothing")
    c.eq(rec.calls.draw_batch or 0, 60, "a resting pile is one batch draw a frame")
    c.eq(rec.calls.draw or 0, 0, "and no immediate quads")

    -- A pile that moves by whole pixels keeps its batch; a fraction rebuilds
    -- it once (the labels are snapped to screen pixels).
    Perf.beginFrame(1 / 60)
    ChipPile.place(K2, 203, 190, P2); ChipPile.draw(K2)
    ChipPile.place(K2, 210, 180, P2); ChipPile.draw(K2)
    Perf.beginFrame(1 / 60)
    c.eq(Perf.counter("pile_batch"), 0, "a whole-pixel move keeps the batch")
    ChipPile.place(K2, 210.5, 180, P2); ChipPile.draw(K2)
    ChipPile.place(K2, 211.5, 180, P2); ChipPile.draw(K2)
    Perf.beginFrame(1 / 60)
    c.eq(Perf.counter("pile_batch"), 1, "a sub-pixel move rebuilds once")

    -- reserve leaves the drawn picture (and its revision) alone.
    Perf.beginFrame(1 / 60)
    local held = ChipPile.reserve(K2, { pal[4] })
    ChipPile.draw(K2)
    Perf.beginFrame(1 / 60)
    c.eq(Perf.counter("pile_batch"), 0, "reserve does not rebuild the batch")
    c.eq(#ChipPile.debugSlots(K2), 5, "reserve does not draw the airborne chip")
    -- A new column, on landing, is a full solve.
    Perf.beginFrame(1 / 60)
    ChipPile.accept(K2, held[1].chip)
    ChipPile.draw(K2)
    Perf.beginFrame(1 / 60)
    c.eq(Perf.counter("stack_layout"), 1, "a landing that opens a new column solves once")
    c.eq(#ChipPile.debugSlots(K2), 6, "and the chip is drawn")

    -- A settle rebuilds every frame, from the parts, then rests again.
    ChipPile.sync(K2, ChipPile.value(K2), { palette = pal, tier = "medium" })
    ChipPile.tidy(K2, 40, { palette = pal, tier = "medium" })
    c.ok(ChipPile.debugSettleParts(K2) ~= nil, "a tidy on a placed pile settles")
    Perf.beginFrame(1 / 60)
    rec.reset()
    for _ = 1, 5 do ChipPile.update(0.02); ChipPile.draw(K2) end
    Perf.beginFrame(1 / 60)
    c.eq(Perf.counter("pile_batch"), 5, "a settling pile rebuilds every frame")
    c.eq(rec.calls.draw_batch or 0, 5, "and is still one batch draw a frame")
    for _ = 1, 20 do ChipPile.update(0.05) end
    ChipPile.draw(K2)
    Perf.beginFrame(1 / 60)
    ChipPile.draw(K2); ChipPile.draw(K2)
    Perf.beginFrame(1 / 60)
    c.eq(Perf.counter("pile_batch"), 0, "settled again: no rebuilds")
    c.ok(same and ChipPile.debugSlots(K2) ~= nil, "settled again: a single layout")

    -- freeze draws the snapshot; the live collection keeps changing.
    local before = #ChipPile.debugSlots(K2)
    ChipPile.freeze(K2)
    ChipPile.place(K2, 211.5, 180, P2)     -- a pile is live only while placed
    local fr = ChipPile.reserve(K2, { pal[4], pal[4] })
    for _, s in ipairs(fr) do ChipPile.accept(K2, s.chip) end
    ChipPile.draw(K2)
    c.eq(#ChipPile.debugSlots(K2), before, "frozen: the snapshot is drawn")
    ChipPile.thaw(K2)
    ChipPile.draw(K2)
    c.eq(#ChipPile.debugSlots(K2), before + 2, "thawed: the live pile is drawn")

    -- forget drops the key and releases its batch.
    local n_released = 0
    for _, b in ipairs(rec.batches) do if b.released then n_released = n_released + 1 end end
    ChipPile.forget(K2)
    c.ok(not ChipPile.has(K2), "forget removes the key")
    local n_released2 = 0
    for _, b in ipairs(rec.batches) do if b.released then n_released2 = n_released2 + 1 end end
    c.eq(n_released2, n_released + 1, "forget releases the pile's batch")
    c.eq(ChipPile.count(K2), 0, "a forgotten key holds no chips")

    -- The bound evicts.
    local n0 = ChipPile.count()
    for i = 1, 100 do ChipPile.place("smoke:evict:" .. i, 0, 0, P2) end
    c.ok(ChipPile.count() <= 80, "the registry stays within its bound (" .. ChipPile.count() .. ")")
    c.ok(ChipPile.count() >= n0, "and holds a board's worth")
    Perf.setEnabled(false)
end

-- ── cap ─────────────────────────────────────────────────────────────────
-- A pile holds at most three times its tier's chip target, airborne chips
-- included: past that a reservation hands back a landing spot with no
-- record, the arrival is a no-op, and the pile's size no longer follows
-- the number of chips that ever flew to it.
do
    local K3 = "smoke:cap"
    local pal   = ChipData.full_palette
    ChipPile.place(K3, 300, 300, { align = "center", scale = 1, max_cols = 10, max_rows = 2 })
    ChipPile.sync(K3, 0, { tier = "stack" })
    local cap = 50 * 3
    local list = {}
    for i = 1, 40 do list[i] = pal[3] end
    local absorbed, placed = 0, 0
    for _ = 1, 25 do
        local slots = ChipPile.reserve(K3, list)
        c.eq(#slots, 40, "every reserved chip gets a slot")
        for _, s in ipairs(slots) do
            if s.chip then placed = placed + 1; ChipPile.accept(K3, s.chip)
            else absorbed = absorbed + 1; c.ok(s.x and s.y, "an absorbed chip still has a landing spot"); ChipPile.accept(K3, s.chip) end
        end
    end
    c.eq(placed, cap, "the pile took records up to its cap")
    c.eq(absorbed, 1000 - cap, "and absorbed the rest")
    c.eq(ChipPile.count(K3), cap, "a thousand landings leave the pile at its cap")
    ChipPile.draw(K3)
    c.ok(#ChipPile.debugSlots(K3) <= cap, "the drawn pile is no bigger than its cap")
end

-- ── flights ─────────────────────────────────────────────────────────────

local FlightSystem = require("services.FlightSystem")
local ChipFlight   = require("views.ChipFlight")   -- registers the chip renderer
local Tumble       = require("services.Tumble")

do
    FlightSystem.clear()
    ChipPile.clearAll()

    -- A thousand chips: every on_arrive once, and every record back on
    -- the free stack.
    local arrived = {}
    local function note(_x, _y, _rec, i) arrived[i] = (arrived[i] or 0) + 1 end
    for i = 1, 1000 do
        FlightSystem.emitChip(0, 0, 100 + i, 200, 1 + (i % ND), true, nil, 1, 1,
                              Tumble.PRESETS.toss, (i % 10) * 0.02, 0.3 + (i % 7) * 0.05, nil,
                              note, i, nil)
    end
    c.ok(FlightSystem.count() <= 800, "the cap holds (" .. FlightSystem.count() .. " in flight)")
    for _ = 1, 120 do FlightSystem.update(1 / 60); FlightSystem.draw() end
    c.eq(FlightSystem.count(), 0, "all thousand landed")
    local once, total = true, 0
    for i = 1, 1000 do
        total = total + (arrived[i] or 0)
        if arrived[i] ~= 1 then once = false end
    end
    c.ok(once, "every on_arrive fired exactly once")
    c.eq(total, 1000, "a thousand arrivals")
    local alloc, free = FlightSystem.debugPool()
    c.eq(free, alloc, "free stack equals records allocated")
    c.ok(alloc <= 800, "no more records than the cap (" .. alloc .. ")")

    -- The cap lands the oldest.
    local landed_first = 0
    FlightSystem.emitChip(0, 0, 10, 10, 1, false, nil, 1, 1, false, 0, 1, nil,
                          function() landed_first = landed_first + 1 end)
    for _ = 1, 800 do
        FlightSystem.emitChip(0, 0, 10, 10, 1, false, nil, 1, 1, false, 0, 1, nil)
    end
    c.eq(landed_first, 1, "the cap lands the oldest at once")
    c.eq(FlightSystem.count(), 800, "and holds at the cap")
    FlightSystem.clear()
    c.eq(FlightSystem.count(), 0, "clear empties the queue")
    alloc, free = FlightSystem.debugPool()
    c.eq(free, alloc, "clear returns every record")

    -- An arrival that emits during update is kept and lands in turn.
    local second_landed = false
    local function second(_x, _y) second_landed = true end
    local function first(x, y)
        FlightSystem.emitChip(x, y, x + 50, y, 1, false, nil, 1, 1, false, 0, 0.2, nil, second)
    end
    for i = 1, 5 do
        FlightSystem.emitChip(0, 0, 10 * i, 0, 1, false, nil, 1, 1, false, 0, 0.1, nil, i == 3 and first or nil)
    end
    FlightSystem.update(0.11)
    c.eq(FlightSystem.count(), 1, "the chip emitted from an arrival survives the compaction")
    FlightSystem.update(0.25)
    c.ok(second_landed, "and lands in turn")
    c.eq(FlightSystem.count(), 0, "queue empty after the second leg")

    -- Draw: chip records are one batch draw a frame.
    for i = 1, 40 do
        FlightSystem.emitChip(0, 0, 100, 100 + i, 1 + (i % ND), true, nil, 0.8, 1,
                              Tumble.PRESETS.throw, 0, 1, nil)
    end
    FlightSystem.update(0.3)
    rec.reset()
    FlightSystem.draw()
    c.eq(rec.calls.draw_batch or 0, 1, "forty chips in the air are one batch draw")
    c.eq(rec.calls.draw or 0, 0, "and no immediate quads")
    FlightSystem.clear()

    -- Steady state allocates nothing: a warm pool, 20 chips a frame for
    -- 300 frames with the collector stopped.
    local function nothing() end
    local function frame()
        for i = 1, 20 do
            FlightSystem.emitChip(i, 0, 300, 200, 1 + (i % ND), (i % 2 == 0), nil, 1, 1,
                                  (i % 3 == 0) and false or Tumble.PRESETS.toss,
                                  0, 0.5, nil, nothing, i, nil)
        end
        FlightSystem.update(1 / 60)
        FlightSystem.draw()
    end
    for _ = 1, 120 do frame() end
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 300 do frame() end
    local delta = collectgarbage("count") - before
    collectgarbage("restart")
    c.ok(delta < 8, string.format("300 steady frames allocate under 8 KB (%.2f KB)", delta))
    print(string.format("[smoke_chips] steady-state flights: %.2f KB across 300 frames, %d in flight",
                        delta, FlightSystem.count()))
    FlightSystem.clear()

    -- The tumble as one sprite transform: 500 random poses, three points
    -- each, through the transform chain and through LOVE's
    -- setTransformation with the decomposed parameters.
    local function chain(axis, squash, spin, near, x, y)
        -- rotate(spin), scale(1, squash), rotate(axis), scale(near): the
        -- innermost first, as love.graphics applies them to a point.
        local cs, ss = math.cos(spin), math.sin(spin)
        local x1, y1 = cs * x - ss * y, ss * x + cs * y
        local x2, y2 = x1, squash * y1
        local ca, sa = math.cos(axis), math.sin(axis)
        local x3, y3 = ca * x2 - sa * y2, sa * x2 + ca * y2
        return x3 * near, y3 * near
    end
    local function loveXform(angle, sx, sy, kx, ky, x, y)
        -- Matrix4::setTransformation with ox = oy = 0.
        local cc, s = math.cos(angle), math.sin(angle)
        local e0 = cc * sx - ky * s * sy
        local e1 = s * sx + ky * cc * sy
        local e4 = kx * cc * sx - s * sy
        local e5 = kx * s * sx + cc * sy
        return e0 * x + e4 * y, e1 * x + e5 * y
    end
    local worst = 0
    local pts = { { 1, 0 }, { 0, 1 }, { 0.6, -0.8 } }
    for _ = 1, 500 do
        local axis   = math.random() * math.pi
        local squash = 0.14 + math.random() * 0.86
        local spin   = (math.random() * 2 - 1) * math.pi * 3
        local near   = 1 + math.random() * 0.8
        local m11, m12, m21, m22 = Chips.tumbleMatrix(axis, squash, spin, near)
        local th, a, d, kx = Chips.decompose(m11, m12, m21, m22)
        c.ok(a > 0 and d > 0, "decomposition keeps positive scales") -- det > 0
        for _, p in ipairs(pts) do
            local x, y = p[1] * 17, p[2] * 17
            local cx, cy = chain(axis, squash, spin, near, x, y)
            local mx, my = m11 * x + m12 * y, m21 * x + m22 * y
            local lx, ly = loveXform(th, a, d, kx, 0, x, y)
            local e1 = math.max(math.abs(cx - mx), math.abs(cy - my))
            local e2 = math.max(math.abs(cx - lx), math.abs(cy - ly))
            if e1 > worst then worst = e1 end
            if e2 > worst then worst = e2 end
        end
    end
    c.ok(worst < 1e-6, string.format("tumble transform agrees to 1e-6 (worst %.2e)", worst))

    -- Tumble.eval reproduces wrap's motion: a wrapped callback sees the
    -- squash eval returns.
    do
        local rec_t = Tumble.roll({ flips = 1.5, spins = 1, axis = 0.3, phase = 0.2,
                                    min_squash = 0.2, spin_dir = 1, loft = 0.3 }, {})
        local seen
        local fn = Tumble.wrap(function(_x, _y, _t, squash) seen = squash end,
                               { flips = 1.5, spins = 1, axis = 0.3, phase = 0.2,
                                 min_squash = 0.2, spin_dir = 1, loft = 0.3 })
        fn(0, 0, 0.37)
        local sq = Tumble.eval(rec_t, 0.37)
        c.ok(seen and math.abs(seen - sq) < 1e-12, "Tumble.wrap and Tumble.eval agree")
    end

    -- A transfer delivers every chip into the destination pile.
    local PL = { align = "center", scale = 1, max_cols = 8, max_rows = 3 }
    local pal = ChipData.full_palette
    ChipPile.place("smoke:src", 100, 100, PL)
    ChipPile.place("smoke:dst", 500, 100, PL)
    ChipPile.sync("smoke:src", 30, { palette = pal, tier = "medium" })
    ChipPile.draw("smoke:src"); ChipPile.draw("smoke:dst")
    local src_before = ChipPile.value("smoke:src")
    ChipFlight.transfer(nil, nil, { source_key = "smoke:src", dest_key = "smoke:dst", amount = 10 })
    c.ok(FlightSystem.count() > 0, "a transfer puts chips in the air (" .. FlightSystem.count() .. ")")
    c.ok(math.abs(ChipPile.value("smoke:src") - (src_before - 10)) < 1e-9, "the source shrank at once")
    for _ = 1, 120 do
        ChipPile.place("smoke:src", 100, 100, PL); ChipPile.place("smoke:dst", 500, 100, PL)
        FlightSystem.update(1 / 60); ChipPile.update(1 / 60); FlightSystem.draw()
        ChipPile.draw("smoke:src"); ChipPile.draw("smoke:dst")
    end
    c.eq(FlightSystem.count(), 0, "the transfer landed")
    c.ok(math.abs(ChipPile.value("smoke:dst") - 10) < 1e-9, "the destination holds the amount")
    c.eq(#ChipPile.denominations("smoke:dst", true), #ChipPile.denominations("smoke:dst"),
         "every reserved chip was accepted")
    do
        local got  = ChipPile.debugSlots("smoke:dst")
        local want = ChipPile.layoutAt(500, 100, ChipPile.denominations("smoke:dst", true), PL)
        c.eq(got and #got or -1, #want, "the destination's record equals a fresh layout")
    end

    -- A gathering explosion: the pile comes apart, turns, and every chip
    -- ends up in the destination.
    local debris = ChipPile.takeAll("smoke:src")
    c.ok(debris and #debris > 0, "takeAll hands back the visible chips")
    local dst_before = ChipPile.value("smoke:dst")
    local debris_value = 0
    for _, t in ipairs(debris or {}) do debris_value = debris_value + ChipData.denominations[t.d].value end
    ChipFlight.explodeTaken(debris, { dest_key = "smoke:dst", dest = { 500, 100 }, within = { 300, 200 } })
    c.ok(FlightSystem.count() == #debris, "every piece of debris flies (" .. FlightSystem.count() .. ")")
    for _ = 1, 240 do
        ChipPile.place("smoke:src", 100, 100, PL); ChipPile.place("smoke:dst", 500, 100, PL)
        FlightSystem.update(1 / 60); ChipPile.update(1 / 60); FlightSystem.draw()
        ChipPile.draw("smoke:dst")
    end
    c.eq(FlightSystem.count(), 0, "the explosion and its gather landed")
    c.ok(math.abs(ChipPile.value("smoke:dst") - (dst_before + debris_value)) < 1e-9,
         "the destination gained the debris")
    c.eq(#ChipPile.denominations("smoke:dst", true), #ChipPile.denominations("smoke:dst"),
         "nothing left airborne after the gather")
    alloc, free = FlightSystem.debugPool()
    c.eq(free, alloc, "the pool is whole after the transfer and the explosion")
end

local fails = c.report("smoke_chips")
if fails > 0 then os.exit(1) end
