-- sim/smoke_views.lua
--
-- The view and service checks the optimization pass was verified against.
--
-- Everything here guards a CACHE or a BAKE: a stored result standing in for
-- work that used to be redone every frame. That is the whole risk of the
-- pass. A cache is wrong in one of two ways — it serves a stale answer when
-- an input changed, or it rebuilds when nothing did — and neither shows up
-- in the engine suite, which never draws. So each section computes the
-- answer twice, once through the cache and once the long way, and compares.
--
-- Four sections:
--   text     IconText measure/wrap/spans and services/Memo — a cached
--            answer must equal a fresh one, and two fonts, two option sets
--            or two widths must never share an entry.
--   chips    The chip face atlas: what bakes, what reuses a bake, what
--            invalidates one, and that the feature flag still restores the
--            vector path exactly.
--   pile     views/ChipPile draws the same chips in the same order and at
--            the same positions as its own layout helper computes fresh,
--            across sync / move / tidy / take / reserve / accept / clear.
--   screens  every state builds and draws two frames, which is the only
--            check that runs a view's draw at all.
--   save     services/SaveService with love.thread absent (the web build):
--            one versioned file, staged and verified, with a backup to fall
--            back to; a foreign version refused without latching; an
--            unreadable one latching so nothing overwrites it.
--
-- Standalone: `lua sim/smoke_views.lua` from the repo root.

package.path = "./?.lua;" .. package.path

local Stub = require("sim.love_stub")
Stub.base()

local c = Stub.checker()

-- ── text: IconText caches and services/Memo ─────────────────────────────

do
    local IconText = require("views.IconText")
    local Memo     = require("services.Memo")

    local f1, f2 = Stub.font(16), Stub.font(8)
    local strings = {
        "plain words here",
        "Win {chip} now",
        "1 in 4 chance of {w:stack}",
        "+$1,234.56 {l:large}",
        "{c:heat:heater} spreads to {k:6-Max} tables",
        "×2 payout and +15% odds",
        "",
        "{achip}{arrow}{chip}",
    }

    -- A repeated measure must be stable, per font and per option set, and
    -- the span list behind it must not be corrupted by the shared parse.
    for _, font in ipairs({ f1, f2 }) do
        for _, plain in ipairs({ false, true }) do
            local o = plain and IconText.PLAIN or nil
            for _, s in ipairs(strings) do
                local first = IconText.measure(s, font, o)
                c.eq(first, IconText.measure(s, font, o), "measure stable: " .. s)
                c.eq(first, IconText.measure(s, font, o), "measure stable x3: " .. s)
                c.eq(#IconText.spans(s, font, o), #IconText.spans(s, font, o),
                     "spans stable: " .. s)
            end
        end
    end

    -- Two fonts must not share a measure entry.
    for _, s in ipairs(strings) do
        if #s > 0 then
            c.ok(IconText.measure(s, f1) ~= IconText.measure(s, f2),
                 "font bleed in the measure cache: " .. s)
        end
    end

    -- Pills on and off must not share one either; a pill adds padding.
    c.ok(IconText.measure("1 in 4 chance", f1)
         ~= IconText.measure("1 in 4 chance", f1, IconText.PLAIN),
         "pill option bleed in the measure cache")

    -- Wrapping: cached equals uncached, and width buckets do not bleed.
    for _, s in ipairs(strings) do
        for _, w in ipairs({ 40, 120, 400 }) do
            local a = IconText.wrap(s, f1, w)
            local b = IconText.wrapUncached(s, f1, w)
            local tag = string.format("%s@%d", s, w)
            if c.eq(#a, #b, "wrap line count " .. tag) then
                for i = 1, #a do c.eq(a[i], b[i], "wrap line " .. i .. " " .. tag) end
            end
            c.eq(a, IconText.wrap(s, f1, w), "wrap identity " .. tag)
        end
    end

    -- Memo's contract: one build per token, a new token replaces the value.
    local m, builds = Memo.new("t"), 0
    local function build(v) builds = builds + 1; return { v } end
    local a = m:get("k", 1, build, "x")
    c.eq(a, m:get("k", 1, build, "x"), "memo returns the same table on a token match")
    c.eq(builds, 1, "memo built once")
    local rebuilt = m:get("k", 2, build, "y")
    c.eq(builds, 2, "memo rebuilt on a new token")
    c.ok(rebuilt ~= a, "memo replaced the value on a new token")

    local m2, n = Memo.new("t2"), 0
    local function b2() n = n + 1; return n end
    c.eq(m2:get2("s1", "g1", 1, b2), 1, "get2 first build")
    c.eq(m2:get2("s1", "g1", 1, b2), 1, "get2 hit")
    c.eq(m2:get2("s1", "g2", 1, b2), 2, "get2 second key")
    c.eq(m2:get2("s2", "g1", 1, b2), 3, "get2 other level")
    c.eq(m2:get2("s1", "g1", 2, b2), 4, "get2 token change")
end

-- ── chips: the face atlas ───────────────────────────────────────────────
-- One canvas for the whole ladder, built on the first draw and never again
-- for anything that varies per chip: tint, shade, rotation and denomination
-- are sprite parameters, not bake keys. Only a resize or a font change
-- earns a rebuild. sim/smoke_chips.lua goes deeper (piles, batches,
-- flights); this is the cache contract in the same terms as the others.

local Chips  -- also used by the pile section below

do
    local rec = Stub.recorder()
    local Constants = require("data.constants")
    Chips = require("views.Chips")

    local font = Stub.font(16)
    Chips.configureFont({ sm = font, xs = font })
    Chips.setScale(1)

    local was = Constants.FEATURES.CHIP_ATLAS

    -- The vector baseline: how many primitives is one full chip?
    Constants.FEATURES.CHIP_ATLAS = false
    rec.reset()
    Chips.drawChip(100, 100, 1, 1, true, nil, 1, 0, 1, 0.4)
    local vector_primitives = rec.total()

    -- The atlas: the first draw builds it, the second draws from it.
    Constants.FEATURES.CHIP_ATLAS = true
    rec.reset()
    Chips.drawChip(100, 100, 1, 1, true, nil, 1, 0, 1, 0.4)
    c.eq(rec.canvases, 1, "the first draw builds exactly one canvas")

    rec.reset()
    Chips.drawChip(100, 100, 1, 1, true, nil, 1, 0, 1, 0.4)
    c.eq(rec.canvases, 0, "a second draw must not build again")
    c.eq(rec.calls.draw or 0, 5, "a labelled atlas chip is five quad draws")
    c.eq(rec.calls.arc or 0, 0, "an atlas chip draws no arcs")
    c.eq(rec.calls.print or 0, 0, "the label is a quad, not a print")
    c.ok(rec.total() < vector_primitives,
         string.format("atlas (%d) should cost fewer primitives than vector (%d)",
                       rec.total(), vector_primitives))
    rec.reset()
    Chips.drawChip(100, 100, 1, 1, false, nil, 1, 0, 1, 0.4)
    c.eq(rec.calls.draw or 0, 2, "an unlabelled atlas chip is two quad draws")

    -- Rotation, denomination, tint and shade are sprite parameters, so none
    -- of them may touch the canvas.
    for _, case in ipairs({
        { "rotation",     function() Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 1, 2.1) end },
        { "denomination", function() Chips.drawChip(50, 50, 2, 1, true, nil, 1, 0, 1, 0) end },
        { "tint",  function() Chips.drawChip(50, 50, 1, 1, true, { 0.5, 0.5, 0.5 }, 1, 0, 1, 0) end },
        { "shade", function() Chips.drawChip(50, 50, 1, 1, true, nil, 0.8, 0, 1, 0) end },
        { "shade a thousandth off", function() Chips.drawChip(50, 50, 1, 1, true, nil, 0.8003, 0, 1, 0) end },
        { "shade a tenth off",      function() Chips.drawChip(50, 50, 1, 1, true, nil, 0.7, 0, 1, 0) end },
    }) do
        rec.reset(); case[2]()
        c.eq(rec.canvases, 0, "a new " .. case[1] .. " must not bake anything")
    end

    -- A resize rebuilds the atlas, once, on the next draw.
    Chips.setScale(1.25)
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 1, 0)
    Chips.drawChip(50, 50, 3, 1, true, nil, 1, 0, 1, 0)
    c.eq(rec.canvases, 1, "setScale must rebuild the atlas exactly once")

    -- Buried and edge chips are one quad each out of the same canvas.
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 3, 1, 0)
    c.ok(rec.canvases == 0 and (rec.calls.draw or 0) == 1 and (rec.calls.arc or 0) == 0,
         "a buried chip is one quad and no arcs")
    rec.reset()
    Chips.drawChipEdge(50, 50, 1, 1, nil, 0)
    c.ok(rec.canvases == 0 and (rec.calls.draw or 0) == 1, "an edge chip is one quad")

    -- The kill switch: one constant restores today's rendering exactly.
    Constants.FEATURES.CHIP_ATLAS = false
    rec.reset()
    Chips.drawChip(50, 50, 1, 1, true, nil, 1, 0, 1, 0)
    c.ok(rec.canvases == 0 and (rec.calls.draw or 0) == 0,
         "CHIP_ATLAS off restores the vector path")
    c.eq(rec.total(), vector_primitives, "the vector path is unchanged with the flag off")

    -- A column (the micro tier): three primitives, no canvas, no texture.
    rec.reset()
    Chips.drawColumn(50, 50, 1, 4, 1, nil, 1)
    c.eq(rec.canvases, 0, "drawColumn bakes nothing")
    c.eq(rec.calls.draw or 0, 0, "drawColumn draws no texture")
    c.eq(rec.total(), 3, "drawColumn is three primitives")

    Constants.FEATURES.CHIP_ATLAS = was
end

-- ── pile: the cached layout draws what a fresh layout says ──────────────

do
    Stub.base()   -- back to inert graphics; the pile is checked at chip level

    -- Intercept at the chip: ChipPile.draw funnels every chip through here,
    -- so recording the calls records the pile's whole output.
    local drawn, recording = {}, false
    local real_draw_chip, real_shadow = Chips.drawChip, Chips.drawShadow
    Chips.drawChip = function(x, y, idx, _, _, _, _, depth)
        if recording then
            drawn[#drawn + 1] = string.format("%d@%.2f,%.2f d%s", idx, x, y, tostring(depth))
        end
    end
    Chips.drawShadow = function() end

    local ChipPile = require("views.ChipPile")
    local ChipData = require("data.chips")

    local PLACE = { align = "center", max_w = 300, scale = 1, max_cols = 8, max_rows = 3 }
    local KEY   = "smoke:pile"
    local pal   = ChipData.full_palette

    local function snapshot()
        drawn, recording = {}, true
        ChipPile.draw(KEY)
        recording = false
        local out = {}
        for i, v in ipairs(drawn) do out[i] = v end
        return out
    end

    -- What the pile SHOULD draw, straight through the public layout helper
    -- with no cache involved.
    local function expected(x, y)
        local placed = ChipPile.layoutAt(x, y, ChipPile.denominations(KEY), PLACE)
        local out = {}
        for _, p in ipairs(placed) do
            out[#out + 1] = string.format("%d@%.2f,%.2f d%s", p.idx, p.x, p.y, tostring(p.depth))
        end
        return out
    end

    local function compare(label, x, y)
        local got, want = snapshot(), expected(x, y)
        if not c.eq(#got, #want, label .. ": chip count") then return end
        for i = 1, #want do
            if got[i] ~= want[i] then
                c.ok(false, string.format("%s: chip %d %s ~= %s", label, i, got[i], want[i]))
                return
            end
        end
        c.ok(true, label)
    end

    ChipPile.place(KEY, 100, 200, PLACE)
    ChipPile.sync(KEY, 137.50, { palette = pal, tier = "medium" })
    compare("after sync", 100, 200)

    -- Moving the pile must not stale the layout: x/y are applied at draw.
    ChipPile.place(KEY, 340, 512, PLACE)
    compare("after move", 340, 512)
    compare("cached redraw", 340, 512)

    ChipPile.tidy(KEY, 42.25, { palette = pal, tier = "small", instant = true })
    compare("after tidy", 340, 512)

    ChipPile.take(KEY, 10)
    compare("after take", 340, 512)

    -- Reserved chips are IN FLIGHT and deliberately not drawn, so the
    -- settled picture must be untouched until they are accepted.
    local before = snapshot()
    local res = ChipPile.reserve(KEY, { pal[1], pal[1] })
    local during = snapshot()
    if c.eq(#during, #before, "reserve must not change the settled pile") then
        for i = 1, #before do
            if before[i] ~= during[i] then c.ok(false, "reserve moved chip " .. i); break end
        end
    end
    for _, r in ipairs(res or {}) do ChipPile.accept(KEY, r.chip) end
    compare("after accept", 340, 512)

    -- A layout-shaping change must re-solve rather than serve the old plan.
    PLACE.max_cols = 2
    ChipPile.place(KEY, 340, 512, PLACE)
    compare("after max_cols change", 340, 512)
    PLACE.align = "left"
    ChipPile.place(KEY, 340, 512, PLACE)
    compare("after align change", 340, 512)

    ChipPile.clear(KEY)
    compare("after clear", 340, 512)
    ChipPile.sync(KEY, 88, { palette = pal, tier = "medium" })
    compare("after resync", 340, 512)

    -- The detail tier is draw-only: setting it must not re-solve the
    -- layout, and at "micro" the pile draws columns and never a chip.
    local solves, real_layout = 0, Chips.stackLayoutInto
    Chips.stackLayoutInto = function(...) solves = solves + 1; return real_layout(...) end
    local columns, real_column = 0, Chips.drawColumn
    Chips.drawColumn = function() columns = columns + 1 end
    ChipPile.tidy(KEY, 88, { palette = pal, tier = "medium", instant = true })
    snapshot()                       -- solves and caches the layout
    solves = 0
    PLACE.detail = "micro"
    ChipPile.place(KEY, 340, 512, PLACE)
    local micro_chips = #snapshot()
    c.eq(solves, 0, "detail = micro must not re-solve the layout")
    c.ok(columns > 0 and micro_chips == 0,
         string.format("micro draws columns and no chips (columns %d, chips %d)",
                       columns, micro_chips))
    PLACE.detail = nil
    ChipPile.place(KEY, 340, 512, PLACE)
    columns = 0
    local full_chips = #snapshot()
    c.ok(columns == 0 and full_chips > 0, "detail off draws chips again")
    c.eq(solves, 0, "clearing detail must not re-solve either")
    Chips.stackLayoutInto, Chips.drawColumn = real_layout, real_column

    Chips.drawChip, Chips.drawShadow = real_draw_chip, real_shadow
end

-- ── cards: the held queue ───────────────────────────────────────────────

do
    local rec = Stub.recorder()
    local CardSprites = require("views.CardSprites")
    local img   = { getWidth = function() return 56 end, getHeight = function() return 80 end,
                    setFilter = function() end }
    local atlas = { getSprite = function() return img end }
    local Card  = require("models.Card")
    local card  = Card:new("spades", "a")

    rec.reset()
    CardSprites.batchBegin()
    CardSprites.back(atlas, "cards/backs/x", 0, 0, 56, 80, 1)
    CardSprites.back(atlas, "cards/backs/x", 60, 0, 56, 80, 1)
    CardSprites.front(atlas, card, 120, 0, 56, 80, 1, false)
    c.eq(rec.calls.draw or 0, 0, "held cards draw nothing until batchEnd")
    CardSprites.batchEnd()
    c.eq(rec.calls.draw or 0, 3, "batchEnd replays every held card")

    -- Replaying must not re-enqueue: a second batchEnd is a no-op.
    rec.reset()
    CardSprites.batchEnd()
    c.eq(rec.calls.draw or 0, 0, "a second batchEnd replays nothing")

    -- A plated back and its flash replay as rects, in that order.
    rec.reset()
    CardSprites.batchBegin()
    CardSprites.back(atlas, "cards/backs/x", 0, 0, 56, 80, 1, true, 0.5)
    CardSprites.batchEnd()
    c.eq(rec.calls.draw or 0, 0, "a plated back draws no texture")
    c.ok((rec.calls.rectangle or 0) >= 3, "plate body, plate edge and the flash all drew")

    -- Outside a batch everything is immediate, as before.
    rec.reset()
    CardSprites.back(atlas, "cards/backs/x", 0, 0, 56, 80, 1)
    c.eq(rec.calls.draw or 0, 1, "a back outside a batch draws at once")

    -- No decision means art, whatever the width: flights and the flyer.
    rec.reset()
    CardSprites.back(atlas, "cards/backs/x", 0, 0, 8, 11, 1)
    c.eq(rec.calls.draw or 0, 1, "an undecided back never plates, however narrow")
end

-- ── analytics: an append-only log, folded back to the file shape ───────

do
    local files = Stub.memoryFS()
    local Constants = require("data.constants")
    local was = Constants.DEBUG.HAND_ANALYTICS
    Constants.DEBUG.HAND_ANALYTICS = true
    local HA   = require("services.HandAnalytics")
    local json = require("lib.json")

    -- Entering the grind must never read the log back: that parse of the
    -- whole file is one of the two stalls the log replaced.
    local reads = 0
    local base_read = love.filesystem.read
    love.filesystem.read = function(p) reads = reads + 1; return base_read(p) end

    -- The writer stub the autosave stands in for: every call's name,
    -- chunk and mode, in order.
    local calls = {}
    local function writer(name, chunk, mode)
        calls[#calls + 1] = { name = name, chunk = chunk, mode = mode }
        return true
    end
    local function allChunks()
        local parts = {}
        for i, w in ipairs(calls) do parts[i] = w.chunk end
        return table.concat(parts)
    end

    local state = { save_id = "t1", shove_count = 2, active_deck_id = "d1",
                    owned_items = { "a" }, run_upgrade_levels = { focus = 2 } }
    HA.startRun(state)
    c.eq(reads, 0, "startRun reads nothing back")
    for i = 1, 30 do
        HA.recordHand({ won = (i % 2 == 0), delta = i, tier = "small", game_type_id = "zoom",
                        stake_id = 'nl"2', stake_bb = 0.02 })
    end
    HA.recordEvent({ kind = "buy", id = "desk" })
    HA.flush(state, false, writer)

    c.eq(#calls, 1, "one flush is one chunk")
    c.eq(calls[1] and calls[1].name, "analytics_t1.jsonl", "the writer gets the per-save log name")
    for _, w in ipairs(calls) do c.eq(w.mode, "append", "every chunk is an append") end
    c.ok(calls[1] and calls[1].chunk:sub(-1) == "\n", "the chunk ends on a newline")

    -- Every line is one JSON object.
    local n_lines, bad = 0, 0
    for line in allChunks():gmatch("[^\n]+") do
        n_lines = n_lines + 1
        local ok, obj = pcall(json.decode, line)
        if not (ok and type(obj) == "table" and obj.k) then bad = bad + 1 end
    end
    c.eq(bad, 0, "every line decodes")
    c.eq(n_lines, 30 + 1 + 1 + 1 + 1, "save, header, 30 hands, the event and the update")

    -- Folded, it is the file the tools read.
    local data = HA.fold(allChunks())
    c.eq(data.save_id, "t1", "save_id survives")
    c.eq(#data.shoves, 1, "one shove")
    local run = data.shoves[1]
    c.eq(run and run.shove_count, 2, "the current shove is the one in the log")
    c.eq(run and #run.hands, 30, "every hand is in the log")
    c.eq(run and run.hands[30].delta, 30, "hands keep their order and fields")
    c.eq(run and run.hands[30].stake_id, 'nl"2', "a quote in a string field round-trips")
    c.eq(run and run.hands[30].stake_bb, 0.02, "a fraction round-trips")
    c.eq(run and run.hands[30].hands_played, nil, "a field the record lacks is absent, not null")
    c.eq(run and run.hands[1].won, false, "false is false, not absent")
    c.eq(run and #run.events, 1, "events ride with the run")
    c.eq(run and run.events[1].id, "desk", "an event keeps its fields")
    c.eq(run and run.run_upgrade_levels and run.run_upgrade_levels.focus, 2, "flush snapshots upgrades")
    c.eq(run and run.deck_id, "d1", "the header's deck")
    c.eq(run and run.hands_dropped, 0, "nothing dropped")

    -- A flush with nothing new writes nothing: the update line only lands
    -- when the metadata changed.
    HA.flush(state, false, writer)
    c.eq(#calls, 1, "an unchanged flush writes no chunk")
    HA.recordShoveStart({ r1 = 0.5, r2 = 0.4, r3 = 0.3, clear = 0.06, catalog = 1, mult = 2, bankroll = 1e6 })
    HA.flush(state, false, writer)
    c.eq(#calls, 2, "a changed snapshot writes its update")
    data = HA.fold(allChunks())
    c.eq(data.shoves[1].shove_rate and data.shoves[1].shove_rate.r1, 0.5, "the update merges into the shove")
    HA.recordShoveResult({ won = false, busted_at = 2 }, 0)
    HA.flush(state, false, writer)
    data = HA.fold(allChunks())
    c.eq(data.shoves[1].gauntlet_result, "lost_r2", "the result merges in, last wins")

    -- The burst flush: past the pending cap the lines go out on their
    -- own, through the writer the autosave registered.
    HA.setWriter(writer)
    local before = #calls
    for i = 1, 300 do HA.recordHand({ delta = 1000 + i }) end
    c.ok(#calls > before, "a burst between autosaves flushes itself")
    for _, w in ipairs(calls) do c.eq(w.mode, "append", "the burst is an append too") end
    HA.flush(state, false, writer)
    data = HA.fold(allChunks())
    c.eq(#data.shoves[1].hands, 330, "every burst hand is in the log")
    HA.setWriter(nil)

    -- The next shove: a second header, and later hands fold under it.
    state.shove_count = 3
    HA.startRun(state)
    c.eq(reads, 0, "a second startRun reads nothing back either")
    for i = 1, 5 do HA.recordHand({ won = true, delta = i }) end
    HA.flush(state, false, writer)
    data = HA.fold(allChunks())
    c.eq(#data.shoves, 2, "two shoves after a resume")
    c.eq(data.shoves[1] and #data.shoves[1].hands, 330, "the old shove is intact")
    c.eq(data.shoves[2] and data.shoves[2].shove_count, 3, "the new shove is the second")
    c.eq(data.shoves[2] and #data.shoves[2].hands, 5, "the new shove has its hands")
    c.eq(data.shoves[2] and data.shoves[2].gauntlet_result, nil, "the new shove has no result yet")
    local saves = 0
    for _ in allChunks():gmatch('"k":"save"') do saves = saves + 1 end
    c.eq(saves, 1, "the save line is written once")

    -- A resume into the same shove writes another header and the fold
    -- merges them.
    HA.startRun(state)
    HA.recordHand({ delta = 6 })
    HA.flush(state, false, writer)
    data = HA.fold(allChunks())
    c.eq(#data.shoves, 2, "a resumed shove is still one shove")
    c.eq(data.shoves[2] and #data.shoves[2].hands, 6, "hands after the resume join it")

    -- A torn tail (a crash mid-append leaves a line without its end)
    -- costs that line only.
    local folded = HA.fold(allChunks() .. '{"k":"hand","s":3,"delta":99,"ti')
    c.eq(#folded.shoves, 2, "a truncated last line is skipped")
    c.eq(folded.shoves[2] and #folded.shoves[2].hands, 6, "the torn hand is the only one lost")
    c.eq(folded.shoves[2] and folded.shoves[2].hands[6].delta, 6, "the last whole line is kept")

    -- No writer: the inline append lands on the disk.
    HA.recordHand({ delta = 7 })
    HA.flush(state, false, nil)
    c.ok(files["analytics_t1.jsonl"] ~= nil, "flush without a writer appends inline")
    c.ok(files["analytics_t1.jsonl"] and files["analytics_t1.jsonl"]:find('"delta":7', 1, true) ~= nil,
         "the inline append carries the hand")

    -- deleteCurrent removes the log and the document an older build left.
    files["analytics_t1.json"] = "{}"
    HA.deleteCurrent()
    c.eq(files["analytics_t1.jsonl"], nil, "deleteCurrent removes the log")
    c.eq(files["analytics_t1.json"], nil, "deleteCurrent removes the legacy document")
    local n_calls = #calls
    HA.recordHand({ delta = 8 })
    HA.flush(state, false, writer)
    c.eq(#calls, n_calls, "nothing records after deleteCurrent")

    -- Off is off: with the flag down nothing is named or written.
    Constants.DEBUG.HAND_ANALYTICS = false
    HA.startRun(state)
    HA.recordHand({ delta = 9 })
    HA.flush(state, false, writer)
    c.eq(#calls, n_calls, "disabled, nothing is written")
    c.eq(HA.stats().hands, 0, "disabled, nothing is counted")

    love.filesystem.read = base_read
    Constants.DEBUG.HAND_ANALYTICS = was
end

-- ── screens: every state builds and draws ───────────────────────────────
--
-- Twice now a call site left behind by a refactor reached the player as a
-- boot crash: a preload calling a local declared below it, and a title
-- screen calling a function whose signature had changed. Requiring the
-- module caught neither, because neither runs until something draws.
--
-- So: build every state the way main.lua registers them, and draw each one
-- frame. The stub graphics record nothing here; the assertion is simply
-- that the call completes. That is enough — both of those crashes were an
-- index of a nil, one frame in.

do
    local H = require("sim.harness")
    local F = Stub.font(16)
    local w = H.world()
    local g = w.game
    g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
    -- A state machine shaped like the real one: the states ask it what
    -- screen is showing and register themselves against it.
    g.state_machine = { states = {}, switch = function() end,
                        current = function() return "grind" end }

    -- A sprite loader that answers without touching the disk: the room
    -- draws whatever the layout names, and what matters here is that the
    -- draw runs, not what it looks like.
    local img = { getWidth = function() return 32 end,
                  getHeight = function() return 32 end,
                  getDimensions = function() return 32, 32 end,
                  setFilter = function() end, release = function() end }
    g.sprite_loader = {
        getSprite    = function() return img end,
        getSpriteFor = function() return img end,
        hasSprite    = function() return true end,
        backColor    = function() return { 0.5, 0.5, 0.5 } end,
        setSprite    = function() end,
        itemArt      = function() return img end,
    }

    Stub.recorder()
    love.graphics.newFont = function() return F end
    love.graphics.getFont = function() return F end

    -- Every state is built BEFORE any of them draws, because they reach
    -- each other through the machine: the title borrows the room's view to
    -- show the room in the dark, and the shove borrows it for its intro.
    -- Building and drawing one at a time left those lookups nil, which is
    -- how a crash inside RoomView slipped through this very check.
    local NAMES = { "grind", "shove", "credits", "title", "room" }
    local MODULES = { grind = "GrindState", shove = "ShoveState",
                      credits = "CreditsState", title = "TitleState",
                      room = "RoomState" }
    local built = {}
    for _, key in ipairs(NAMES) do
        local name = MODULES[key]
        local made, inst = pcall(function() return require("states." .. name):new(g) end)
        if c.ok(made, name .. " builds: " .. tostring(inst)) then
            built[key] = inst
            g.state_machine.states[key] = inst
        end
    end
    for _, key in ipairs(NAMES) do
        local inst = built[key]
        if inst then
            g.state_machine.current = function() return key end
            local drew, err = pcall(function() inst:draw() end)
            c.ok(drew, MODULES[key] .. " draws: " .. tostring(err))
            -- A second frame, because the first one fills the caches and
            -- registers the anchors the second one reads back.
            local again, err2 = pcall(function() inst:draw() end)
            c.ok(again, MODULES[key] .. " draws a second frame: " .. tostring(err2))
        end
    end
    -- The shove's room phase, the room before the shove: it plays on the
    -- House's security monitor (views/CrtMonitor).
    local sv = built.shove and built.shove.view
    local rv = built.shove and built.shove._roomView and built.shove:_roomView()
    if sv and sv.beginRoomCount and rv then
        sv:beginRoomCount(rv, {}, {})
        sv.room_lights = "on"
        local drew, err = pcall(function() sv:_drawRoomCount(1600, 900) end)
        c.ok(drew, "the shove's room count draws through the security monitor: " .. tostring(err))
    else
        c.ok(false, "the shove view has a room view to draw the count with")
    end
end

-- ── save: one file, versioned, with a backup ────────────────────────────
--
-- The thread-less path, which is what the web build always takes and what
-- the quit path takes everywhere.

do
    love.thread = nil
    local files = Stub.memoryFS()

    local SaveService = require("services.SaveService")
    local Constants   = require("data.constants")
    local FILE        = Constants.SAVE.FILE

    local ss = SaveService:new()
    c.eq(ss:_worker(), nil, "no worker when love.thread is absent")
    c.eq(ss:hasSave(), false, "no save on an empty disk")

    local payload = {
        meta = { chips = 7, owned_items = { "a", "b" }, nested = { x = { 1, 2, 3 } } },
        run  = { bankroll = 1234.5, tables = { { stake_id = "s001", game_type_id = "zoom" } } },
    }

    c.eq(ss:save(payload), true, "the save writes")
    c.ok(files[FILE] ~= nil, "the save file is on disk")
    c.eq(files[FILE .. ".tmp"], nil, "the staged tmp is consumed")
    c.ok(not files[FILE]:find("\n"), "the save is compact, not pretty")
    c.eq(ss:hasSave(), true, "hasSave is true after a save")

    local back = ss:load()
    c.ok(back ~= nil, "the save reads back")
    c.eq(back and back.meta and back.meta.chips, 7, "a scalar round-trips")
    c.eq(back and back.meta and back.meta.owned_items[2], "b", "a list round-trips")
    c.eq(back and back.meta and back.meta.nested.x[3], 3, "nesting round-trips")
    c.ok(back and back.run and math.abs(back.run.bankroll - 1234.5) < 1e-9,
         "a float round-trips")
    c.eq(back and back.run and back.run.tables[1].stake_id, "s001",
         "a table record round-trips")

    -- Both halves are in ONE file, which is what makes a torn pair
    -- impossible: there is no second commit to crash between.
    c.ok(files[FILE]:find('"meta"', 1, true) and files[FILE]:find('"run"', 1, true),
         "meta and run are in the same file")

    -- A staged tmp left by a crash between stage and commit is the newest
    -- copy, and is tried before anything else.
    local staged = files[FILE]
    files[FILE] = nil
    files[FILE .. ".tmp"] = staged
    local from_tmp = ss:load()
    c.ok(from_tmp ~= nil, "a save is recovered from its staged tmp")
    c.eq(from_tmp and from_tmp.meta and from_tmp.meta.chips, 7,
         "...carrying the state that was staged")
    c.eq(ss.load_failed, false, "...without latching the service")
    files[FILE], files[FILE .. ".tmp"] = staged, nil
end

-- ── save: the desktop commit, which keeps a backup ──────────────────────
--
-- The rename path only runs where love.filesystem reports a real save
-- directory; the web build has none and takes the copy fallback, which
-- deliberately keeps no backup (a read plus two writes on every autosave
-- is the IDBFS stall the writer thread exists to avoid).

do
    local files = Stub.memoryFS()
    local SaveService = require("services.SaveService")
    local FILE = require("data.constants").SAVE.FILE

    -- A save directory, and rename/remove over the same memory table, so
    -- the commit takes the branch a desktop player takes.
    love.filesystem.getSaveDirectory = function() return "/save" end
    local real_rename, real_remove = os.rename, os.remove
    local function strip(path) return (path:gsub("^/save/", "")) end
    os.rename = function(from, to)
        from, to = strip(from), strip(to)
        if files[from] == nil then return nil, "no such file" end
        files[to], files[from] = files[from], nil
        return true
    end
    os.remove = function(path)
        path = strip(path)
        if files[path] == nil then return nil, "no such file" end
        files[path] = nil
        return true
    end

    local ss = SaveService:new()
    local payload = { meta = { chips = 7 }, run = { bankroll = 1 } }
    c.eq(ss:save(payload), true, "the first save writes")
    c.eq(files[FILE .. ".bak"], nil, "the first save has nothing to back up")

    payload.meta.chips = 9
    c.eq(ss:save(payload), true, "the second save writes")
    c.ok(files[FILE .. ".bak"] ~= nil, "the previous save is kept as a backup")
    c.eq(ss:load().meta.chips, 9, "the newest save is what loads")

    -- The backup is what a corrupted live file falls back to. This is the
    -- case the old two-slot layout had no answer for at all.
    files[FILE] = "{ this is not json"
    local recovered = ss:load()
    c.ok(recovered ~= nil, "a corrupt save falls back to the backup")
    c.eq(recovered and recovered.meta and recovered.meta.chips, 7,
         "...carrying the previous state")
    c.eq(ss.load_failed, false, "...without latching the service")

    os.rename, os.remove = real_rename, real_remove

    -- A file from another version is refused, kept, and does not latch.
    local ss2 = SaveService:new()
    Stub.memoryFS()
    local other = SaveService:new()
    other:save(payload)
    local raw = love.filesystem.read(FILE)
    love.filesystem.write(FILE, (raw:gsub('"version":%d+', '"version":1')))
    local refused, why = ss2:load()
    c.eq(refused, nil, "a save from another version does not load")
    c.eq(why, "old", "...and says why")
    c.eq(ss2.refused, "old", "...and records it for the title screen")
    c.eq(ss2.load_failed, false, "...without latching the service")
    c.eq(ss2:hasSave(), false, "...and does not count as a save")
    c.ok(love.filesystem.read(FILE) ~= nil, "...and is left on disk, not deleted")

    -- An unreadable save DOES latch, and nothing overwrites it.
    local files3 = Stub.memoryFS()
    local ss3 = SaveService:new()
    files3[FILE] = "{ garbage"
    c.eq(ss3:load(), nil, "an unreadable save does not load")
    c.eq(ss3.load_failed, true, "...and latches the service")
    c.eq(ss3:save(payload), false, "...so nothing overwrites it")
    ss3:clear()
    c.eq(ss3.load_failed, false, "clear lifts the latch")
    c.eq(files3[FILE], nil, "clear removes the save")

    -- Settings are their own file and their own rules: a broken one costs
    -- the player their volume, not their save.
    local files4 = Stub.memoryFS()
    local ss4 = SaveService:new()
    c.eq(ss4:saveSettings({ volume = 0.5, motion_cards = 3 }), true, "settings write")
    c.eq(ss4:loadSettings().volume, 0.5, "settings read back")
    files4[require("data.constants").SAVE.SETTINGS_FILE] = "{ garbage"
    c.eq(ss4:loadSettings(), nil, "a broken settings file does not load")
    c.eq(ss4.load_failed, false, "...and never latches the save service")
    c.eq(ss4:save(payload), true, "...so the game still saves")

    c.ok(pcall(function() ss:drainResults() end), "drainResults is safe with no worker")
    c.ok(pcall(function() ss:flushWorker() end), "flushWorker is safe with no worker")
end

-- ─── The catalog book: paging, the paper, the count ────────────────────
-- The post-shove book (open, not on the felt) on the stub: the arrow and
-- Page keys turn it, a click on bare paper leaves it open while a click on
-- the felt closes it, and the turn controls sit inside the book's edges
-- (the manifest's stub lives on the outer left edge and must stay clear).
do
    local H = require("sim.harness")
    local F = Stub.font(16)
    local w = H.world()
    local g = w.game
    g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
    g.state_machine = { states = {}, switch = function() end,
                        current = function() return "shove" end }
    local img = { getWidth = function() return 32 end,
                  getHeight = function() return 32 end,
                  getDimensions = function() return 32, 32 end,
                  setFilter = function() end, release = function() end }
    g.sprite_loader = {
        getSprite    = function() return img end,
        getSpriteFor = function() return img end,
        hasSprite    = function() return true end,
        backColor    = function() return { 0.5, 0.5, 0.5 } end,
        setSprite    = function() end,
        itemArt      = function() return img end,
    }
    Stub.recorder()
    love.graphics.newFont = function() return F end
    love.graphics.getFont = function() return F end

    -- The page-flip timer reads the frame delta; the stub has no clock.
    love.timer.getDelta = love.timer.getDelta or function() return 1 / 60 end
    local CatalogModal = require("views.CatalogModal")
    local m = CatalogModal:new(g)
    local function landed() m.flip_t, m.flip_dir, m.old_spread_index = nil, nil, nil end

    local drew, err = pcall(function() m:draw() end)
    c.ok(drew, "the catalog draws its cover: " .. tostring(err))
    local W  = love.graphics.getDimensions()
    local cx = W * 0.5
    c.ok(m._book_rect ~= nil and math.abs(m._book_rect.x - cx) <= 1,
         "on the cover the visible book starts at the spine")
    c.ok(m._next_rect ~= nil and m._prev_rect == nil, "the cover has OPEN > and no PREV")
    if m._next_rect and m._book_rect then
        c.ok(m._next_rect.x + m._next_rect.w <= m._book_rect.x + m._book_rect.w + 1,
             "OPEN > sits inside the book's right edge")
    end

    c.eq(m:consumeKey("right"), true, "the right arrow is a page key")
    c.eq(m.spread_index, 1, "...and turns to the first spread")
    landed()
    c.eq(m:consumeKey("pagedown"), true, "Page Down is a page key")
    c.eq(m.spread_index, 2, "...and turns forward again")
    landed()
    c.eq(m:consumeKey("left"), true, "the left arrow is a page key")
    c.eq(m.spread_index, 1, "...and turns back")
    landed()
    c.eq(m:consumeKey("space"), true, "Space is still the book's leave key")
    c.eq(m._resolved, true, "...and resolves it")
    m._resolved = false

    local drew2, err2 = pcall(function() m:draw() end)
    c.ok(drew2, "a spread draws: " .. tostring(err2))
    local br = m._book_rect
    c.ok(br ~= nil and m._prev_rect ~= nil and m._prev_rect.x >= br.x,
         "PREV starts at the book's left edge, never outside it where the manifest's stub is")
    c.ok(br ~= nil and m._next_rect ~= nil and m._next_rect.x + m._next_rect.w <= br.x + br.w + 1,
         "NEXT ends at the book's right edge")

    -- Bare paper: the left leaf's outer margin at mid-height, where no
    -- card, tab, sticker or control is.
    m._enter_t = 1
    if br then
        c.eq(m:consumeMouse(br.x + 6, br.y + br.h * 0.5, 1), true, "a click on bare paper is consumed")
        c.eq(m._resolved, false, "...and leaves the book open")
    end
    c.eq(m:consumeMouse(1, 1, 1), true, "a click on the felt is consumed")
    c.eq(m._resolved, true, "...and closes the book")
    m._resolved = false

    m.spread_index = math.ceil(#m:_pages() / 2) + 1
    local drew3, err3 = pcall(function() m:draw() end)
    c.ok(drew3, "the back cover draws: " .. tostring(err3))
    c.ok(m._book_rect and math.abs(m._book_rect.x + m._book_rect.w - cx) <= 1,
         "on the back cover the visible book ends at the spine")
    c.ok(m._prev_rect ~= nil and m._next_rect == nil, "the back cover has < BACK and no NEXT")
    c.eq(m:consumeKey("home"), true, "Home is a page key")
    landed()
    c.eq(m.spread_index, 0, "...back to the cover")
end

-- ─── The take: the run's chips thrown onto the felt ────────────────────
-- views/ChipTake on the stub: every chip lands inside the screen and clear
-- of the BANKED line, a handful clusters and a flood still fits, and the
-- draws run (the light pass returns early: the stub never builds the quad).
do
    local ChipTake = require("views.ChipTake")
    local W, H = 1600, 900
    local summary = { x = W / 2 - 200, y = 700, w = 400, h = 40 }
    local book    = { x = 640, y = 300, w = 200, h = 260 }
    local avoid   = { summary, book }
    local preset  = { flips = 1, spins = 1, phase = 0, min_squash = 0.28, loft = { 0.30, 0.50 } }
    local function inside(cc, take)
        return cc.x - take.r >= 0 and cc.x + take.r <= W and cc.y - take.r >= 0 and cc.y + take.r <= H
    end
    local function offRect(cc, take, rect)
        return not (cc.x + take.r > rect.x and cc.x - take.r < rect.x + rect.w
                    and cc.y + take.r > rect.y and cc.y - take.r < rect.y + rect.h)
    end
    local function offSummary(cc, take) return offRect(cc, take, summary) and offRect(cc, take, book) end
    local function run(n)
        local take = ChipTake.begin(n, "take:test", W, H, 1, avoid, preset)
        local last = 0
        for _, cc in ipairs(take.chips) do if cc.arrive_t > last then last = cc.arrive_t end end
        local steps = math.ceil((last + 0.1) / (1 / 60))
        for _ = 1, steps do ChipTake.update(take, 1 / 60, nil) end
        return take
    end

    c.eq(ChipTake.begin(0, "take:none", W, H, 1, avoid, preset), nil, "no chips, no take")

    local t12 = run(12)
    c.eq(#t12.chips, 12, "twelve chips banked: twelve chips thrown")
    c.ok(ChipTake.done(t12), "...and all twelve landed once the clock passed the last arrival")
    local all_in, all_off = true, true
    for _, cc in ipairs(t12.chips) do
        if not inside(cc, t12) then all_in = false end
        if not offSummary(cc, t12) then all_off = false end
    end
    c.ok(all_in, "every chip of twelve lands inside the screen")
    c.ok(all_off, "none of the twelve lands on the BANKED line or the book")

    local t150 = run(150)
    c.eq(#t150.chips, 150, "a hundred and fifty banked: a hundred and fifty thrown, no cap")
    c.ok(ChipTake.done(t150), "...and the flood all lands")
    all_in, all_off = true, true
    for _, cc in ipairs(t150.chips) do
        if not inside(cc, t150) then all_in = false end
        if not offSummary(cc, t150) then all_off = false end
    end
    c.ok(all_in, "the flood stays on screen")
    c.ok(all_off, "the flood stays off the BANKED line and the book")
    c.ok(t150.spacing < t12.spacing, "a flood rains faster per chip than a handful")

    local t1 = ChipTake.begin(1, "take:one", W, H, 1, avoid, preset)
    local dx = math.abs(t1.chips[1].x - W * 0.5)
    c.ok(dx <= 60 + t1.r, "a single chip lands within the spread floor of the rest point")

    local drew, err = pcall(function()
        Stub.recorder()
        ChipTake.drawLights(t12)
        ChipTake.drawChips(t12)
        local mid = ChipTake.begin(20, "take:mid", W, H, 1, avoid, preset)
        ChipTake.update(mid, 0.5, nil)   -- some landed, some in the air
        ChipTake.drawChips(mid)
    end)
    c.ok(drew, "the take draws landed and airborne chips: " .. tostring(err))
end

os.exit(c.report("smoke_views") == 0 and 0 or 1)
