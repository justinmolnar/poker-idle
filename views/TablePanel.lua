-- views/TablePanel.lua
--
-- Renders one mini 6-max poker table inside a layout cell. Stateless module
-- (not a class) — call sites pass the Table model + cell rect + a hit_boxes
-- accumulator each frame.
--
-- Visual layout in a (w × h) cell, w ≈ 340, h ≈ 205:
--   • header strip (22 px) — stake display name + [x] remove button
--   • felt area  — green rounded rect filling the rest of the cell
--       └ top row: 5 opponent boxes (name / 2 mini face-down cards / stack)
--       └ middle:  pot label + 5 community card slots
--       └ bottom:  2 player hole cards centered; chip pile + its $ amount
--                  at the left edge, EV readout at the right
--   • DEAL button overlay (when state == idle) covering the felt center
--   • [STAKE↑ <next>] button overlay (when next stake is unlocked + affordable)
--
-- The community / hole card visibility tracks the per-hand state machine
-- in models/Table — flop shows 3, turn 4, river+ 5; opponent's hole flips
-- face-up only on showdown and settling.

local Theme         = require("views.Theme")
local Constants     = require("data.constants")
local Decks         = require("models.Decks")
local PokerEventAnims = require("views.PokerEventAnims")
local AnimsData       = require("data.animations")
local Stakes        = require("data.stakes")
local GameTypes     = require("data.game_types")
local KoPayouts    = require("data.ko_payouts")
local Chips         = require("views.Chips")
local ChipFlight    = require("views.ChipFlight")
local ChipPile      = require("views.ChipPile")
local ChipData      = require("data.chips")
local Denoms        = require("services.DenominationBreakdown")
local ClickFlash    = require("services.ClickFlash")
local RollingValue  = require("services.RollingValue")
local Hover         = require("services.HoverService")
local Button        = require("views.Button")
local Ghosts        = require("services.Ghosts")
local Anchors       = require("services.AnchorRegistry")
local ClickSurfaces = require("services.ClickSurfaces")
local OutcomeBar    = require("views.OutcomeBar")
local IconText      = require("views.IconText")
local Poke          = require("services.Poke")
local Table         = require("models.Table")
local Stats         = require("views.TablePanelStats")
local SpriteRenderer = require("services.SpriteRenderer")
local StakeThemes   = require("data.stake_themes")
local GameTypeThemes = require("data.game_type_themes")
local HistoryBars   = require("data.history_bars")
local Lookups       = require("utils.lookups")
local Format        = require("utils.format")
local CardSprites   = require("views.CardSprites")
local Motion        = require("services.Motion")
local Effects       = require("views.TablePanelEffects")
local ShaderRegistry = require("services.ShaderRegistry")
local Perf           = require("services.Perf")
local PanelSheet     = require("views.PanelSheet")
local FeltStyle     = require("data.felt_style")
local FeltData      = require("data.felt_layout")

-- ── Felt = the stake's chip, leashed to the card room ───────────────────
-- Every felt starts from the same classic green (Theme.bg.felt) and is
-- pulled toward the stake's chip — the biggest denomination that posts
-- its big blind, the chip a player at that table thinks in. The chip's
-- hue is allowed to lead (the purple room reads purple, the blue room
-- blue); the green in the mix and the shared luminance ramp keep the
-- tiers one family instead of a set of unrelated paints. Both knobs live
-- in data/felt_style.lua `color`. OPAQUE, luma-normalized per tier so a
-- pale chip can't out-glow the ladder.
--
-- Cached per stake; the cache is keyed to the live base token so a theme
-- palette switch rebuilds it (tokens must never be cached — Theme.lua).
local _felt_cache, _felt_base = {}, nil
local _deal_fill_cache = {}
local function feltForStake(stake_id)
    local base = Theme.bg.felt
    if _felt_base ~= base then
        _felt_cache, _felt_base = {}, base
        _deal_fill_cache = {}
    end
    local cached = _felt_cache[stake_id]
    if cached then return cached end
    local stake = Lookups.findById(Stakes, stake_id)
    local bb = (stake and stake.bb) or 0
    -- Which chip paints this room: the stake's felt_chip override when
    -- set (data/stakes — used where the bb chip's hue would repeat a
    -- neighbouring tier's), else the biggest denomination that posts
    -- the big blind.
    local best
    if stake and stake.felt_chip then
        for _, d in ipairs(ChipData.denominations) do
            if d.value == stake.felt_chip then best = d; break end
        end
    end
    if not best then
        for _, d in ipairs(ChipData.denominations) do
            if d.value <= bb then best = d else break end
        end
    end
    best = best or ChipData.denominations[1]
    local col = best.color
    -- Every room is built at the SAME luminance and the SAME chroma; the
    -- only thing a room takes from its chip is the HUE ANGLE. This is
    -- uniform by construction — no room can be brighter, louder, or
    -- grayer than another, and a hue can't wash out into "another
    -- version of teal" the way every blend-toward-green scheme did (a
    -- green-cast blend injects green into all six rooms, so they
    -- converge; equal-chroma construction can't converge).
    --
    -- Hue is read in an opponent-axis plane (cr = R-Y, cb = B-Y) and the
    -- output color is reconstructed exactly at target luma Y with chroma
    -- C along that hue. A hueless chip (white 1c, black $100) has no
    -- angle, so its room takes the base felt GREEN's hue — the classic
    -- green room. Knobs in data/felt_style `color`.
    -- NOTE: sim/felt_check.lua mirrors this math to audit the rooms —
    -- keep the two in step.
    local cc  = FeltStyle.color or {}
    local base_luma = 0.30 * base[1] + 0.59 * base[2] + 0.11 * base[3]
    local target = base_luma * (cc.luma or 1.10)
    local C = cc.chroma or 0.10
    local cy = 0.30 * col[1] + 0.59 * col[2] + 0.11 * col[3]
    local cr, cb = col[1] - cy, col[3] - cy
    local n = math.sqrt(cr * cr + cb * cb)
    if n < (cc.min_chroma or 0.06) then
        cr, cb = base[1] - base_luma, base[3] - base_luma
        n = math.sqrt(cr * cr + cb * cb)
    end
    local r = target + C * cr / n
    local b = target + C * cb / n
    local g = (target - 0.30 * r - 0.11 * b) / 0.59
    r = math.max(0, math.min(1, r))
    g = math.max(0, math.min(1, g))
    b = math.max(0, math.min(1, b))
    local c = { r, g, b, 1 }
    _felt_cache[stake_id] = c
    return c
end

-- The DEAL button wears its own table's felt, lifted: a different table, a
-- different button, and never a result colour. Cached beside the felt
-- (the same reset on a palette change): it was three multiplies and a
-- table per idle panel per frame.
local function dealFillForStake(stake_id)
    local fill = _deal_fill_cache[stake_id]
    if fill then return fill end
    local felt = feltForStake(stake_id) or Theme.bg.felt
    fill = { math.min(1, felt[1] * 1.7 + 0.10),
             math.min(1, felt[2] * 1.7 + 0.10),
             math.min(1, felt[3] * 1.7 + 0.10) }
    _deal_fill_cache[stake_id] = fill
    return fill
end

-- "1st" / "2nd" / "3rd" / "Nth". Shared by the FINISH readout and the
-- finish tags eliminated seats wear.
local function ordinal(pos)
    if pos == 1 then return "1st"
    elseif pos == 2 then return "2nd"
    elseif pos == 3 then return "3rd"
    else return string.format("%dth", pos) end
end
local FeltDecor     = require("views.FeltDecor")
local FeltLayout    = require("views.FeltLayout")
local BandStack     = require("services.BandStack")
local Pop           = require("services.Pop")

local TablePanel = {}

-- Exported: the sidebar's add-table rows wear the same felt as the
-- panels they open (views/GrindView), so the two read as one identity.
function TablePanel.feltForStake(stake_id)
    return feltForStake(stake_id)
end

-- Layout constants — relative to a panel's (x, y) origin.
-- Base sizes are 1× design-space; scaled per-panel at draw time
-- against the panel's actual (w, h) so the chrome shrinks when the
-- grid crams many panels into a single window. Computed as
--   pscale = min(w / PANEL_BASE_W, h / PANEL_BASE_H)
-- and clamped by game.ui_scale so a single panel on a giant window
-- doesn't blow chrome up past the window scale's font budget.
local PANEL_BASE_W    = 520
local PANEL_BASE_H    = 390
local HEADER_H_BASE   = 24
local FELT_INSET_BASE = 6
local REMOVE_BTN_BASE = 18
local DEAL_BTN_W_BASE = 140
local DEAL_BTN_H_BASE = 40

local HEADER_H        = 24
local FELT_INSET      = 6
local REMOVE_BTN_SIZE = 18
local DEAL_BTN_W      = 140
local DEAL_BTN_H      = 40

-- EV readout (bottom-of-panel "+/- $N.NN/h" text) and the backtick
-- debug overlay both live in views/TablePanelStats — that module is the
-- single source of truth for the pool-breakdown line list. We just route
-- the calls through here.

-- Panel-relative card sizing now lives in views/FeltLayout (sourced from
-- data/felt_layout's card fractions) so the layout calculator and the panel
-- share one sizing path. Thin alias kept for the existing call sites.
local cardSizesFor = FeltLayout.cardSizes

-- Opponent count comes from the table's game type now (`#tbl.opponents`).

-- ─── Helpers ──────────────────────────────────────────────────────────


-- Visibility helpers. Two paths: with poker theater on, the table
-- carries a playback_state populated by HandScript event applicators
-- (fold / deal / showdown_reveal mutate playback_state), and we read
-- those fields directly. With theater off, fall back to the legacy
-- state-name keying (dealing/flop/turn/river/showdown/settling).
-- The finished hand still on the felt: only at idle, only until the next
-- deal removes tbl.last_hand. The snapshot's keys mirror both tbl.* and
-- playback_state.* names, so handData/seatState substitute it for either
-- source and every draw function below renders the residue for free.
-- The residue's shader pair. `sh` is the desaturate shader or nil (no
-- shader: draw in colour, keep the layout); the amount goes up only when
-- it differs from the last one sent, which across a resting board is once.
local _desat_sent = nil
local function desatBegin(sh, amount)
    if not (sh and amount) then return end
    if _desat_sent ~= amount then
        _desat_sent = amount
        pcall(sh.send, sh, "u_amount", amount)
    end
    Perf.count("shader_switch")
    love.graphics.setShader(sh)
end
local function desatEnd(sh)
    if not sh then return end
    love.graphics.setShader()
end

local EMPTY = {}  -- the shared empty list: never mutated, never allocated per frame
local _lp = {}   -- FeltLayout.computeCached's parameter table, reused
local function residueOf(tbl)
    return (tbl.state == "idle") and tbl.last_hand or nil
end

-- Card/name/combo source: the live table, or the residue snapshot at idle.
local function handData(tbl)
    return residueOf(tbl) or tbl
end

-- Seat-facts source: live playback_state, or the residue snapshot at idle.
local function seatState(tbl)
    return tbl.playback_state or residueOf(tbl)
end

local function communityCardCount(tbl)
    local ss = seatState(tbl)
    if ss then return ss.community_count or 0 end
    local s = tbl.state
    if s == "idle" or s == "dealing" then return 0 end
    if s == "flop"     then return 3 end
    if s == "turn"     then return 4 end
    return 5  -- river / showdown / settling
end

local function holeVisible(tbl)
    return tbl.state ~= "idle" or residueOf(tbl) ~= nil
end

-- ─── Low-motion pile hold ─────────────────────────────────────────────
-- At chips ≤ Low the pot and the player's stack piles hold their picture
-- for a whole street: frozen at the street's first frame, thawed (and
-- re-frozen) when the board grows and when the hand settles. The held
-- value is what the pot label prints too. Returns the value to show, or
-- nil when nothing is held (motion on, or the table idle).
local function holdPile(tbl, key, field, live_value)
    if Motion.level("chips") > Motion.LOW or tbl.state == "idle" then
        if tbl[field] then ChipPile.thaw(key); tbl[field] = nil end
        return nil
    end
    local ps       = tbl.playback_state
    local street   = (ps and ps.community_count) or 0
    local settling = tbl.state == "settling"
    local h = tbl[field]
    if not h or h.street ~= street or h.settling ~= settling then
        ChipPile.thaw(key)
        h = { street = street, settling = settling, value = live_value }
        tbl[field] = h
        ChipPile.freeze(key)
    end
    return h.value
end

-- ─── The deal gates ──────────────────────────────────────────────────
-- views/PokerEventAnims writes tbl._deal_fx when it throws cards: for each
-- card key ("you", "opp_N", "board_N") the wall-clock time the flight lands
-- and whether the card turns face-up on landing. Until it lands the slot
-- draws empty; while it turns, the back squashes to edge-on and the face
-- opens out (the shove's flip). Live hands only — residue never gates.
-- Returns nil (draw normally), "hidden", or "flip", p.
-- Names built from an index, once each: "cards_opp_3_1", "table:12",
-- "tied:12". The first read of an index builds and keeps the string; every
-- read after is a lookup. Table.anchorKey memoizes on the slot string, so
-- building the slot per seat per frame was defeating it; the panel-index
-- names ("table:N", "tied:N") cannot use anchorKey at all, because
-- data/hints.lua targets them by index. Bounded by the board: 36 cells,
-- 9 seats, 5 board slots.
local function named(build)
    return setmetatable({}, { __index = function(t, i)
        local s = build(i)
        rawset(t, i, s)
        return s
    end })
end
local OPP_CARD_1 = named(function(i) return "cards_opp_" .. i .. "_1" end)
local OPP_CARD_2 = named(function(i) return "cards_opp_" .. i .. "_2" end)
local OPP_SLOT   = named(function(i) return "opp_" .. i end)
local SEAT_NAME  = named(function(i) return "Seat " .. i end)
local BOARD_SLOT = named(function(i) return "board_" .. i end)
local TABLE_KEY  = named(function(i) return "table:" .. i end)
local BAR_KEY    = named(function(i) return "bar:" .. i end)
-- How fast the odds bar eases to new odds (per second, exponential).
local BAR_EASE   = 6
local _pv_opts   = {}
local _bar_live_opts = {}
local TIED_KEY   = named(function(i) return "tied:" .. i end)
local STACK_KEY  = named(function(i) return "stack:" .. i end)
local EV_KEY     = named(function(i) return "ev:" .. i end)
-- Two levels: ACTION_KEY.deal[3] is "deal:3".
local ACTION_KEY = named(function(action)
    return named(function(i) return action .. ":" .. i end)
end)

-- A clicked card jumps (services/Poke, services/ClickFX): its key is
-- "card:<table id>:<card anchor name>", built once per table and name; the
-- panel's prefix ("card:<id>:") lets the cache classifier see any of them.
local function cardKey(tbl, name)
    local m = tbl._card_keys
    if not m then m = {}; tbl._card_keys = m end
    local k = m[name]
    if not k then k = "card:" .. tostring(tbl._id) .. ":" .. name; m[name] = k end
    return k
end
local function cardPrefix(tbl)
    local k = tbl._card_prefix
    if not k then k = "card:" .. tostring(tbl._id) .. ":"; tbl._card_prefix = k end
    return k
end
local function cardDY(tbl, name)
    local _, dy = Poke.offset(cardKey(tbl, name))
    return dy
end
-- "pile:<anchor key>", the key views/ChipPile draws a pile's spring under.
-- A card on show as a click surface, at its recorded anchor.
local _surf_opts = {}
local function cardSurface(tbl, name)
    local a = Anchors.get(Table.anchorKey(tbl, name))
    if a and a[3] then
        _surf_opts.poke = cardKey(tbl, name)
        ClickSurfaces.addLocal("card", a[1], a[2], a[3], a[4], _surf_opts)
    end
end
local _pile_opts, _felt_opts, _deny_opts = {}, {}, {}
-- "hit:<action>:<id>", the press key ClickFlash flashes and a refusal shakes.
local HIT_POKE = setmetatable({}, { __index = function(t, k)
    local v = "hit:" .. k; rawset(t, k, v); return v end })
local PILE_SLOTS = { "pot", "you" }
local PILE_POKE = setmetatable({}, { __index = function(t, k)
    local v = "pile:" .. k; rawset(t, k, v); return v end })

local _deal_back = nil   -- this frame's back sprite, for the turn's first half
-- The dealer button, parked by the seat that holds it and drawn by
-- TablePanel.draw after the cards are released from their batch: it
-- straddles a card's corner, so drawn in the seat it would sit under the
-- replayed card. `d` is nil when no seat parked one this panel.
local _dealer_btn = { x = 0, y = 0, d = nil, alpha = 1 }
local function dealGate(tbl, key)
    local fx = tbl._deal_fx
    if not fx or tbl.state == "idle" then return nil end
    local at = fx.arrive and fx.arrive[key]
    if not at then return nil end
    local now = love.timer.getTime()
    if now < at then return "hidden" end
    if fx.flip and fx.flip[key] then
        local d = (AnimsData.grind_deal and AnimsData.grind_deal.flip) or 0.22
        if now < at + d then return "flip", (now - at) / d end
    end
    -- Low motion: the card is in its slot and fades in.
    if Motion.level("cards") <= Motion.LOW then
        local a = Motion.fade("cards", "deal:" .. tostring(tbl._id) .. ":" .. key .. ":" .. tostring(at))
        if a < 1 then return "fade", a end
    end
    return nil
end

-- The live window (fx.live_until, PokerEventAnims): while a street's cards
-- are landing and turning, a STATIC render leaves their slots empty and
-- TablePanel.drawLive paints the cards over the cached picture each frame
-- (drawLiveCards). Once the street is down the key moves (buildKey's live
-- count) and the cards are baked. The immediate path ignores it: the body
-- draws every card by its gate as it always did.
local _static = false   -- set by renderBody: this body paints a cache slot
local function dealLive(tbl, key)
    local fx = tbl._deal_fx
    if not fx or tbl.state == "idle" then return false end
    local lu = fx.live_until
    local u = lu and lu[key]
    return u ~= nil and love.timer.getTime() < u
end

-- Zoom's seat row fading in after a reroll (reroll_flash_t, 0.4 s from
-- Table:fillOpponents): the same treatment. A STATIC render leaves the
-- row out and drawLive draws the seats each frame until the fade is done;
-- the flag is a key field, so the fade's end rebuilds the picture once.
local function rerollLive(tbl)
    return (tbl.reroll_flash_t or 0) > 0 and Motion.at("tables", Motion.FULL)
end

-- How many card keys are inside their live window: a key field, so a
-- street opening and a street settling each rebuild the picture once.
local function dealLiveCount(tbl)
    local fx = tbl._deal_fx
    if not fx or tbl.state == "idle" then return 0 end
    local lu = fx.live_until
    if not lu then return 0 end
    local now, n = love.timer.getTime(), 0
    for _, u in pairs(lu) do if now < u then n = n + 1 end end
    return n
end

-- A card turning face-up in its slot: back squashing to edge-on, then the
-- face opening out. Same squash the shove uses.
-- `back_plate` is the band's decision for its backs: the closing half shows
-- the plate at the squashed width rather than the art, so a card on a small
-- felt does not flash its pattern for a tenth of a second mid-turn.
local function drawCardTurn(sl, card, x, y, w, h, p, shadow, back_plate)
    if p < 0.5 then
        local sx = 1 - 2 * p
        CardSprites.shadow(x + (w - w * sx) / 2, y, w * sx, h, 1, shadow)
        if _deal_back then
            if back_plate then
                CardSprites.backPlate(sl, _deal_back, x + (w - w * sx) / 2, y, w * sx, h, 1)
            else
                CardSprites.sprite(sl, _deal_back, x, y, w, h, sx, 1)
            end
        end
    else
        local sx = 2 * p - 1
        CardSprites.shadow(x + (w - w * sx) / 2, y, w * sx, h, 1, shadow)
        if card then CardSprites.sprite(sl, card:spriteName(), x, y, w, h, sx, 1) end
    end
end

local function opponentFaceUp(tbl)
    local ss = seatState(tbl)
    if ss then
        return ss.opp_revealed == true
    end
    local s = tbl.state
    return s == "showdown" or s == "settling"
end

-- Default back sprite used when no deck override is available (FEATURES.DECKS
-- off, or active deck spec missing). The deck system overrides this per
-- frame in TablePanel.draw — the constant is just the fallback.
local CARD_BACK = Constants.GAUNTLET and Constants.GAUNTLET.CARD_BACK_SPRITE
                  or "cards/backs/03-fish"


-- ─── Card rendering ──────────────────────────────────────────────────
-- Card back / front / slot rendering primitives now live in
-- views/CardSprites.lua so the shove gauntlet shares the same fallback
-- treatment. drawCardBack takes the back sprite explicitly so the active
-- deck's art can flow through without globals.

-- Backs take no `plate` argument: the deck's art is drawn at every size (see
-- views/CardSprites), so there is no decision to force.
-- Deck level-up flash: GrindController stamps state._deck_levelup_t and
-- every face-down back brightens for LEVELUP_FLASH_SECS after it. Set per
-- frame in TablePanel.draw, read here so the call sites stay untouched.
local LEVELUP_FLASH_SECS = 0.6
local _back_pulse = 0

-- `plate` is the band's back_plate decision (views/FeltLayout). The
-- level-up pulse rides along as CardSprites.back's `flash`, so it is drawn
-- with the back and stays on top of it when backs are held for a batch.
local function drawCardBack(sl, back, x, y, w, h, alpha, shadow, plate)
    CardSprites.shadow(x, y, w, h, alpha, shadow)
    CardSprites.back(sl, back or CARD_BACK, x, y, w, h, alpha, plate, _back_pulse)
end

-- Fronts take the layout's FORCED small-card decision, not a per-call size
-- test: the showdown emphasis pass redraws the winning cards up to 1.26x, and
-- letting each call re-derive it from its own width would flip a card near the
-- threshold between art and plate mid-pop. `shadow` (the drop-shadow offset in
-- px, 0 = none) comes from the layout for the same reason.
local function drawCardFront(sl, card, x, y, w, h, alpha, plate, shadow)
    if not card then return end
    CardSprites.shadow(x, y, w, h, alpha, shadow)
    CardSprites.front(sl, card, x, y, w, h, alpha, plate)
end

local function drawCardSlot(x, y, w, h)
    CardSprites.slot(x, y, w, h)
end

-- Showdown win highlight. `combo` is the winner's best-5 (the 5 cards from
-- models/Table's player_combo / opponent_combo). A card glows when it is one
-- of those references. Matches the gauntlet's best-5 treatment so "which
-- cards won" reads at a glance — the winner's two hole cards + the board
-- cards they used light up green, the rest stay plain.
-- Value match (suit+rank) -- a 7-card deal has no duplicates, so this uniquely
-- identifies a card and can't break on reference identity the way `c == card`
-- could if the combo and the drawn card ever came from different objects.
local function inCombo(card, combo)
    if not combo or not card then return false end
    for _, c in ipairs(combo) do
        if c.rank == card.rank and c.suit == card.suit then return true end
    end
    return false
end

-- Showdown emphasis is done as a single overlay pass (drawShowdownEmphasis,
-- below) that runs AFTER every normal card/anim draw, so it can't be buried.

-- ─── Sub-panels ──────────────────────────────────────────────────────

-- Mini bar-graph of the last N hand outcomes, drawn into the header strip.
-- Newest entry on the right, oldest on the left. Color: per-tier ramp
-- (green for wins, red for losses) so a Stack result pops gold/pink at a
-- glance. Height: per-tier fraction from data/history_bars.lua.
--
-- Adapts to available width: targets 10 bars, falls back to the min-size
-- pair (min_bar_w / min_bar_gap) when the zone is tight, and renders
-- nothing if even one min-sized bar wouldn't fit. No tier branches —
-- height is a data lookup.
local function drawHistoryBars(tbl, zone_x, zone_y, zone_w, zone_h, s)
    local results = tbl.last_results
    if not results or #results == 0 or zone_w <= 0 or zone_h <= 0 then
        return
    end

    local layout  = HistoryBars.layout
    local heights = HistoryBars.height

    -- Scale bar dimensions with the active ui_scale so the mini-graph
    -- grows with the window. Data file holds 1× sizes; we apply the
    -- scale here at draw time. Min sizes use ceil(... * s) so they
    -- never round down to zero on small windows.
    local sc          = s or 1
    local bar_w_pref  = math.max(1, math.floor(layout.bar_w     * sc))
    local gap_pref    = math.max(1, math.floor(layout.bar_gap   * sc))
    local bar_w_min   = math.max(1, math.ceil (layout.min_bar_w * sc))
    local gap_min     = math.max(1, math.ceil (layout.min_bar_gap * sc))
    local graph_h_max = math.max(1, math.floor(layout.graph_h   * sc))

    -- Pick the largest bar+gap pair that fits at least 1 bar in zone_w.
    -- Try the preferred sizes first; fall back to the min sizes.
    local function fit(bar_w, gap)
        local slot_w = bar_w + gap
        if slot_w <= 0 then return 0 end
        local n = math.floor((zone_w + gap) / slot_w)
        if n > layout.max_bars then n = layout.max_bars end
        return n, bar_w, gap
    end

    local n, bar_w, gap = fit(bar_w_pref, gap_pref)
    if n < 1 then
        n, bar_w, gap = fit(bar_w_min, gap_min)
    end
    if n < 1 then return end

    -- Show the newest n results, in order (oldest left → newest right).
    local total = #results
    local first_visible = math.max(1, total - n + 1)
    local visible_count = total - first_visible + 1

    -- Right-align the bar pack inside the zone. graph baseline = zone bottom.
    local pack_w = visible_count * bar_w + (visible_count - 1) * gap
    local x0 = zone_x + zone_w - pack_w
    local baseline_y = zone_y + zone_h
    local graph_h = math.min(zone_h, graph_h_max)

    -- Faint baseline track behind every slot — gives the empty slots a
    -- tiny dark cap so the graph reads as "10 slots" not "free-floating
    -- bars". Drawn full visible_count wide (not max_bars wide) so it
    -- aligns with the actual bars rendered this frame.
    Theme.setColor(Theme.border.default, layout.baseline_alpha)
    love.graphics.rectangle("fill", x0, baseline_y - 1, pack_w, 1)

    for i = 0, visible_count - 1 do
        local entry = results[first_visible + i]
        if entry and entry.tier then
            local frac = heights[entry.tier] or 0.5
            local bh   = math.max(1, math.floor(graph_h * frac))
            local bx   = x0 + i * (bar_w + gap)
            local by   = baseline_y - bh

            -- Color by tier so a Stack (stack) result pops at a glance,
            -- while win/loss stays legible (green ramp vs red ramp). Keyed
            -- lookup — no tier branches; flat win/loss color is the fallback.
            local ramp  = entry.won and Theme.tier.win or Theme.tier.loss
            local color = ramp[entry.tier]
                          or (entry.won and Theme.sem.won or Theme.sem.lost)
            Theme.setColor(color, 0.95)
            love.graphics.rectangle("fill", bx, by, bar_w, bh)
        end
    end
end

-- ─── Hit boxes ────────────────────────────────────────────────────────
-- Pooled per table. `list` is either GrindView's frame list (the immediate
-- path: the entry comes from tbl._hb_pool and is appended) or the table's
-- own static list tbl._hb_static (the cached render: the list IS the pool,
-- and its entries are replayed into the frame list every frame until the
-- next rebuild). Two pools, so an immediate frame can never rewrite an
-- entry the cached path is still replaying. Nothing holds a hit box past
-- the frame it was read (GrindView's click handler and the cursor swarm
-- both resolve within the update), so rewriting in place is safe. Was a
-- table per box per panel per frame.
local function hbNew(tbl, list)
    local e
    if list == tbl._hb_static then
        local n = (tbl._hbs_n or 0) + 1
        tbl._hbs_n = n
        e = list[n]
        if not e then e = {}; list[n] = e end
    else
        local pool = tbl._hb_pool
        if not pool then pool = {}; tbl._hb_pool = pool end
        local n = (tbl._hb_n or 0) + 1
        tbl._hb_n = n
        e = pool[n]
        if not e then e = {}; pool[n] = e end
        list[#list + 1] = e
    end
    for k in pairs(e) do e[k] = nil end
    return e
end

-- One options table for every chunky button the panel draws, rewritten
-- per call (views/Button reads it synchronously and keeps nothing), and
-- label painters hoisted to module level reading upvalues set just before
-- the call: the X, D, R and DEAL buttons were four tables and four
-- closures per panel per frame.
local _bopts = {}
local function btnOpts(fill, border, hovered, press, disabled, depth, line_width)
    local o = _bopts
    o.fill_color, o.border_color = fill, border
    o.hovered, o.press_alpha, o.disabled, o.depth = hovered, press, disabled, depth
    o.line_width = line_width
    return o
end
local _lbl_fonts, _lbl_color, _lbl_text, _lbl_muted = nil, nil, nil, false
local function headerLabel(fx, fy, fw, fh)
    local f = _lbl_fonts.sm
    Theme.setColor(_lbl_color)
    love.graphics.setFont(f)
    love.graphics.printf(_lbl_text, fx, fy + (fh - f:getHeight()) * 0.5, fw, "center")
    if _lbl_muted then
        love.graphics.setLineWidth(1)
        Theme.setColor(Theme.fg.disabled)
        love.graphics.line(fx + 3, fy + fh / 2, fx + fw - 3, fy + fh / 2)
    end
end

-- The header's text, memoized on the table: neither part changes for a
-- table's life. Read by the header and by the panel cache's key.
local function headerText(tbl)
    local stats = tbl:liveStats() or EMPTY
    local sd, gs = stats.stake_display or "?", stats.game_type_short
    local header_text = tbl._header_str
    if not header_text or tbl._header_sd ~= sd or tbl._header_gs ~= gs then
        header_text = sd
        if gs and gs ~= "" then header_text = sd .. " · " .. gs end
        tbl._header_str, tbl._header_sd, tbl._header_gs = header_text, sd, gs
    end
    return header_text
end

local function drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, can_remove, cursor_on, rebuy_cursor_on, s, ui_s)
    local header_text = headerText(tbl)
    -- Per-stake header chrome: T1 dim grey, T6 near-black with a gold
    -- accent. Falls back to default Theme.bg.chrome.
    local stake_theme = StakeThemes[tbl.stake_id]
    -- The header wears the GAME TYPE's color (data/game_type_themes.lua):
    -- chrome = mode, felt = stake. Falls back to the stake header, then
    -- the default chrome, for a type with no theme.
    local gtype_theme = GameTypeThemes[tbl.game_type_id]
    local header_fill = (gtype_theme and gtype_theme.chrome_color)
                        or (stake_theme and stake_theme.header_bg)
                        or Theme.bg.chrome
    Theme.setColor(header_fill)
    love.graphics.rectangle("fill", x, y, w, HEADER_H, Theme.space.radius)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", x, y, w, HEADER_H, Theme.space.radius)

    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.heading)
    local header_text_y = y + math.floor((HEADER_H - fonts.sm:getHeight()) * 0.5)
    love.graphics.print(header_text, x + 8, header_text_y)

    -- [x] remove (right edge). Chunky button via views/Button. Warn-
    -- tinted while pending_close so the player can see a click on a busy
    -- table was queued and will fire when the hand finishes.
    local rb_x = x + w - REMOVE_BTN_SIZE - 4
    local rb_y = y + 3
    local pending_close = tbl.pending_close == true
    local rb_fill       = pending_close and Theme.border.strong
                          or (can_remove and Theme.bg.widget_hover or Theme.bg.sunken)
    do
        local rid     = Table.rollingKey(tbl, "remove_table")
        local hovered = can_remove and Hover.is("hit", rid)
        local press   = can_remove and ClickFlash.alpha("hit", rid) or 0
        _lbl_fonts, _lbl_text, _lbl_muted = fonts, "X", false
        _lbl_color = (can_remove or pending_close) and Theme.fg.heading or Theme.fg.disabled
        Button.draw(rb_x, rb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE,
            btnOpts(rb_fill,
                    (can_remove or pending_close) and Theme.border.strong or Theme.border.soft,
                    hovered, press, not can_remove, 2),
            headerLabel)
    end
    if can_remove then
        local hb = hbNew(tbl, hit_boxes)
        hb.x, hb.y, hb.w, hb.h = rb_x, rb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE
        hb.action, hb.idx, hb.table_id = "remove_table", idx, tbl._id
        hb.label, hb.fill_color = "X", rb_fill
        hb.tooltip = pending_close
              and "Closing after this hand. Click again to leave NOW — forfeits the hand; a tournament cashes whatever place it stands in."
               or "Close this table — refunds the current stack."
    end

    -- Header toggle buttons fill in left of the [×] from right to left.
    -- D shows when the cursor system itself is unlocked; R shows when
    -- the cursor-rebuy upgrade is owned. Each is independent so an
    -- edge-case state where only one is owned still renders correctly.
    local hands_right_offset = REMOVE_BTN_SIZE + 4 + 4
    local next_btn_x         = rb_x - REMOVE_BTN_SIZE - 4

    -- Cursor-deal toggle "D" — green (matches the DEAL button it gates).
    if cursor_on then
        local cb_x = next_btn_x
        local cb_y = y + 3
        local muted = tbl.cursor_muted == true
        local cid     = Table.rollingKey(tbl, "toggle_cursor")
        local hovered = Hover.is("hit", cid)
        local press   = ClickFlash.alpha("hit", cid)
        local active_color = Theme.fg.heading        -- DEAL is lit, not green (green is a hand won)
        _lbl_fonts, _lbl_text, _lbl_muted = fonts, "D", muted
        _lbl_color = muted and Theme.fg.disabled or active_color
        Button.draw(cb_x, cb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE,
            btnOpts(muted and Theme.bg.sunken or Theme.bg.widget_hover,
                    muted and Theme.border.soft or active_color,
                    hovered, press, nil, 2),
            headerLabel)
        local hb = hbNew(tbl, hit_boxes)
        hb.x, hb.y, hb.w, hb.h = cb_x, cb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE
        hb.action, hb.idx, hb.table_id = "toggle_cursor", idx, tbl._id
        hb.tooltip = muted and "Unmute: allow cursors to deal at this table."
                           or  "Mute: stop the cursor swarm from dealing at this table."
        next_btn_x         = next_btn_x - REMOVE_BTN_SIZE - 4
        hands_right_offset = hands_right_offset + REMOVE_BTN_SIZE + 4
    end

    -- Cursor-rebuy toggle "R" — red (matches the REBUY button it gates).
    -- Independent of the D toggle: visible whenever the rebuy upgrade is
    -- owned, even if the cursor-system unlock somehow weren't.
    if rebuy_cursor_on then
        local rcb_x = next_btn_x
        local rcb_y = y + 3
        local rmuted = tbl.cursor_rebuy_muted == true
        local rcid     = Table.rollingKey(tbl, "toggle_rebuy_cursor")
        local rhovered = Hover.is("hit", rcid)
        local rpress   = ClickFlash.alpha("hit", rcid)
        local r_active_color = Theme.sem.lost        -- REBUY follows a loss and spends money
        _lbl_fonts, _lbl_text, _lbl_muted = fonts, "R", rmuted
        _lbl_color = rmuted and Theme.fg.disabled or r_active_color
        Button.draw(rcb_x, rcb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE,
            btnOpts(rmuted and Theme.bg.sunken or Theme.bg.widget_hover,
                    rmuted and Theme.border.soft or r_active_color,
                    rhovered, rpress, nil, 2),
            headerLabel)
        local hb = hbNew(tbl, hit_boxes)
        hb.x, hb.y, hb.w, hb.h = rcb_x, rcb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE
        hb.action, hb.idx, hb.table_id = "toggle_rebuy_cursor", idx, tbl._id
        hb.tooltip = rmuted and "Unmute: cursors will rebuy this table."
                            or  "Mute: cursors won't rebuy this table."
        next_btn_x         = next_btn_x - REMOVE_BTN_SIZE - 4
        hands_right_offset = hands_right_offset + REMOVE_BTN_SIZE + 4
    end

    -- History bars — fit them into the gap between the stake-name text
    -- and the buttons on the right. Vertically centered in the header
    -- strip. The graph uses ui_scale (the window scale) instead of the
    -- per-panel scale, so the bars stay legible even at small panel
    -- sizes — the user wanted the graph to keep size, not vanish into
    -- a single-pixel sliver when the grid crams panels.
    local scale_for_graph = ui_s or s or 1
    local name_right = x + 8 + fonts.sm:getWidth(header_text)
    local zone_x     = name_right + 8
    local zone_w     = (x + w - hands_right_offset) - zone_x
    local graph_h    = math.max(1, math.floor(HistoryBars.layout.graph_h * scale_for_graph))
    local zone_y     = y + math.floor((HEADER_H - graph_h) / 2)
    drawHistoryBars(tbl, zone_x, zone_y, zone_w, graph_h, scale_for_graph)

    -- Whole-header grab strip for drag-to-rearrange. Pushed LAST so the
    -- [x]/D/R boxes above win the first-match hit walk; a press anywhere
    -- else on the header latches a possible drag (GrindView resolves
    -- click-vs-drag on release).
    local hb = hbNew(tbl, hit_boxes)
    hb.x, hb.y, hb.w, hb.h = x, y, w, HEADER_H
    hb.action, hb.idx, hb.table_id = "drag_table", idx, tbl._id
end

local function drawOpponentSeat(opp, opp_idx, tbl, x, y, w, h, sl, fonts, sizes,
                                cards_y_offset, back_sprite, show_names, plate,
                                shadow, plate_rect, felt_color, button, back_plate)
    if not opp then return end

    local gtype = Lookups.findById(GameTypes,tbl.game_type_id)

    -- HU seat is the duel — the opponent gets a heading-font name and
    -- 2× cards so they read as A Rival, not a generic seat. Single
    -- boolean check on the gtype id, not a kind chain.
    local big      = tbl.game_type_id == "hu"
    local base_w   = sizes.opp_w
    local base_h   = sizes.opp_h
    local card_w   = big and (base_w * 2) or base_w
    local card_h   = big and (base_h * 2) or base_h
    local card_gap = big and 6 or 3
    -- All seat names use the small xs tier (HU included). HU was md, which
    -- dwarfed the felt and shrank the opp/community cards -- it's low-priority
    -- chrome, not worth the space.
    local name_font = fonts.xs or fonts.sm
    -- cards_y_offset is supplied by views/FeltLayout (= reserved name height +
    -- gap) so cards always begin BELOW the name, at any font/panel size.
    local name_max = big and 14 or 8

    -- Anonymous pool (Zoom): show "Seat N" instead of the rolled name.
    -- The data file flips the flag; the view consumes it. Reroll-flash
    -- adds a brief fade-in so the player visibly sees the swap each hand.
    local anonymous = gtype and gtype.anonymous_opponents
    local raw_name  = anonymous and SEAT_NAME[opp_idx]
                      or (opp.name or "?")

    -- Pixel-width truncation, MEMOIZED on the opp object. The naive
    -- per-frame while-loop dominated the grind hot path at multi-table
    -- scale (6 panels × 5 opps × ~12 trim iterations per opp ≈ 360
    -- getWidth calls + 360 string allocations every frame, which fed
    -- enough GC pressure to compound with other heap churn into
    -- observable lag). Cache key = (raw_name, slot_w, font_height).
    -- Reroll rebuilds the opp object so cache fields go away naturally;
    -- a slot resize or font-tier change invalidates via the w / fh
    -- comparisons. Stable steady-state = zero getWidth calls in this
    -- block.
    --
    -- We always shrink the ASCII raw name BEFORE appending "…" —
    -- chopping a string that already has the 3-byte "…" suffix at byte
    -- boundaries leaves a partial UTF-8 codepoint and crashes
    -- name_font:getWidth (real bug we hit before).
    local label_pad = 6
    local fh        = name_font:getHeight()
    if show_names == false then
        -- The layout decided this seat is too narrow to hold a name. Names are
        -- flavor and there is no smaller font to shrink into, so nothing is
        -- drawn and nothing is measured (the memo below is the hot path at 32
        -- panels x 7 seats). Clearing _lbl_raw is what makes the memo rebuild
        -- if the grid opens back up; the guard keeps this to one write.
        if opp._lbl_raw ~= nil then
            opp._lbl, opp._lbl_w, opp._lbl_fh, opp._lbl_raw = nil, nil, nil, nil
        end
    elseif opp._lbl_w  ~= w
       or opp._lbl_fh  ~= fh
       or opp._lbl_raw ~= raw_name then
        local ell = "…"
        local label = raw_name
        if name_font:getWidth(label) > w - label_pad then
            local n = #raw_name
            while n > 0 and name_font:getWidth(raw_name:sub(1, n) .. ell) > w - label_pad do
                n = n - 1
            end
            if n > 0 then
                label = raw_name:sub(1, n) .. ell
            else
                label = ell
            end
        end
        -- Even the bare ellipsis doesn't fit → hide entirely.
        if name_font:getWidth(label) > w - 2 then label = nil end
        opp._lbl     = label
        opp._lbl_w   = w
        opp._lbl_fh  = fh
        opp._lbl_raw = raw_name
    end
    local label = opp._lbl

    -- Reroll-flash alpha multiplier. flash_t decays 0.4 → 0 over ~0.4 s
    -- (set by Table:fillOpponents); we map that to alpha 0 → 1 so seats
    -- pulse-fade-in on each new hand.
    local flash_t = tbl.reroll_flash_t or 0
    if not Motion.at("tables", Motion.FULL) then flash_t = 0 end
    local seat_alpha = (flash_t > 0) and (1 - flash_t / 0.4) or 1
    if seat_alpha < 0.15 then seat_alpha = 0.15 end

    -- Map this seat's visual opp_idx (1..n_opps) to a script_seat
    -- (1..n_seats including the player). Used by both fold-dim and the
    -- chip-stack busted lookup.
    local ss_map = seatState(tbl)
    local player_seat_for_map =
        (ss_map and ss_map.player_seat)
        or tbl.player_seat_fixed
    local script_seat = nil
    if player_seat_for_map then
        script_seat = (opp_idx < player_seat_for_map) and opp_idx or (opp_idx + 1)
    end

    -- Chip-stack tournaments (8-max KO): an ELIMINATED player LEAVES.
    -- No plate, no cards, no dim arithmetic — an empty chair with a small
    -- finish tag where they sat, which is legible at any panel size and
    -- can never be mistaken for a fold (a fold is a live seat with mucked
    -- cards). The tag is dropped, not shrunk, when it doesn't fit the
    -- seat; the empty chair still reads. The KO flash on top is the
    -- moment itself (queued by the controller when the bust lands).
    local seat_busted_flag = (gtype and gtype.chip_stack_table
        and tbl.seat_busted and script_seat
        and tbl.seat_busted[script_seat]) or false
    if seat_busted_flag then
        local n_seats = (gtype.seats or 0) + 1
        local finish
        for i, s in ipairs(tbl.bust_order or {}) do
            if s == script_seat then finish = n_seats - i + 1; break end
        end
        local cards_y = y + cards_y_offset
        local ko = Effects.seatKOProgress(tbl, script_seat)
        if finish then
            -- The biggest font that fits the seat, dropped (never
            -- clipped) below that. Muted, not disabled — the tags are
            -- half the progress display and have to be readable.
            local f, tag = fonts.sm, ordinal(finish):upper()
            if f:getWidth(tag) > w - 2 then f = fonts.xs or f end
            love.graphics.setFont(f)
            if f:getWidth(tag) <= w - 2 then
                local ty = cards_y + math.floor((card_h - f:getHeight()) / 2)
                if ko then
                    -- Stamping in: red and oversized on the hit, settling
                    -- into the resting grey.
                    local pop = Motion.at("tables", Motion.FULL) and (1 + 0.6 * (1 - ko)) or 1
                    Theme.setColor(Theme.sem.lost, 0.5 + 0.5 * (1 - ko))
                    love.graphics.push()
                    love.graphics.translate(x + w / 2, ty + f:getHeight() / 2)
                    love.graphics.scale(pop, pop)
                    love.graphics.printf(tag, -w / 2, -f:getHeight() / 2, w, "center")
                    love.graphics.pop()
                else
                    Theme.setColor(Theme.fg.muted, 0.9)
                    love.graphics.printf(tag, x, ty, w, "center")
                end
            end
        end
        if ko then
            Effects.drawSeatKOFlash(x, cards_y, w, card_h, ko)
        end
        return
    end

    -- Folded-seat dim. When the script has marked this seat out of the
    -- hand (in_seats[script_seat] is nil), drop the seat to ~30% opacity
    -- so the player can see at a glance who's still in. Theater-only —
    -- when playback_state is nil we don't dim.
    local seat_folded = false
    local ss_fold = seatState(tbl)
    if ss_fold and ss_fold.player_seat and ss_fold.in_seats and script_seat then
        if not ss_fold.in_seats[script_seat] then
            seat_alpha  = seat_alpha * 0.30
            seat_folded = true
        end
    end
    -- Out of the hand: the dim above says HOW MUCH; this says the seat
    -- draws flat slabs instead of deck art, which is what actually reads
    -- at a glance (see CardSprites.folded).
    local seat_out = seat_folded

    -- Seat plate: the backing this seat's name and cards sit on, so the seat
    -- reads as a position at the table. Published by the layout only when the
    -- seat is showing a name (the plate IS the nameplate), and dimmed with the
    -- seat so a folded or busted one recedes as a whole.
    FeltDecor.drawSeatPlate(plate_rect, felt_color, seat_alpha)

    -- Name / label. Drawn on a single line — never wrap. If even the
    -- truncated "…" form doesn't fit, the label was nil-ed out above
    -- and the slot just shows cards.
    if label then
        Theme.setColor(Theme.fg.primary, 0.85 * seat_alpha)
        love.graphics.setFont(name_font)
        local lw = name_font:getWidth(label)
        love.graphics.print(label, x + math.floor((w - lw) / 2), y)
    end

    -- Two face-down cards (or face-up if showdown and this is the revealed opp).
    local cards_y  = y + cards_y_offset
    local cards_w  = card_w * 2 + card_gap
    local cards_x  = x + math.floor((w - cards_w) / 2)
    -- Face-up requires showdown reveal AND this is the showcase opp AND
    -- (theater-mode only) that opp is still in_seats. Without the in-seats
    -- guard a folded opp could flip face-up if opponent_idx pointed at them.
    local hd = handData(tbl)
    -- Card slots, for the deal's flights to land on.
    Anchors.set(Table.anchorKey(tbl, OPP_CARD_1[opp_idx]), cards_x, cards_y, card_w, card_h)
    Anchors.set(Table.anchorKey(tbl, OPP_CARD_2[opp_idx]), cards_x + card_w + card_gap, cards_y, card_w, card_h)
    local gate, gp_seat = dealGate(tbl, OPP_SLOT[opp_idx])
    local dy1, dy2 = cardDY(tbl, OPP_CARD_1[opp_idx]), cardDY(tbl, OPP_CARD_2[opp_idx])
    if _static and dealLive(tbl, OPP_SLOT[opp_idx]) then gate = "hidden" end
    local face_up = opponentFaceUp(tbl) and hd.opponent_idx == opp_idx
    if face_up and ss_fold and ss_fold.player_seat and ss_fold.in_seats then
        local ps = ss_fold.player_seat
        local script_seat = (opp_idx < ps) and opp_idx or (opp_idx + 1)
        if not ss_fold.in_seats[script_seat] then
            face_up = false
        end
    end
    local gate_a = 1
    if gate == "fade" then gate_a = gp_seat or 1 end
    seat_alpha = seat_alpha * gate_a
    if gate == "hidden" then
        -- In the air: the slots wait.
        drawCardSlot(cards_x, cards_y, card_w, card_h)
        drawCardSlot(cards_x + card_w + card_gap, cards_y, card_w, card_h)
    elseif face_up and hd.opponent_hole then
        drawCardFront(sl, hd.opponent_hole[1], cards_x, cards_y + dy1, card_w, card_h, seat_alpha,
                      plate, shadow)
        drawCardFront(sl, hd.opponent_hole[2], cards_x + card_w + card_gap, cards_y + dy2, card_w, card_h,
                      seat_alpha, plate, shadow)
        -- Showdown win emphasis (dim losers / grow winners) is applied later as
        -- a single on-top overlay pass in TablePanel.draw -- see
        -- drawShowdownEmphasis. The hand-name label renders under this seat.
    elseif holeVisible(tbl) then
        -- A seat that's out of the hand shows flat slabs, not deck art. The
        -- alpha dim alone left a folded seat carrying every bit of detail a
        -- live one has, so "who's still in" took a second look; two shapes
        -- side by side read instantly, and keep reading at nine pixels wide.
        local drawOne = seat_out and CardSprites.folded or nil
        if drawOne then
            drawOne(cards_x, cards_y + dy1, card_w, card_h, seat_alpha)
            drawOne(cards_x + card_w + card_gap, cards_y + dy2, card_w, card_h, seat_alpha)
        else
            drawCardBack(sl, back_sprite, cards_x, cards_y + dy1, card_w, card_h, seat_alpha, shadow,
                         back_plate)
            drawCardBack(sl, back_sprite, cards_x + card_w + card_gap, cards_y + dy2, card_w, card_h,
                         seat_alpha, shadow, back_plate)
        end
    end

    -- Dealer button. `button` is the layout's SIZE decision (nil below the
    -- diameter where a disc stops being a disc); the model says which seat
    -- holds it, and it advances ONE seat per hand — a button that jumps around
    -- is worse than no button, since moving is the whole thing it communicates.
    --
    -- Read from button_visual_seat, NOT button_seat: the latter is script space
    -- and cash re-rolls player_seat every hand, so it maps to a different drawn
    -- seat each time. Visual space is the fixed ring the panel actually draws --
    -- opponents 1..n left to right, you last.
    --
    -- Straddles the lower-LEFT corner of the seat's cards, clamped inside the
    -- seat box so it can never drift over a neighbouring seat, and on the
    -- opposite side from the bb stack label that hangs under them.
    local btn_seat = ss_fold and ss_fold.button_visual_seat
    if button and btn_seat and opp_idx == btn_seat then
        local br = button.d * 0.5
        _dealer_btn.x     = math.max(x + br, cards_x)
        _dealer_btn.y     = cards_y + card_h
        _dealer_btn.d     = button.d
        _dealer_btn.alpha = seat_alpha
    end

    -- Chip-stack tournament: render the seat's current bb stack below
    -- the cards (busted seats never reach here — they returned above as
    -- empty chairs). Cash games skip this — opponents there are visual
    -- flavor with no per-seat stack model behind them.
    if gtype and gtype.chip_stack_table and script_seat then
        local stake_for_bb = Lookups.findById(Stakes, tbl.stake_id)
        local bb_val       = (stake_for_bb and stake_for_bb.bb) or 0
        if tbl.seat_stacks and bb_val > 0 then
            local label_y = cards_y + card_h + 2
            -- Memoized on the seat: rebuilt only when the rounded bb changes.
            local bb_n = math.floor((tbl.seat_stacks[script_seat] or 0) / bb_val + 0.5)
            if opp._bb_n ~= bb_n then
                opp._bb_n, opp._bb_str = bb_n, string.format("%dbb", bb_n)
            end
            local txt = opp._bb_str
            -- Same rule as the seat name: a label that doesn't fit its
            -- seat is dropped rather than clipped mid-glyph.
            love.graphics.setFont(fonts.sm)
            if fonts.sm:getWidth(txt) <= w - 2 then
                Theme.setColor(Theme.fg.muted, seat_alpha)
                love.graphics.printf(txt, x, label_y, w, "center")
            end
        end
    end
end

-- The opponents row: every seat the layout split, with its chip-flight
-- anchor. Called by the body, and by the live layer while the seats fade
-- in after a Zoom reroll. The caller holds the backs batch and parks the
-- dealer button (_dealer_btn) around it.
local function drawOpponentRow(tbl, L, sl, fonts, back_sprite, felt_color)
    local ob = L.opponents
    if not ob then return end
    for i, seat in ipairs(ob.seats) do
        local opp = tbl.opponents[i]
        if opp then
            drawOpponentSeat(opp, i, tbl, seat.x, ob.y, seat.w, ob.h,
                sl, fonts, L.sizes, ob.cards_y_offset, back_sprite,
                ob.show_names, ob.plate, ob.shadow,
                seat.plate_rect, felt_color, L.button, ob.back_plate)
            Anchors.set(Table.anchorKey(tbl, OPP_SLOT[i]),
                seat.x + seat.w * 0.5, ob.anchor_y)
        end
    end
end

-- Draws the 5 community slots centered in the comm layout rect
-- (`{ x, y, w, card_w, card_h, gap }` from views/FeltLayout).
local function drawCommunity(tbl, comm, sl, plate)
    local hd      = handData(tbl)
    local count   = communityCardCount(tbl)
    local total_w = comm.card_w * 5 + 4 * comm.gap
    local row_x   = comm.x + math.floor((comm.w - total_w) / 2)

    for i = 1, 5 do
        local cx = row_x + (i - 1) * (comm.card_w + comm.gap)
        Anchors.set(Table.anchorKey(tbl, BOARD_SLOT[i]), cx, comm.y, comm.card_w, comm.card_h)
        local gate, gp = dealGate(tbl, BOARD_SLOT[i])
        if _static and dealLive(tbl, BOARD_SLOT[i]) then gate = "hidden" end
        if i <= count and hd.community and hd.community[i] and gate ~= "hidden" then
            local cy = comm.y + cardDY(tbl, BOARD_SLOT[i])
            if gate == "flip" then
                drawCardTurn(sl, hd.community[i], cx, cy, comm.card_w, comm.card_h, gp,
                             comm.shadow, comm.back_plate)
            else
                drawCardFront(sl, hd.community[i], cx, cy, comm.card_w, comm.card_h,
                              (gate == "fade") and gp or 1, plate, comm.shadow)
            end
        else
            drawCardSlot(cx, comm.y, comm.card_w, comm.card_h)
        end
    end
end

-- Draws the pot pile + "Pot: $X" into the `pot` layout anchor
-- (`{ center_x, chips_y, text_x, text_w, text_y, max_w, allow_chips }` from
-- views/FeltLayout). chips_y is the base chip's CENTRE and the pile grows
-- upward from it over the community row, which is by design; the layout
-- reserves only the bottom half plus the text line below it.
--
-- `allow_chips` is false once the felt is too short for a chip bigger than a
-- dot. The pot is then the number alone.
-- views/ChipPile.place and .sync copy the fields they keep (place into
-- its per-pile record, sync onto the entry), so one options table each,
-- rewritten per call, replaces the two literals per pile per frame.
-- Every field is written on every call: the pot and the stack share them.
local _place, _sync = {}, {}
local TOURNEY_PALETTE = { 1 }   -- one chip per big blind; never mutated

local function drawPotLabel(tbl, pot, fonts, anims_on)
    local pot_key = Table.anchorKey(tbl, "pot")
    -- Record the pile's spot before any early-out. The first bet of a hand
    -- is reserved into this pile on a frame where the pot is still empty
    -- and nothing below here runs, and it has to land somewhere real.
    if pot.allow_chips then
        local stake_theme_pot = StakeThemes[tbl.stake_id]
        -- A tournament's pot pile wears tournament colors and no dollar
        -- labels — the same chip vocabulary as its bet flights
        -- (views/PokerEventAnims): these chips are not money.
        local is_tourney = tbl.seat_stacks ~= nil
        local o = _place
        o.align, o.max_w = "center", pot.max_w
        -- The layout decides how wide the pot may spread: unbounded it
        -- runs a single line of chips out under the community cards.
        o.max_cols, o.max_rows = pot.max_cols, pot.max_rows
        o.scale = pot.chip_scale or 1
        o.tint  = stake_theme_pot and stake_theme_pot.chip_tint
        o.labels = not is_tourney
        -- The layout's size decision: chips, or columns on a small felt.
        o.detail = pot.detail
        ChipPile.place(pot_key, pot.center_x, pot.chips_y, o)
    else
        -- Felt too short for a chip that isn't a dot, so the pot is the number
        -- alone. The pile still needs CLEARING (it would otherwise sit there
        -- holding last hand's chips, invisible, and hand them to a detonation)
        -- and the anchor still needs a real spot, since bet flights aim at it
        -- whether or not anything is drawn when they land.
        ChipPile.clear(pot_key)
        Anchors.set(pot_key, pot.center_x, pot.chips_y)
    end

    if tbl.state == "idle" then
        RollingValue.reset(Table.rollingKey(tbl, "table_pot"))
        -- Next hand gets its pile back.
        tbl.pot_exploded       = nil
        tbl.pot_explode_pending = nil
        ChipPile.clear(pot_key)
        return
    end
    -- Pot reading. Two paths:
    --   * Theater on  → tbl.playback_state.pot is the running pot, mutated
    --                   by HandScript event applicators as bets land. Taken
    --                   RAW, zero included.
    --   * Theater off → 2 × |outcome_delta| (legacy assumption that the
    --                   pot is symmetric around the player's net delta).
    --
    -- The theater path must not fall through to the outcome_delta guess
    -- when the running pot is zero. That value is the PREVIOUS hand's, so
    -- the pot never reads as empty, and the pile below never gets the
    -- `potval <= 0` clear that ends a hand — it carries its chips into the
    -- next one and the next hand's bets pile on top of them. Harmless when
    -- the pile was a number recomputed every frame; not harmless now that
    -- it's a collection that persists.
    local potval = (tbl.playback_state and tbl.playback_state.pot) or 0

    -- What the PILE is allowed to show: chips that have actually been
    -- committed — potval, the running playback pot. NEVER outcome_delta:
    -- that's decided at deal, so it would fill the pot the instant DEAL
    -- is clicked (spoiling the hand's tier up front) and blow past what
    -- the stake's denominations can express. (A vestigial `theater`
    -- conditional lived here after the legacy table model was ripped;
    -- both of its branches had converged on potval.)
    local pile_val = potval

    local held_pot   = tbl._pot_hold and tbl._pot_hold.value
    local rolled_pot = RollingValue.get(Table.rollingKey(tbl, "table_pot"), held_pot or potval)
    -- NB: no early-out on a near-zero rolled_pot here. The pile below has
    -- to be told the pot is empty — that's the call that ends its hand —
    -- and the rolling value lags behind the real one, so bailing on it
    -- would skip exactly the frames where potval first reads zero. Only
    -- the text at the bottom of this function is suppressed.

    -- Chip pile when room permits — uses outcome_tier so stack pots
    -- visibly dwarf small ones. Text-only once the chip would be a dot.
    --
    -- The pile is a COLLECTION owned by views/ChipPile, not a breakdown of
    -- potval recomputed here every frame. Bets are reserved into it by the
    -- theater's chip flights and fill in as they land, so the pot grows
    -- with the chips arriving instead of jumping the instant they launch.
    if pot.allow_chips then
        -- Payout-aware: under the seats rule a pot can hold several
        -- stacks, which runs straight past what the stake's four-chip
        -- window can express (one top chip per unit until MAX_TOKENS
        -- clips it). Same helper the payout bursts and flights use.
        local palette = Denoms.paletteForAmount(ChipData, tbl.stake_id, pile_val)
        -- FIXED tier while the hand is live — NOT tbl.outcome_tier.
        --
        -- outcome_tier is decided at deal, and it drives the pile's chip
        -- COUNT (data/chips.lua tier_chip_target: 4 for small, 50 for
        -- stack). Composing the running pot against it means a $2 pot
        -- that is about to become a Stack sits there as fifty chips from
        -- the first blind — the pile announces the tier before a single
        -- card is dealt. The pot is worth what's been bet and should look
        -- like it; the tier is the payout's business, and the payout is
        -- what the detonation and the resolution bursts are for.
        local tier    = "medium"
        local stake_theme = StakeThemes[tbl.stake_id]
        local tint    = stake_theme and stake_theme.chip_tint
        -- The base chip is CENTERED on chips_y (the community-row bottom edge,
        -- per FeltLayout) and the pile grows UPWARD over the community cards
        -- (overlap by design). The layout reserves the base chip's lower half +
        -- the "Pot:" text BELOW chips_y, so the pile is never lifted further
        -- over the cards and the text always has clear room underneath it.
        local cs = pot.chip_scale or 1

        if pile_val > 0 then
            if tbl.seat_stacks then
                -- Tournament pot: one chip per big blind. The bet flights
                -- reserve their chips into this pile (denomination 1, one
                -- per bb), and syncing (bb count × that rung's value)
                -- keeps the reconciler agreeing with them exactly — the
                -- dollar value never touches the composition.
                local stake = Lookups.findById(Stakes, tbl.stake_id)
                local bbv   = (stake and stake.bb) or 0
                local units = (bbv > 0) and math.floor(pile_val / bbv + 0.5) or 0
                if units > 0 then
                    _sync.palette, _sync.tier = TOURNEY_PALETTE, tier
                    ChipPile.sync(pot_key, units * 0.01, _sync)
                else
                    ChipPile.clear(pot_key)
                end
            else
                _sync.palette, _sync.tier = palette, tier
                ChipPile.sync(pot_key, pile_val, _sync)
            end
        else
            ChipPile.clear(pot_key)
        end
        -- Low motion: the pile holds its street's picture (see holdPile).
        holdPile(tbl, pot_key, "_pot_hold", pile_val)

        -- Stack detonation: the pile comes apart INSTEAD of being drawn.
        -- The controller raises pot_explode_pending on a stack win; we
        -- consume it here and hand ChipFlight the pile's own chips, so the
        -- debris IS the collection that was sitting there — not a
        -- breakdown recomputed at the moment of the explosion. The debris
        -- then regroups into your stack, so the explosion IS the payout.
        --
        -- With poker theater on this never fires: the script's pot_push
        -- handler detonates at the moment the pot is pushed and sets
        -- pot_exploded itself. This is the legacy build's path.
        if tbl.pot_explode_pending and not tbl.pot_exploded and not anims_on then
            -- No theater at this size: the pot is simply gone.
            tbl.pot_explode_pending = nil
            tbl.pot_exploded = true
            ChipPile.clear(pot_key)
        elseif tbl.pot_explode_pending and not tbl.pot_exploded then
            tbl.pot_explode_pending = nil
            local debris = ChipPile.takeAll(pot_key)
            if debris then
                tbl.pot_exploded = true
                local you_key = Table.anchorKey(tbl, "you")
                -- Scale the burst to this panel (see the center anchor,
                -- stamped with the panel size each draw) so a table one of
                -- twelve doesn't detonate at the size of a solo table.
                local c = Anchors.get(Table.anchorKey(tbl, "center"))
                ChipFlight.explodeTaken(debris, {
                    tint         = tint,
                    scale        = cs,
                    dest_key     = you_key,
                    dest         = Anchors.get(you_key),
                    within       = (c and c[3] and c[4]) and { c[3], c[4] } or nil,
                    gather_sound = "chip_land_you",
                })
            end
        end

        if not tbl.pot_exploded then
            ChipPile.draw(pot_key)
        end
        Anchors.set(pot_key, pot.center_x, pot.chips_y)
    end

    -- Pot amount uses the xs tier -- it's low-priority chrome that shouldn't
    -- read as big as the cards (falls back to sm at 1×, see FontService).
    -- Hidden while there's no pot to speak of, which is what the early-out
    -- up top used to do for this whole function.
    if rolled_pot > 0.01 then
        Theme.setColor(Theme.fg.muted)
        love.graphics.setFont(fonts.xs or fonts.sm)
        -- Tournament pots are chips, not money: no dollar sign on a pot
        -- that will never be cashed. bb is the same unit the seat stacks
        -- and Depth readout already speak.
        local label
        if tbl.seat_stacks then
            local stake = Lookups.findById(Stakes, tbl.stake_id)
            local bb    = (stake and stake.bb) or 0
            if bb > 0 then
                local n = math.floor(rolled_pot / bb + 0.5)
                if tbl._potbb_n ~= n then
                    tbl._potbb_n, tbl._potbb_str = n, string.format("Pot %dbb", n)
                end
                label = tbl._potbb_str
            end
        end
        if not label then
            -- Rebuilt only when the displayed cents change.
            local cents = math.floor(rolled_pot * 100 + 0.5)
            if tbl._pot_c ~= cents then
                tbl._pot_c, tbl._pot_str = cents, "Pot: " .. Format.money(rolled_pot)
            end
            label = tbl._pot_str
        end
        -- The result floater pops in the middle of the felt, right where
        -- this sits: the label stands aside while it pops (GrindView stamps
        -- tbl._floater_pop_t each frame a floater on this table is popping).
        local popping = tbl._floater_pop_t and love.timer.getTime() - tbl._floater_pop_t < 0.1
        if not popping then
            love.graphics.printf(label, pot.text_x, pot.text_y, pot.text_w, "center")
        end
    end
end

-- Tournament bottom row for chip-stack tables: THE KO PROGRESS BAR.
--
-- One track spanning every knockout a win takes (n_seats - 1 of them),
-- divided into the paying finishes in the order the tournament reaches
-- them — 3rd first, 1st last — with each segment exactly as wide as the
-- knockouts it takes to cross it. Reaching 3rd needs five bodies and one
-- more each for 2nd and 1st, so 3rd is the long march and the money
-- places are the short sharp end.
--
-- The fill IS the tournament: one knockout, one unit, eased so a KO
-- visibly shoves it forward. Where the fill stops when the run ends is
-- the finish — flush with a boundary if you locked that place, short of
-- one if you busted before it. Green while it's money, ash when the run
-- died outside it.
-- Paying finishes, worst place first (3rd, 2nd, 1st), per (boost, seats).
-- Built and sorted once instead of every frame per tournament panel; the
-- payout tables are static data and the seat count comes from the game type.
local _ladder_finishes = {}

local function ladderFinishes(boost, n_seats)
    local per_boost = _ladder_finishes[boost]
    if not per_boost then per_boost = {}; _ladder_finishes[boost] = per_boost end
    local hit = per_boost[n_seats]
    if hit then return hit end
    local payout_table = KoPayouts[boost] or KoPayouts[0]
    local finishes = {}
    for k, mult in pairs(payout_table) do
        finishes[#finishes + 1] = { finish = n_seats - k + 1, mult = mult }
    end
    table.sort(finishes, function(a, b) return a.finish > b.finish end)
    per_boost[n_seats] = finishes
    return finishes
end

-- A chip-stack tournament's counts: seats, seats still in, and opponent
-- knockouts so far (the player's own bust ends the run and advances
-- nothing). Shared by the bottom row, the ladder and the panel cache's
-- key, so the number the key compares is the number the row prints.
local function tourneyCounts(tbl, gtype)
    local n_seats = (gtype.seats or 0) + 1
    local alive   = 0
    if tbl.seat_busted then
        for s = 1, n_seats do
            if not tbl.seat_busted[s] then alive = alive + 1 end
        end
    else
        alive = n_seats
    end
    local kos = n_seats - alive
    if tbl.seat_busted and tbl.player_seat_fixed
       and tbl.seat_busted[tbl.player_seat_fixed] then
        kos = kos - 1   -- your own bust isn't a KO you scored
    end
    return n_seats, alive, kos
end

-- The player's stack in big blinds (nil once the run is over or when the
-- table has no stacks): the Depth readout's number, and the key's.
local function depthBB(tbl)
    if tbl.last_finish then return nil end
    local stake_for_bb = Lookups.findById(Stakes, tbl.stake_id)
    local bb_val       = (stake_for_bb and stake_for_bb.bb) or 0
    if bb_val > 0 and tbl.seat_stacks and tbl.player_seat_fixed then
        local chips = tbl.seat_stacks[tbl.player_seat_fixed] or 0
        return math.floor(chips / bb_val + 0.5)
    end
    return nil
end

-- The ladder's fill target in pixels, from the counts above.
local function ladderTarget(tbl, gtype, band)
    local n_seats, _, kos = tourneyCounts(tbl, gtype)
    local total_units = n_seats - 1
    if total_units <= 0 then return nil end
    return math.min(kos, total_units) * (band.w / total_units), kos, n_seats, total_units
end

-- Is the ladder's fill still easing toward its target? The panel cache
-- draws the panel live while it is (the fill is painted into the static
-- picture, so a moving one has to be redrawn every frame).
local function ladderRolling(tbl, gtype, band)
    local target = ladderTarget(tbl, gtype, band)
    if not target then return false end
    local v = RollingValue.get(Table.rollingKey(tbl, "ko_knockouts"), target, 6)
    return math.abs(v - target) > 0.5
end

local function drawTournamentLadder(tbl, gtype, ctx, band, fonts)
    local target, kos, n_seats, total_units = ladderTarget(tbl, gtype, band)
    if not target then return end
    local boost       = (ctx and ctx.ko_payout_boost) or 0
    local finishes    = ladderFinishes(boost, n_seats)
    if #finishes == 0 then return end

    local f, fh   = fonts.sm, fonts.sm:getHeight()
    local unit_w  = band.w / total_units
    local text_y  = band.y + math.floor((band.h - fh) / 2)
    love.graphics.setFont(f)

    -- Track.
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", band.x, band.y, band.w, band.h,
                            Theme.space.radius)

    -- Fill.
    local over   = tbl.last_finish ~= nil
    local paid   = over and tbl.last_finish <= finishes[1].finish
    local fill_w = RollingValue.get(Table.rollingKey(tbl, "ko_knockouts"), target, 6)
    if fill_w > 0.5 then
        if over and not paid then
            Theme.setColor(Theme.fg.disabled, 0.9)
        else
            Theme.setColor(Theme.sem.won, over and 0.95 or 0.55)
        end
        love.graphics.rectangle("fill", band.x, band.y, fill_w, band.h,
                                Theme.space.radius)
    end

    -- Segment boundaries + labels, on top of the fill. A segment the fill
    -- has fully crossed is a finish you've locked; its label brightens.
    local function shortPos(p)
        if p == 1 then return "1st" elseif p == 2 then return "2nd"
        elseif p == 3 then return "3rd" else return p .. "th" end
    end
    local left_units = 0
    for _, e in ipairs(finishes) do
        local right_units = n_seats - e.finish   -- KOs that lock this place
        local seg_x = band.x + left_units * unit_w
        local seg_w = (right_units - left_units) * unit_w
        -- Shed ladder: "3rd:3x" → "3rd" → nothing. Dropped, never clipped.
        local full, short = string.format("%s:%dx", shortPos(e.finish), e.mult),
                            shortPos(e.finish)
        local label
        if f:getWidth(full) <= seg_w - 4 then label = full
        elseif f:getWidth(short) <= seg_w - 4 then label = short end
        if label then
            Theme.setColor(kos >= right_units and Theme.fg.heading
                                              or Theme.fg.muted)
            love.graphics.printf(label, seg_x, text_y, seg_w, "center")
        end
        if right_units < total_units then
            Theme.setColor(Theme.border.soft)
            love.graphics.line(seg_x + seg_w, band.y,
                               seg_x + seg_w, band.y + band.h)
        end
        left_units = right_units
    end

    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", band.x, band.y, band.w, band.h,
                            Theme.space.radius)

    Anchors.set(Table.anchorKey(tbl, "you"), band.x + band.w * 0.5, band.y + band.h * 0.5)
end

-- The player's RUNNING stack through a theater hand: what they sat down with,
-- minus what they've pushed in, plus the pot if they've just been pushed it.
-- tbl.stack itself doesn't move until the table enters settling and the
-- controller applies the resolution — so reading it raw mid-hand would claim
-- the player still holds the chips they bet.
--
-- Crossing pot_push has to stay CONTINUOUS. Falling back to tbl.stack there
-- (what this used to do the moment a winner was set) jumps the number back up
-- for the second or so between the pot pushing and the resolution landing, and
-- the pile would tidy down to it and straight back up again.
local function displayStack(tbl)
    local stack = tbl.stack or 0
    local pbs   = tbl.playback_state
    if pbs and tbl.state ~= "idle" and tbl.state ~= "settling" then
        local seat      = pbs.player_seat
        local committed = (seat and pbs.per_seat_total and pbs.per_seat_total[seat]) or 0
        -- Winning credits the pot PLUS your own bets back. Under the
        -- pot-is-what-you-win sizing (Table:deal's effective_bb), the
        -- pot equals the payout, so the reconciliation at settling
        -- (raw stack + delta) is exactly -committed + committed + pot —
        -- continuous, no snap.
        local won = (seat and pbs.winner == seat
                     and ((pbs.pot_at_push or 0) + committed)) or 0
        return math.max(0, stack - committed + won)
    end
    return stack
end

-- The bottom-left money line, in the form the layout picked. "Tied up" is the
-- same term as the top-bar TIED UP cell, which is the sum of these (NOT
-- "Stack": that word is the win/loss tier). The printed number rolls toward
-- its target (top-bar money feel); the pile above stays on the raw value so
-- its denominations don't reshuffle every frame mid-roll.
--
-- Called twice per frame — once to MEASURE before the layout runs, once to
-- draw. RollingValue eases by wall-clock delta, so the second call in a frame
-- advances by ~0 and returns the value the first one measured.
local function tiedText(tbl, parts)
    local rolled = RollingValue.get(Table.rollingKey(tbl, "table_tied"), displayStack(tbl))
    -- Both forms rebuilt together, only when the displayed cents change:
    -- this runs three times per table per frame and most tables are at
    -- rest.
    local cents = math.floor(rolled * 100 + 0.5)
    if tbl._tied_c ~= cents then
        local money = Format.money(rolled)
        tbl._tied_c, tbl._tied_short, tbl._tied_full = cents, money, "Tied up  " .. money
    end
    if parts == "short" then return tbl._tied_short end
    return tbl._tied_full
end

-- Is the printed number still rolling toward its target? A STATIC render
-- leaves the line blank while it rolls (every frame's digits would be a
-- rebuild) and drawLive prints it; the key holds the roll as one value.
local function tiedRolling(tbl)
    local target = math.floor(displayStack(tbl) * 100 + 0.5)
    return tbl._tied_c ~= target
end

-- Renders the player seat into the layout `hole` rect (centered hole cards +
-- showdown hand-name) and `bottom` anchors (chip pile + its $ amount at the
-- felt LEFT edge — both from views/FeltLayout; the EV readout takes the
-- right edge later in :draw). Tournament tables draw their ladder as a
-- single row in the bottom band (bottom.band). `tied_anchor_key` (e.g.
-- "tied:1") registers the "Tied up $X" label as a hint-anchor.
-- The stack anchor's rect, handed from the pile to the tied-up label
-- within one drawPlayerSeat. One scratch, flagged on: it was a table per
-- panel per frame.
local _ssa = { on = false, key = nil, x = 0, y = 0, w = 0 }

-- The player's stack pile: placed, synced and held every frame (a flight
-- has to find the pile whether or not the panel draws it this frame),
-- with the "you" anchor and, when `idx` is given, the stack anchor's rect
-- for the tied-up label. Drawing is the caller's: the panel cache paints
-- a quiet pile into the static picture and a moving one live over it
-- (views/TablePanel.draw), so the bookkeeping and the draw are split.
-- Returns the pile's key.
local function youPileSync(tbl, bottom, idx)
    -- displayStack / tiedText live at module scope so TablePanel.draw can
    -- MEASURE the tied-up line before the layout runs (the felt sheds the
    -- "Tied up" label when the row is too narrow to hold it beside the EV
    -- readout) and hand the exact same string back here to draw.
    local display_stack = displayStack(tbl)

    -- No hold-back ledger any more: the pile no longer follows the scalar
    -- while chips are in the air. Chips the player bets are TAKEN out of
    -- this collection and chips they win are RESERVED into it, so it is
    -- already showing exactly what has actually arrived. It reconciles
    -- against display_stack only once everything has landed (rake, rebuys,
    -- anything that moves the number without a flight) — see ChipPile.sync.
    local you_key = Table.anchorKey(tbl, "you")
    local palette = Denoms.paletteForAmount(ChipData, tbl.stake_id, display_stack)
    local stake_theme = StakeThemes[tbl.stake_id]
    local tint        = stake_theme and stake_theme.chip_tint
    -- The pile's base chip is centered on its y; offset up by the (scaled)
    -- chip radius so the pile's visual BOTTOM sits on the tied-up baseline.
    -- The pile scales with the cards (bottom.chip_scale) to stay proportional.
    local cs     = bottom.chip_scale or 1
    local pile_y = bottom.chips.y - Chips.radius() * cs

    local o = _place
    o.align, o.max_w, o.scale, o.tint = "left", bottom.chips.max_w, cs, tint
    o.max_cols, o.max_rows = bottom.chips.max_cols, bottom.chips.max_rows
    o.detail, o.labels = bottom.detail, nil
    ChipPile.place(you_key, bottom.chips.x, pile_y, o)
    -- "medium" target (~12 chips) keeps the pile compact regardless of stake.
    _sync.palette, _sync.tier = palette, "medium"
    ChipPile.sync(you_key, display_stack, _sync)
    holdPile(tbl, you_key, "_stack_hold", display_stack)

    if ChipPile.count(you_key) > 0 then
        Anchors.set(you_key, bottom.chips.x + 18, pile_y)
    else
        Anchors.set(you_key, bottom.chips.x, bottom.chips.y)
    end
    -- The pile AND its tied-up label as one tight RECT anchor
    -- ("stack:<idx>") for story marks: as wide as the chips actually laid
    -- out (or the label, whichever is wider), from the top chip down to
    -- the label's baseline. Registered after the label below, which sets
    -- _ssa for it.
    if idx then
        local fw, fh = ChipPile.footprint(you_key)
        local pad    = math.floor(4 * (cs or 1))
        _ssa.on  = true
        _ssa.key = STACK_KEY[idx]
        _ssa.x   = bottom.chips.x - pad
        _ssa.y   = pile_y - Chips.radius() * cs - math.max(0, fh * cs - Chips.radius() * cs * 2) - pad
        _ssa.w   = fw * cs + pad * 2
    end
    return you_key
end

-- `mode` is the render mode (STATIC paints only a quiet pile; the moving
-- one is drawn live by TablePanel.draw).
local STATIC_MODE = 2
local function drawPlayerSeat(tbl, hole, bottom, sl, fonts, ctx, idx, button, mode)
    local tied_anchor_key = idx and TIED_KEY[idx]
    local card_w  = hole.card_w
    local card_h  = hole.card_h
    local cards_w = card_w * 2 + hole.gap
    local cards_x = hole.x + math.floor((hole.w - cards_w) / 2)
    local cards_y = hole.y

    local hd = handData(tbl)
    Anchors.set(Table.anchorKey(tbl, "cards_you_1"), cards_x, cards_y, card_w, card_h)
    Anchors.set(Table.anchorKey(tbl, "cards_you_2"), cards_x + card_w + hole.gap, cards_y, card_w, card_h)
    local gate, gp = dealGate(tbl, "you")
    if _static and dealLive(tbl, "you") then gate = "hidden" end
    local ydy1, ydy2 = cardDY(tbl, "cards_you_1"), cardDY(tbl, "cards_you_2")
    if gate == "hidden" then
        drawCardSlot(cards_x, cards_y, card_w, card_h)
        drawCardSlot(cards_x + card_w + hole.gap, cards_y, card_w, card_h, 1)
    elseif gate == "flip" and hd.player_hole then
        drawCardTurn(sl, hd.player_hole[1], cards_x, cards_y + ydy1, card_w, card_h, gp, hole.shadow,
                     hole.back_plate)
        drawCardTurn(sl, hd.player_hole[2], cards_x + card_w + hole.gap, cards_y + ydy2, card_w, card_h, gp,
                     hole.shadow, hole.back_plate)
    elseif holeVisible(tbl) and hd.player_hole then
        local a = (gate == "fade") and gp or 1
        drawCardFront(sl, hd.player_hole[1], cards_x, cards_y + ydy1, card_w, card_h, a,
                      hole.plate, hole.shadow)
        drawCardFront(sl, hd.player_hole[2], cards_x + card_w + hole.gap, cards_y + ydy2, card_w, card_h, a,
                      hole.plate, hole.shadow)
        -- Showdown win emphasis (dim losers / grow winners) is applied later as
        -- a single on-top overlay pass in TablePanel.draw (drawShowdownEmphasis).
    else
        drawCardSlot(cards_x, cards_y, card_w, card_h)
        drawCardSlot(cards_x + card_w + hole.gap, cards_y, card_w, card_h, 1)
    end

    -- Dealer button when it's on YOUR seat. In visual space you are the LAST
    -- seat (opponents are 1..n, drawn left to right, you are below them), which
    -- is where the button lands after it walks off the right-hand seat. Same
    -- lower-left placement the opponent seats use, so the disc means one thing
    -- wherever it sits.
    local pbs = seatState(tbl)
    if button and pbs and pbs.button_visual_seat
       and pbs.button_visual_seat == (#tbl.opponents + 1) then
        FeltDecor.drawButton(math.max(hole.x + button.d * 0.5, cards_x),
                             cards_y + card_h, button.d, 1)
    end

    local gtype = Lookups.findById(GameTypes,tbl.game_type_id)

    -- Chip-stack tournaments: alive/FINISH counter at the felt LEFT edge,
    -- Depth Nbb at the RIGHT edge, finish-position pip strip below — all in
    -- the bottom band.
    if gtype and gtype.chip_stack_table then
        -- Alive/Depth labels sit just ABOVE the pip band (the band itself is
        -- one thin row filled by the pips).
        local label_y = bottom.band.y - fonts.sm:getHeight() - 2
        local font    = fonts.sm
        love.graphics.setFont(font)

        local n_seats, alive, kos = tourneyCounts(tbl, gtype)
        -- The number that matters in a KO tournament is KNOCKOUTS — the
        -- same unit the progress bar below fills by. Once the field is
        -- down to the paying positions the label stops counting and says
        -- the thing a tournament player is actually watching for.
        local pays = 0
        do
            local payout_table = KoPayouts[(ctx and ctx.ko_payout_boost) or 0]
                                 or KoPayouts[0]
            for _ in pairs(payout_table) do pays = pays + 1 end
        end
        local counter_label
        local counter_color = Theme.fg.heading
        if tbl.last_finish then
            counter_label = string.format("FINISH %s", ordinal(tbl.last_finish))
        elseif pays > 0 and alive <= pays then
            counter_label = "IN THE MONEY"
            counter_color = Theme.sem.won
            -- Shrink-then-drop: the short form before no form at all.
            if font:getWidth(counter_label) > bottom.inner_w * 0.6 then
                counter_label = "PAID"
            end
        else
            if tbl._ko_n ~= kos then
                tbl._ko_n, tbl._ko_str = kos, string.format("%d KO", kos)
            end
            counter_label = tbl._ko_str
        end

        -- Tournament chips aren't reclaimable cash, so not "Tied up" —
        -- "Depth" is the poker term for a stack in bb.
        local depth_full, depth_short
        local bb = depthBB(tbl)
        if bb then
            if tbl._depth_n ~= bb then
                tbl._depth_n     = bb
                tbl._depth_short = string.format("%dbb", bb)
                tbl._depth_full  = "Depth  " .. tbl._depth_short
            end
            depth_short, depth_full = tbl._depth_short, tbl._depth_full
        end

        -- Same shed as the cash row: two edge-anchored strings on one line with
        -- no smaller font to fall back on, so the right-hand one gives up its
        -- label and then leaves rather than running into the counter.
        Theme.setColor(counter_color)
        love.graphics.print(counter_label, bottom.chips.x, label_y)
        if depth_full then
            local left_w = font:getWidth(counter_label)
            for _, txt in ipairs({ depth_full, depth_short }) do
                local tw = font:getWidth(txt)
                local t  = BandStack.threeUp(bottom.inner_w, left_w, tw, 0, bottom.pad)
                if t.center_show then
                    love.graphics.print(txt, bottom.right_x - tw, label_y)
                    break
                end
            end
        end
        drawTournamentLadder(tbl, gtype, ctx, bottom.band, fonts)
        return
    end

    -- Cash: chip pile + its $ amount hug the felt LEFT edge; the EV
    -- readout takes the RIGHT edge (drawn later from L.bottom.ev).
    local you_key = youPileSync(tbl, bottom, tied_anchor_key and idx or nil)
    -- A still pile is part of the resting picture; a moving one (chips in
    -- the air, a settle, a low-motion hold) is drawn live over the blit.
    if mode ~= STATIC_MODE or ChipPile.quiet(you_key) then
        ChipPile.draw(you_key)
    end

    -- "Tied up $X.XX" on the bottom line beneath the pile it prices — the
    -- same term as the top-bar TIED UP cell, which is the sum of these
    -- (NOT "Stack": that word is the win/loss tier). The printed number
    -- rolls toward its target (top-bar money feel); the pile above stays
    -- on the raw value so its denominations don't reshuffle every frame
    -- mid-roll.
    --
    -- The label goes first when the row is tight: it is chrome, and the
    -- number's position under the pile already says what it prices.
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.sm)
    local tied_str = tiedText(tbl, bottom.tied.parts)
    if not (_static and tiedRolling(tbl)) then
        love.graphics.print(tied_str, bottom.tied.x, bottom.tied.y)
    end
    if tied_anchor_key then
        local tw, th = fonts.sm:getWidth(tied_str), fonts.sm:getHeight()
        Anchors.set(tied_anchor_key, bottom.tied.x, bottom.tied.y, tw, th)
        local a = _ssa
        if a.on then
            local right = math.max(a.x + a.w, bottom.tied.x + tw + 2)
            Anchors.set(a.key, a.x, a.y, right - a.x, (bottom.tied.y + th) - a.y)
            a.on = false
        end
    end
end

-- Shared felt-overlay button (DEAL when stacked, REBUY $X when busted).
-- The variant is decided in :draw based on tbl.stack; this just renders.
local DEAL_BTN_DEPTH = 4

-- Pick the felt-button font and text that fit inside the button face
-- (`fw` × `fh`). `label` is a string or a list of progressively shorter
-- strings (REBUY passes the exact price, the compact price, then the bare
-- verb). Tries every label at every real font size, largest first, and
-- takes the first fit. Text is NEVER scaled: a held size is always a
-- rasterized font (xs/sm/md), never a blit of a bigger one. Returns
-- (font, text, text_x, text_y). Shared between the live render and the
-- press-then-vanish ghost so both pick identically.
-- The label list and the font ladder are two module scratches with a
-- count each: they were two tables per felt button per frame.
local _pf_labels, _pf_ladder = {}, {}
local function _pickFeltButtonFont(label, fonts, fx, fy, fw, fh)
    local pad   = 8
    local avail = math.max(1, fw - pad)
    local labels, nl
    if type(label) == "table" then
        labels, nl = label, #label
    else
        _pf_labels[1] = label
        labels, nl = _pf_labels, 1
    end
    local ladder, nf = _pf_ladder, 0
    if fh >= 32 and fonts.md then nf = nf + 1; ladder[nf] = fonts.md end
    nf = nf + 1; ladder[nf] = fonts.sm
    if fonts.xs then nf = nf + 1; ladder[nf] = fonts.xs end
    local pick_font, pick_text
    for i = 1, nl do
        local text = labels[i]
        for j = 1, nf do
            local font = ladder[j]
            if font:getWidth(text) <= avail then
                pick_font, pick_text = font, text
                break
            end
        end
        if pick_font then break end
    end
    if not pick_font then
        -- Nothing fits even shortened: smallest font, shortest text,
        -- centred and overflowing rather than shrunk.
        pick_font, pick_text = ladder[nf], labels[nl]
    end
    local tw, th = pick_font:getWidth(pick_text), pick_font:getHeight()
    local text_x = fx + math.floor((fw - tw) / 2)
    local text_y = fy + math.floor((fh - th) * 0.5)
    return pick_font, pick_text, text_x, text_y
end

local function _drawFeltButtonLabel(label, fonts, fx, fy, fw, fh, enabled)
    local font, text, text_x, text_y = _pickFeltButtonFont(label, fonts, fx, fy, fw, fh)
    love.graphics.setFont(font)
    Theme.setColor(enabled and Theme.bg.window or Theme.fg.disabled)
    love.graphics.print(text, text_x, text_y)
end

-- Render the chunky DEAL/REBUY button at (bx, by, btn_w, btn_h). Used both
-- by the live render path and by the press-then-vanish ghost path, so the
-- ghost matches the live button pixel-for-pixel.
-- The label painter reads these, set just before Button.draw calls it.
local _fb_label, _fb_fonts, _fb_enabled = nil, nil, false
local function feltButtonLabel(fx, fy, fw, fh)
    _drawFeltButtonLabel(_fb_label, _fb_fonts, fx, fy, fw, fh, _fb_enabled)
end
local function _renderFeltButton(bx, by, btn_w, btn_h, fonts, label, fill_color,
                                  enabled, hovered, press)
    _fb_label, _fb_fonts, _fb_enabled = label, fonts, enabled
    Button.draw(bx, by, btn_w, btn_h,
        btnOpts(fill_color,
                enabled and Theme.fg.heading or Theme.border.soft,
                hovered, press, not enabled, DEAL_BTN_DEPTH, Theme.space.line_strong),
        feltButtonLabel)
end

-- Felt-overlay button: visual button stays centered for affordance (still
-- chunky and obviously clickable), but the hit_box now covers the entire
-- felt rect — so the player can click anywhere on the table to fire the
-- DEAL / REBUY action. The CursorPool still finds the same `action="deal"`
-- entries and clicks at the rect's center, which sits over the visual
-- button so the click animation feels natural.
local function drawFeltButton(tbl, x, y, w, h, fonts, hit_boxes, idx, label, action, fill_color, enabled, table_id, label_cy)
    -- ONE deal-ready overlay for every idle table; `label_cy` is only a
    -- layout param (the residue's pot gap, a number, nil without residue).
    -- With the last hand still on the felt the button moves out of the
    -- cards (vertically centered on the pot gap instead of the felt
    -- center) — everything else (felt-wide hover wash, rim, hit box,
    -- tooltip, anchors, ghosting, cursor tagging) is identical whether or
    -- not a hand has been dealt before.
    local btn_w = math.min(DEAL_BTN_W, w - 16)
    local btn_h = math.min(DEAL_BTN_H, h - 8)
    if btn_w < 40 then btn_w = math.max(20, w - 4) end
    if btn_h < 18 then btn_h = math.max(14, h - 4) end
    local bx = x + math.floor((w - btn_w) / 2)
    -- A refused REBUY shakes (its press key, services/ClickFX).
    bx = bx + (Poke.offset(HIT_POKE[ACTION_KEY[action][table_id or idx]]))
    local by
    if label_cy then
        by = math.floor(label_cy - btn_h / 2)
        by = math.max(y + 2, math.min(by, y + h - btn_h - 2))
    else
        by = y + math.floor((h - btn_h) / 2)
    end
    -- Hint-anchor on the visual button ("deal:1", "rebuy:3", ...). Goes
    -- stale while a hand plays (button hidden) — fine, hints keyed to it
    -- complete on the click that hides it. "rebuy:any" aliases whichever
    -- busted table drew last, so a hint can point at "a" rebuy button
    -- without knowing the panel index.
    Anchors.set(ACTION_KEY[action][idx], bx, by, btn_w, btn_h)
    if action == "rebuy" then
        Anchors.set("rebuy:any", bx, by, btn_w, btn_h)
    end
    -- Hover/flash key: table_id when provided (reorder-proof; matches the
    -- writers in GrindView). The hint ANCHOR above stays index-keyed on
    -- purpose — data/hints.lua targets "deal:1" literally.
    local fid     = ACTION_KEY[action][table_id or idx]
    -- Dwell, not instant: the whole felt is the hover target, so a mouse
    -- sweeping across the board would light every table it crosses. The
    -- wash waits for the pointer to actually rest here.
    local hovered = enabled and Hover.dwell("hit", fid)
    local press   = enabled and ClickFlash.alpha("hit", fid) or 0

    -- Felt-wide hover wash + rim: EVERY deal-ready felt, residue or not.
    -- The hit_box below is the whole felt on every table, so the visual
    -- affordance must match everywhere — when only residue tables showed
    -- the wash, the fresh ones looked broken on hover. (Style keys live
    -- under FeltStyle.residue for history; they are the deal-overlay
    -- style, not a residue-only one.)
    local RS = FeltStyle.residue or {}
    if hovered or press > 0 then
        Theme.setColor(fill_color, (RS.wash_hover or 0.10) + press * 0.15)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    end
    -- Rim just inside the felt edge, in the action's color.
    local rim_a = hovered and (RS.rim_hover or 0.90) or (RS.rim_alpha or 0.25)
    if not enabled then rim_a = rim_a * 0.5 end
    Theme.setColor(fill_color, math.min(1, rim_a + press * 0.5))
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2, Theme.space.radius)
    love.graphics.setLineWidth(1)
    _renderFeltButton(bx, by, btn_w, btn_h, fonts, label, fill_color,
                      enabled, hovered, press)

    if enabled then
        local hb = hbNew(tbl, hit_boxes)
        -- Full felt rect — click-anywhere semantics. Visual button
        -- stays centered above for affordance.
        hb.x, hb.y, hb.w, hb.h = x, y, w, h
        -- Visual rect (where the chunky button sits) so ghost-fade
        -- animations on click can render the button shape correctly
        -- after the hit_box vanishes.
        hb.visual_x, hb.visual_y, hb.visual_w, hb.visual_h = bx, by, btn_w, btn_h
        hb.action, hb.idx, hb.table_id = action, idx, table_id
        hb.label, hb.fill_color = label, fill_color
        -- DEAL says nothing (the button says it); REBUY says it also deals.
        hb.tooltip = (action == "rebuy") and "Refill the stack and deal the next hand." or nil
        return hb
    end
end

-- Drop the unused inline ghost factory; TablePanel.makeGhostFor below is
-- the public entry point for ephemeral-button ghost-rendering.

-- ─── Per-table FX (shake / vignette / felt light / border-pulse) ────
-- All bounded so adjacent panels in the grid don't get encroached on.
-- Implementations live in views/TablePanelEffects (sibling-module split,
-- mirrors views/TablePanelStats). State decays in models/Table.lua:update;
-- the effects layer just reads tween fields. Nothing here moves the
-- panel during a hand: the close X, the chrome bar and the tooltip hover
-- areas stay put while cursors deal around them.
local REST_SHADOW = { lift_t = 0 }

-- ─── Ghost factory (press-then-vanish for ephemeral buttons) ─────────
-- Builds a Ghosts.add render closure for a hit_box that's about to vanish
-- (DEAL→dealing state, REBUY→stack refilled, [×]→table removed). The
-- closure captures the rect + label + fill so the ghost matches the live
-- button exactly, and replays the press rise-out animation while the
-- underlying render path is gone.
--
-- Returns nil for actions that don't need ghost-fade (stake-up, [C], etc.
-- — those persist after click and animate via the live ClickFlash path).
-- Per-action ghost style. Functions are called per-frame so the Theme
-- token reads pick up palette swaps. Actions absent here yield no ghost.
local GHOST_STYLES = {
    deal         = function() return 4, Theme.bg.window  end,
    rebuy        = function() return 4, Theme.bg.window  end,
    remove_table = function() return 2, Theme.fg.heading end,
}

function TablePanel.makeGhostFor(hb, fonts)
    if not (hb and hb.action and hb.label) then return nil end

    local style_fn = GHOST_STYLES[hb.action]
    if not style_fn then return nil end
    local depth, label_color = style_fn()

    -- DEAL / REBUY hit_boxes carry visual_* fields for the actual button
    -- rect (which sits centered inside the full felt — the felt is the
    -- click area, the button is the visual). Fall back to hb.x/y/w/h for
    -- other actions (remove_table) that don't split the two.
    local rx = hb.visual_x or hb.x
    local ry = hb.visual_y or hb.y
    local rw = hb.visual_w or hb.w
    local rh = hb.visual_h or hb.h
    local label, fill   = hb.label, hb.fill_color or Theme.bg.widget_hover
    local border_color  = Theme.fg.heading

    -- DEAL / REBUY ghosts share the live felt-button label renderer so
    -- the auto-fit (sm fallback + scale-blit) matches pixel-for-pixel
    -- between live and ghost. Without this the ghost picks fonts.md
    -- whenever the face is tall enough — even on labels the live
    -- button had to scale-blit down — and the text appears to "grow"
    -- on click before fading out.
    local use_felt_label = (hb.action == "deal" or hb.action == "rebuy")

    return function(alpha)
        -- Ghosts decays alpha 1 → 0 over ~0.5 s. Mapping straight to
        -- press_alpha gives the rise-out animation: press_alpha=1 at click
        -- (face flat), press_alpha=0 at despawn (face at rest, then ghost
        -- removed). No fade — the rise IS the visual, then it just stops.
        Button.draw(rx, ry, rw, rh, {
            fill_color   = fill,
            border_color = border_color,
            press_alpha  = alpha,
            depth        = depth,
        }, function(fx, fy, fw, fh)
            if use_felt_label then
                _drawFeltButtonLabel(label, fonts, fx, fy, fw, fh, true)
            else
                local font = (fh >= 32) and fonts.md or fonts.sm
                love.graphics.setFont(font)
                Theme.setColor(label_color)
                love.graphics.printf(label, fx,
                                     fy + math.floor((fh - font:getHeight()) * 0.5),
                                     fw, "center")
            end
        end)
    end
end

-- Gather the on-screen rect of every FACE-UP card (community + player hole +
-- the revealed showcase opponent's hole), recomputing the exact same
-- positions the draw functions used. Pure geometry — no rendering — so the
-- emphasis pass can re-target each card after everything else has drawn.
-- Cached on the table: the list and its entries are rewritten in place,
-- and only when the hand on the felt, the layout, the board count, the
-- hand's revision, the script's position or the state has moved (the
-- reveal flags and fold flags all ride on those). A showdown panel was
-- otherwise building seven tables a frame.
local function shownPut(out, n, card, x, y, w, h, plate, shadow)
    n = n + 1
    local e = out[n]
    if not e then e = {}; out[n] = e end
    e.card, e.x, e.y, e.w, e.h, e.plate, e.shadow = card, x, y, w, h, plate, shadow
    return n
end
local function collectShownCards(tbl, L)
    local hd    = handData(tbl)
    local count = communityCardCount(tbl)
    local out   = tbl._shown
    if out and tbl._shown_hd == hd and tbl._shown_L == L and tbl._shown_n == count
       and tbl._shown_rev == tbl.view_rev and tbl._shown_si == tbl.script_idx
       and tbl._shown_st == tbl.state then
        return out
    end
    if not out then out = {}; tbl._shown = out end
    tbl._shown_hd, tbl._shown_L, tbl._shown_n = hd, L, count
    tbl._shown_rev, tbl._shown_si, tbl._shown_st = tbl.view_rev, tbl.script_idx, tbl.state
    local n = 0
    if L.community then
        local comm    = L.community
        local total_w = comm.card_w * 5 + 4 * comm.gap
        local row_x   = comm.x + math.floor((comm.w - total_w) / 2)
        for i = 1, count do
            if hd.community and hd.community[i] then
                n = shownPut(out, n, hd.community[i],
                    row_x + (i - 1) * (comm.card_w + comm.gap),
                    comm.y, comm.card_w, comm.card_h, comm.plate, comm.shadow)
            end
        end
    end
    if L.hole and holeVisible(tbl) and hd.player_hole then
        local hole    = L.hole
        local cards_w = hole.card_w * 2 + hole.gap
        local cards_x = hole.x + math.floor((hole.w - cards_w) / 2)
        n = shownPut(out, n, hd.player_hole[1], cards_x,
                     hole.y, hole.card_w, hole.card_h, hole.plate, hole.shadow)
        n = shownPut(out, n, hd.player_hole[2], cards_x + hole.card_w + hole.gap,
                     hole.y, hole.card_w, hole.card_h, hole.plate, hole.shadow)
    end
    -- Only the revealed, in-seat showcase opponent shows hole cards.
    local oi = hd.opponent_idx
    if oi and L.opponents and L.opponents.seats[oi] and hd.opponent_hole and opponentFaceUp(tbl) then
        local reveal = true
        local ss_st = seatState(tbl)
        if ss_st and ss_st.player_seat and ss_st.in_seats then
            local ps = ss_st.player_seat
            local ss = (oi < ps) and oi or (oi + 1)
            if not ss_st.in_seats[ss] then reveal = false end
        end
        if reveal then
            local ob      = L.opponents
            local seat    = ob.seats[oi]
            local big     = tbl.game_type_id == "hu"
            local cw      = big and (L.sizes.opp_w * 2) or L.sizes.opp_w
            local ch      = big and (L.sizes.opp_h * 2) or L.sizes.opp_h
            local cgap    = big and 6 or 3
            local cards_w = cw * 2 + cgap
            local cards_x = seat.x + math.floor((seat.w - cards_w) / 2)
            local cards_y = ob.y + ob.cards_y_offset
            n = shownPut(out, n, hd.opponent_hole[1], cards_x, cards_y,
                         cw, ch, ob.plate, ob.shadow)
            n = shownPut(out, n, hd.opponent_hole[2], cards_x + cw + cgap, cards_y,
                         cw, ch, ob.plate, ob.shadow)
        end
    end
    for i = #out, n + 1, -1 do out[i] = nil end
    return out
end

-- Showdown emphasis. The "which cards won" signal, drawn after every card and
-- animation pass so nothing buries it: cards NOT in the winning five are dimmed
-- (board + both holes), and the winning cards stay lit and ENLARGED with a
-- brief pop on reveal. No borders. `win5` is the winner's best-5 hand
-- (player_combo on a player win, opponent_combo on an opp win).
local function drawShowdownEmphasis(tbl, L, sl, win5)
    if not win5 then return end
    local shown = collectShownCards(tbl, L)
    if #shown == 0 then return end

    -- Pass 1: dim the cards that did NOT make the winning hand.
    for _, c in ipairs(shown) do
        if not inCombo(c.card, win5) then
            Theme.setColor(Theme.bg.window, 0.62)
            love.graphics.rectangle("fill", c.x, c.y, c.w, c.h, Theme.space.radius)
        end
    end
    -- Pass 2: the winning cards stay full-bright and enlarged, with a single
    -- POP at the reveal that eases back to the steady size. state_timer is the
    -- per-state clock and resets on every phase change, so it would re-fire the
    -- pop when chips move (settling). Gate it OFF during settling: the pop plays
    -- once on the showdown reveal, then the cards just hold their enlarged size
    -- through the chip move (same scale at the boundary -> no snap).
    local st    = tbl.state_timer or 0
    -- Also gated off at idle: _finalizeHand resets state_timer, so the
    -- residue would re-fire the pop the frame the table went idle.
    local pop   = (tbl.state ~= "settling" and tbl.state ~= "idle")
                  and Pop.fromTimer(st, 0.25) or 0
    -- At idle the winning five drop back to TRUE size: the residue felt
    -- has to read as the same deal-ready table as a fresh one, and cards
    -- held oversized overlap their neighbours on small panels. Color
    -- (bright five vs grey dead cards) carries the result at rest; the
    -- enlargement is a live-showdown treatment only.
    local rest  = (tbl.state == "idle") and 1.0 or 1.13
    local scale = Pop.scale(pop, rest, 0.13)      -- pops to ~1.26 at reveal
    for _, c in ipairs(shown) do
        if inCombo(c.card, win5) then
            local gw, gh = c.w * scale, c.h * scale
            local gx = c.x - (gw - c.w) / 2
            local gy = c.y - (gh - c.h) / 2
            -- Shadow travels with the pop. The un-popped card's shadow is
            -- still on the felt underneath at the old offset, so redrawing it
            -- under the enlarged card is what covers it.
            CardSprites.shadow(gx, gy, gw, gh, 1, c.shadow)
            CardSprites.front(sl, c.card, gx, gy, gw, gh, 1, c.plate)
        end
    end
end

-- ─── Two passes: prepare (the sheet) and draw (the frame) ────────────
--
-- Pass A, TablePanel.prepare, runs for every panel on the board between
-- sheetBegin and sheetEnd (views/GrindView._drawCenterGrid): it stamps
-- the model, plays the hand's script events, classifies the panel
-- (bypass: something on it is animating; cached: it is at rest), and for
-- a cached panel whose dirty key moved renders the static layers into the
-- panel's slot of the sheet (views/PanelSheet), recording the anchors and
-- hit boxes that render sets. Pass B, TablePanel.draw, does the
-- transforms and the per-frame anchors, then either draws the whole panel
-- (bypass, the held panel, a size the sheet does not hold, or the cache
-- off) or blits the slot and draws the live layers over it: the stack pile
-- while it moves, the pot, the status FX. The kill switch is
-- Constants.FEATURES.PANEL_CACHE; off, draw is the single pass that
-- shipped before.

local IMMEDIATE = 1          -- renderBody: today's order and pixels
local STATIC    = STATIC_MODE -- renderBody: the live layers skipped
local MODE_BYPASS, MODE_CACHED = 1, 2

-- The frame stamp: sheetBegin bumps it, prepare stamps the table with it
-- (tbl._pf), and draw trusts a prepared entry only from the same frame.
local _frame    = 0
local _sheet_ok = false

-- Per-panel scale dominates: when the grid crams 18 panels into a window,
-- each panel might render at ~340×190 — chrome should shrink with that,
-- not stay sized for the full window. Capped by ui_scale so a lone panel
-- on a 4K window doesn't grow past what the window-scale font budget
-- supports. Writes the module's layout constants; returns (s, ui_s).
local function setScale(w, h, game)
    local ui_s = (game and game.ui_scale) or 1
    local panel_s = math.min(w / PANEL_BASE_W, h / PANEL_BASE_H)
    local s = math.min(ui_s, panel_s)
    -- Header has to remain tall enough to hold fonts.sm + tiny padding,
    -- otherwise the per-panel scale-down crushes header text into a
    -- band that's literally shorter than a glyph.
    local fonts = game and game.fonts
    local sm_h  = (fonts and fonts.sm and fonts.sm:getHeight()) or 12
    HEADER_H        = math.max(sm_h + 4, math.floor(HEADER_H_BASE   * s))
    FELT_INSET      = math.max(1, math.floor(FELT_INSET_BASE * s))
    REMOVE_BTN_SIZE = math.max(sm_h + 2, math.floor(REMOVE_BTN_BASE * s))
    DEAL_BTN_W      = math.max(40, math.floor(DEAL_BTN_W_BASE * s))
    DEAL_BTN_H      = math.max(sm_h + 6, math.floor(DEAL_BTN_H_BASE * s))
    return s, ui_s
end

-- Stash the panel's current screen-space rect onto the model so the
-- resolution emitter (Table:_finalizeHand, GrindController:update) can
-- spawn floating-text and chip bursts at the right table. Without this,
-- r.x/r.y default to (0, 0) and floaters land in the top-left corner
-- instead of over the table that produced them. Returns the board's count.
local function stamp(tbl, x, y, w, controller)
    tbl.x = x
    tbl.y = y
    -- The panel's width and the board's table count, for anything off the
    -- panel that decides by density: services/FloatingTextSystem drops a
    -- crowded board's floaters.
    tbl.panel_w = w
    local n_tables = (controller and controller.pool and controller.pool:count()) or 0
    tbl.board_n = n_tables
    -- The hand's theater plays at every count. From data/felt_layout
    -- anims.dense_tables the board is DENSE: the flights still fly and the
    -- cards still throw; only the pot's detonation on a stack win thins
    -- to a plain push (views/PokerEventAnims pot_push reads the stamp).
    tbl.board_dense = n_tables >= ((FeltData.anims and FeltData.anims.dense_tables) or math.huge)
    -- Past anims.pot_flights_until no chip flies to or from the pot; see
    -- views/PokerEventAnims (the bankroll leg of a payout still flies).
    tbl.board_pot_flights = n_tables <= ((FeltData.anims and FeltData.anims.pot_flights_until) or math.huge)
    return n_tables
end

-- Drain any newly-fired script events since the last frame. Each event
-- whose model index is past tbl.view_event_cursor gets dispatched through
-- views/PokerEventAnims (kind→fn table) — typically pops a floater near
-- the actor's seat anchor. The anchors used by the floaters were
-- registered in the prior frame's draw, so reading them here is 1-frame
-- stale on the very first event of a hand; imperceptible at 60fps.
-- Runs BEFORE the static render reads tbl._deal_fx, and once per frame:
-- a second call finds the cursor caught up.
local function dispatchEvents(tbl, game)
    if tbl.script and tbl.playback_state then
        local cursor = tbl.view_event_cursor or 0
        local idx    = tbl.script_idx or 0
        -- Every event plays at every count (a dense board only thins the
        -- stack-win detonation). The model resets _deal_fx and swept_hand
        -- itself each hand, so nothing waits.
        for i = cursor + 1, idx do
            local ev = tbl.script[i]
            if ev then
                local fn = PokerEventAnims[ev.kind]
                if fn then fn(ev, tbl, game) end
            end
        end
        tbl.view_event_cursor = idx
    end
end

-- Card-back override per frame: once the deck system has unlocked, the
-- active deck's sprite replaces the constant default for every face-down
-- card on this panel. Decks.activeSprite returns nil if the spec is
-- missing → drawCardBack falls back to CARD_BACK. The deck level-up flash
-- rides along (_back_pulse). Returns the back sprite.
local function frameSetup(tbl, game)
    local state = game.state
    local back_sprite = (Decks.systemUnlocked(state) and Decks.activeSprite(state))
                        or CARD_BACK
    _deal_back = back_sprite
    local lt = state._deck_levelup_t
    _back_pulse = 0
    if lt then
        local age = love.timer.getTime() - lt
        if age >= 0 and age < LEVELUP_FLASH_SECS then
            _back_pulse = 1 - age / LEVELUP_FLASH_SECS
        end
    end
    return back_sprite
end

-- Last-hand residue: the finished hand held on the idle felt. Only the
-- DEAD MATERIAL goes grey — the cards and the chips — the felt, the
-- plates, the button, the EV readout, the pill and the winning five keep
-- full color, so the room still says its stake while the spent hand reads
-- as inert. The ease-in off the wall-clock idle timer makes it visibly
-- "go cold" instead of snap. Returns (shader or nil, amount or nil).
local function desatOf(tbl)
    local residue  = residueOf(tbl)
    local desat_sh = residue and ShaderRegistry.get("desaturate") or nil
    if not desat_sh then return nil, nil end
    local RS = FeltStyle.residue or EMPTY
    return desat_sh, (RS.desat or 0.85)
                     * math.min(1, (tbl.state_timer or 0) / (RS.ease_secs or 0.35))
end

-- The rebuy price. Comes from the controller, which owns the discount
-- math (Night Table's rebuy_discount). Reading raw stake.buy_in here made
-- the button lie about the price and refuse affordable rebuys.
-- rebuyCostFor is deterministic — Medical Kit's free roll happens inside
-- rebuyTable, and only ever costs less.
local function rebuyCost(tbl, idx, controller)
    local stake = Lookups.findById(Stakes, tbl.stake_id)
    return (controller and controller.rebuyCostFor)
           and controller:rebuyCostFor(idx)
           or ((stake and stake.buy_in) or 0)
end

-- ── Felt layout ─────────────────────────────────────────────────────
-- ONE pass (views/FeltLayout) maps the felt rect → an explicit rect/anchor
-- for every element; the draw functions render into what they are handed.
-- Solved into one module scratch per call (both passes call it; the layout
-- itself is memoized on the table, so the second call is a field compare).
-- One layout record per table, stamped with the frame and the rect it
-- was solved for: prepare solves it and draw reuses it the same frame
-- (the text measurements in here ran twice per panel per frame).
local function solveLayout(tbl, x, y, w, h, game, controller, s, ui_s, n_tables)
    local fonts = game.fonts
    local ly = tbl._ly
    if not ly then ly = {}; tbl._ly = ly end
    if ly.f == _frame and ly.x == x and ly.y == y and ly.w == w and ly.h == h and ly.L then
        return ly
    end
    ly.f, ly.x, ly.y, ly.w, ly.h = _frame, x, y, w, h
    ly.s, ly.ui_s = s, ui_s
    -- Felt area.
    local felt_x = x + FELT_INSET
    local felt_y = y + HEADER_H + FELT_INSET
    local felt_w = w - 2 * FELT_INSET
    local felt_h = h - HEADER_H - 2 * FELT_INSET
    ly.felt_x, ly.felt_y, ly.felt_w, ly.felt_h = felt_x, felt_y, felt_w, felt_h
    -- Felt = the stake's chip (feltForStake above): the tier read at a
    -- glance, in casino color language. The stake theme still supplies
    -- border / header / chip tint; its old felt_tint is retired.
    ly.stake_theme = StakeThemes[tbl.stake_id]
    ly.felt_color  = feltForStake(tbl.stake_id)
    local sizes  = cardSizesFor(w)
    local gtype  = Lookups.findById(GameTypes, tbl.game_type_id)
    ly.gtype = gtype
    ly.is_tournament = (gtype and (gtype.chip_stack_table or gtype.hand_count)) and true or false
    local sm_h2  = fonts.sm:getHeight()
    local md_h   = fonts.md:getHeight()
    local xs_h   = (fonts.xs or fonts.sm):getHeight()   -- opp names + pot text reserve
    -- The caller measures text widths so FeltLayout stays pure geometry. The
    -- bottom row holds two edge-anchored strings on ONE line with no smaller
    -- font to fall back on, so the layout needs every form it might shed to.
    local ev_w, ev_money_w, ev_metrics, ev_pcts_w = Stats.measureEvReadout(tbl, controller, fonts)
    ev_w, ev_money_w = ev_w or 0, ev_money_w or 0
    ev_pcts_w = ev_pcts_w or ev_w
    ly.ev_metrics = ev_metrics
    local tied_w       = fonts.sm:getWidth(tiedText(tbl, "full"))
    local tied_short_w = fonts.sm:getWidth(tiedText(tbl, "short"))
    -- One character's advance in the seat-name font: what the layout converts
    -- a seat's width into "how many characters of name fit".
    local name_ch_w    = fonts.sm:getWidth("0")

    -- UNIVERSAL LAYOUT: every game type uses the SAME thin bottom row (one
    -- text-line tall) — cash draws chips/tied-up/EV in it, a tournament draws its
    -- HAND counter + payout ladder as a single row in it. No game type gets a
    -- taller band, so cards/opponents/community/hole are identical everywhere
    -- and stay full-size. (bottom_extra/card_bottom default to the thin row.)
    -- One parameter table for the process, rewritten per panel (the
    -- solver copies the fields it compares; a literal here was a table
    -- per panel per frame).
    local lp = _lp
    lp.felt_x, lp.felt_y, lp.felt_w, lp.felt_h = felt_x, felt_y, felt_w, felt_h
    lp.hu, lp.n_opps = (tbl.game_type_id == "hu"), #tbl.opponents
    lp.sizes, lp.s, lp.sm_h, lp.md_h, lp.xs_h = sizes, s, sm_h2, md_h, xs_h
    lp.ev_w, lp.ev_money_w, lp.ev_pcts_w = ev_w, ev_money_w, ev_pcts_w
    lp.tied_w, lp.tied_short_w = tied_w, tied_short_w
    lp.name_ch_w = name_ch_w
    lp.pile_r = Chips.radius()
    -- The board's count: the pile detail rule is gated on it.
    lp.n_tables = n_tables
    ly.L = FeltLayout.computeCached(tbl, lp)
    return ly
end

-- The payout-bar tooltip, resolved only under the pointer (GrindView's
-- hover walk calls tooltip_fn): the SAME breakdown the EV section / add-
-- table button show, so the ladder explains itself.
local function bandTooltip(tbl, controller)
    local stake = Lookups.findById(Stakes, tbl.stake_id)
    local gtype = Lookups.findById(GameTypes, tbl.game_type_id)
    return Stats.breakdownLinesFor(controller, stake, gtype)
end

-- The panel's body: chrome, header, felt, seats, cards, readouts, the
-- overlays. IMMEDIATE is today's single pass in today's order; STATIC is
-- the same with the live layers (border pulse, punch flash, a moving
-- stack pile, the pot, the status FX) skipped, for the sheet.
local function renderBody(tbl, idx, x, y, w, h, game, controller, hit_boxes, mode, ly, back_sprite)
    local fonts = game.fonts
    local sl    = game.sprite_loader
    local state = game.state
    local anims_on = true
    local live  = (mode == IMMEDIATE)
    _static = not live
    local s, ui_s = ly.s, ly.ui_s
    local L = ly.L
    local felt_x, felt_y, felt_w, felt_h = ly.felt_x, ly.felt_y, ly.felt_w, ly.felt_h
    local felt_color, gtype, is_tournament = ly.felt_color, ly.gtype, ly.is_tournament

    -- Panel chrome — fill stays Theme.bg.widget for chrome contrast.
    -- The border is the ONE default line on every table at every stake:
    -- a colored border is reserved for the banked-bounty trim below
    -- (gold = {chip} banked, purple = {achip} banked), and stake identity
    -- lives on the felt tint. No per-stake border chrome.
    Theme.setColor(Theme.bg.widget)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    -- Whether this (stake, game type) has banked its bounty this run — used for
    -- the chrome trim, drawn AFTER the header below so it wraps the whole
    -- panel (the header draws its own border over the top edge otherwise).
    local banked = controller and controller:bountyBanked(tbl.stake_id, tbl.game_type_id)
    local anti_banked = controller and controller.antiBountyBanked and controller:antiBountyBanked(tbl.stake_id, tbl.game_type_id)

    if live then
        -- A result's border pulse: the verdict in green or red, decaying in
        -- Table:update. Drawn here so it overlays the panel border but sits
        -- beneath all felt content. (A hand in progress and the deal itself
        -- light the felt instead: Effects.drawFeltLight, on the surface.)
        -- On the cached path both draw over the blit instead (drawLive), so
        -- a hand in progress keeps its cached picture.
        Effects.drawBorderPulse(tbl, x, y, w, h)
        -- Low motion stand-in: the status colour on the frame while a punch
        -- lands (no shove).
        local punch = Effects.punchFlash(tbl)
        if punch > 0 then
            Theme.setColor(Theme.sem.lost, 0.9)
            love.graphics.setLineWidth(4)
            love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
            love.graphics.setLineWidth(1)
        end
    end

    -- Header. Removing always allowed now that buy-ins are refundable —
    -- the previous "keep at least one table" gate was a leftover from
    -- before cost-to-open and trapped the player's bankroll.
    -- The "C" cursor mute toggle only renders once the cursor system is
    -- catalog-unlocked.
    local cursor_on        = (controller and controller.ctx and controller.ctx.cursor_unlocked) or false
    local rebuy_cursor_on  = (controller and controller.ctx and controller.ctx.cursor_rebuy_unlocked) or false
    drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, true, cursor_on, rebuy_cursor_on, s, ui_s)

    -- "{chip} banked" or "{achip} banked" trim around the WHOLE panel chrome. Drawn after the
    -- header so it overdraws the header's own border on the top edge/sides.
    if banked then
        Theme.setColor(Theme.currency.chip)
        love.graphics.setLineWidth(math.max(1, math.floor(2 * s)))
        love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
        love.graphics.setLineWidth(1)
    elseif anti_banked then
        Theme.setColor(Theme.sem.corrupt)
        love.graphics.setLineWidth(math.max(1, math.floor(2 * s)))
        love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
        love.graphics.setLineWidth(1)
    end

    -- ── Felt surface ────────────────────────────────────────────────────
    -- Drawn AFTER the layout solve, not before, because the layout is what
    -- decides whether this felt gets a rail — and if it does, the playing
    -- surface is the rect INSIDE the ring, which is also the rect every band
    -- above was solved against. Below the rail's gate L.rail is nil and the
    -- surface is the whole felt, exactly as before.
    --
    -- Decor makes no decisions of its own: views/FeltDecor draws what the
    -- layout published and skips what it published as nil.

    -- The residue's shader pair: ONE per panel, around the whole grey
    -- group (the opponent row, the community cards, the player seat:
    -- nothing coloured is drawn between them, only anchors). In the
    -- static render it is baked into the picture once per rebuild; the
    -- panel bypasses the cache while the amount eases in.
    local residue = residueOf(tbl)
    local desat_sh, desat_amount = desatOf(tbl)

    local surf = L.rail
    if surf then
        -- The rail is the game type's; the felt underneath is the stake's.
        FeltDecor.drawRail(surf, GameTypeThemes[tbl.game_type_id])
        local rw = surf.width
        FeltDecor.drawSurface(surf.x + rw, surf.y + rw,
                              surf.w - 2 * rw, surf.h - 2 * rw,
                              felt_color, math.max(0, (surf.radius or 0) - 1))
        -- The lamp over the table: the cloth lights while a hand runs and
        -- pops on the deal. On the surface, inside the rail, under all on
        -- the immediate path; over the blit on the cached one (drawLive).
        if live then
            Effects.drawFeltLight(tbl, surf.x + rw, surf.y + rw,
                                  surf.w - 2 * rw, surf.h - 2 * rw,
                                  math.max(0, (surf.radius or 0) - 1))
        end
    else
        FeltDecor.drawSurface(felt_x, felt_y, felt_w, felt_h,
                              felt_color, Theme.space.radius)
        if live then
            Effects.drawFeltLight(tbl, felt_x, felt_y, felt_w, felt_h, Theme.space.radius)
        end
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", felt_x, felt_y, felt_w, felt_h,
                                Theme.space.radius)
    end
    -- The community plate sits on the surface and under every card, so it
    -- draws here rather than with its band.
    FeltDecor.drawCommPlate(L.community and L.community.plate_rect, felt_color)

    -- Showdown winner state, computed once. At a reveal, win5 is the winner's
    -- best-5 (player_combo on a player win, opponent_combo on an opp win; both
    -- set by models/Table at deal time). The emphasis pass dims everything else
    -- and grows those five; the hand-name label is parked AT the winner (above
    -- your hole cards if you won, under the winning opp's seat if they did) so
    -- position says who, the label just says with-what.
    local hd          = handData(tbl)
    local show_winner = opponentFaceUp(tbl)
    local player_won  = (hd.outcome_delta or 0) > 0
    local win5        = show_winner
                        and (player_won and hd.player_combo or hd.opponent_combo)
                        or nil

    -- Opponents row (seats pre-split by the layout; chip-flight anchor per seat).
    -- Residue: opp cards are dead material, so the row draws desaturated
    -- (the winning five come back in color via the emphasis pass). The
    -- grey group runs from here through the player seat.
    desatBegin(desat_sh, desat_amount)
    -- Cards are held until the band is done so every shadow lands before
    -- any card and the backs batch (views/CardSprites.batchBegin). The
    -- dealer button is parked, not drawn, for the same reason.
    CardSprites.batchBegin()
    _dealer_btn.d = nil
    -- A cache slot leaves the row out while Zoom's seats fade in; the
    -- live layer draws it (rerollLive).
    if not (_static and rerollLive(tbl)) then
        drawOpponentRow(tbl, L, sl, fonts, back_sprite, felt_color)
    end

    -- Community cards. The pot pile is drawn LATER (after the showdown emphasis)
    -- so the chips -- which by design overlap the community cards -- sit on top
    -- of the dim/grow overlay instead of getting painted over by it.
    if L.community then drawCommunity(tbl, L.community, sl, L.community.plate) end
    CardSprites.batchEnd()
    if _dealer_btn.d then
        FeltDecor.drawButton(_dealer_btn.x, _dealer_btn.y, _dealer_btn.d, _dealer_btn.alpha)
    end

    -- Default chip-flight anchors — re-stamped each frame; drawPlayerSeat /
    -- drawPotLabel overwrite with more specific positions when they run.
    if not Anchors.get(Table.anchorKey(tbl, "you")) then
        Anchors.set(Table.anchorKey(tbl, "you"),
            felt_x + felt_w * 0.5, felt_y + felt_h - 12)
    end
    if not Anchors.get(Table.anchorKey(tbl, "pot")) then
        Anchors.set(Table.anchorKey(tbl, "pot"),
            felt_x + felt_w * 0.5, felt_y + felt_h * 0.45)
    end

    -- Player seat. Every band survives at every felt size now (the layout
    -- adapts what goes inside them instead of dropping them), so there is no
    -- cards-dropped fallback to branch to.
    local ctx = controller and controller.ctx
    -- Residue: hole cards and the stack pile are dead material too; the
    -- grey group ends here.
    drawPlayerSeat(tbl, L.hole, L.bottom, sl, fonts, ctx, idx, L.button, mode)
    desatEnd(desat_sh)

    -- DEAL / REBUY overlay (only when idle). Stack > 0 → DEAL. Stack at
    -- 0 means the player busted out and must rebuy the buy-in to keep
    -- playing; the green DEAL button is replaced by a red REBUY $X.XX
    -- button gated on bankroll.
    if tbl.state == "idle" then
        -- With residue on the felt, the button keeps its size but moves
        -- into the pot gap (the one guaranteed-empty band: the pot was
        -- pushed to the winner before the hand ended), plus a felt-wide
        -- rim. Drawn with the shader cleared so both stay full-color
        -- over the grey scene.
        local label_cy = nil
        if residue then
            if L.community and L.hole then
                label_cy = math.floor(((L.community.y + L.community.card_h) + L.hole.y) / 2)
            else
                label_cy = felt_y + felt_h / 2
            end
        end
        if (tbl.stack or 0) <= 0 then
            local cost      = rebuyCost(tbl, idx, controller)
            local can_rebuy = state.bankroll >= cost
            -- A busted tournament is re-entered, not rebought — the one
            -- word that keeps it from reading like a busted cash table.
            local verb  = (gtype and gtype.chip_stack_table) and "RE-ENTER"
                          or "REBUY"
            -- The price when it fits, the bare verb as the last resort —
            -- never scaled text. Memoized on the table: the list was two
            -- strings and a table per busted panel per frame.
            if tbl._rebuy_cost ~= cost or tbl._rebuy_verb ~= verb then
                tbl._rebuy_cost, tbl._rebuy_verb = cost, verb
                tbl._rebuy_label = { string.format("%s %s", verb, Format.price(cost)), verb }
            end
            local hb = drawFeltButton(tbl, felt_x, felt_y, felt_w, felt_h,
                fonts, hit_boxes, idx, tbl._rebuy_label, "rebuy",
                Theme.sem.lost, can_rebuy, tbl._id, label_cy)
            -- Tag the rebuy hit_box with the per-table rebuy-mute flag
            -- so CursorPool can skip this table when the player has
            -- opted out of auto-rebuy here.
            if hb then hb.cursor_rebuy_muted = tbl.cursor_rebuy_muted == true end
        else
            local hb = drawFeltButton(tbl, felt_x, felt_y, felt_w, felt_h,
                fonts, hit_boxes, idx, "DEAL", "deal",
                dealFillForStake(tbl.stake_id), true, tbl._id, label_cy)
            -- Tag the just-pushed DEAL hit_box so CursorPool can skip
            -- this table when the player has muted it. Mouse-click hit
            -- testing in GrindView ignores this field — muted tables
            -- stay hand-clickable.
            if hb then hb.cursor_muted = tbl.cursor_muted == true end
        end
    end

    -- EV readout — cash tables only (tournaments fill this row with their
    -- ladder). Drawn into the layout's bottom-center slot, and dropped when
    -- there's no room for it (L.bottom.ev.show).
    if L.bottom and L.bottom.ev.show and not is_tournament then
        Stats.drawEvReadout(tbl, L.bottom.ev, controller, fonts, hit_boxes,
            EV_KEY[idx], ly.ev_metrics, hbNew)
        -- (The Washing Machine's "2x" streak used to print here, at ev.x,
        -- which is where the EV label starts: it landed on top of the
        -- "+$0" and garbled it. The readout owns this corner; the streak
        -- shows in the deal pace, and the rail's $/min carries it.)
    end

    -- Showdown emphasis — dim the losing/unused cards, grow + pop the winning
    -- five. Runs here, after every card + EV pass, so it sits on top and reads.
    -- Undesaturated: the winning five stay in full color against the grey
    -- dead cards, which is the whole point of holding the result on the felt.
    drawShowdownEmphasis(tbl, L, sl, win5)

    -- Pot pile + "Pot: $X", drawn AFTER the emphasis so the chips stay on top of
    -- the dim/grow overlay (the pile is meant to overlap the community cards).
    -- (The pot is empty whenever there is residue, so it is drawn in
    -- colour: a shader pair around nothing was two binds a panel.)
    -- Live: the pile fills as bets land and the number rolls every frame,
    -- so the cached path draws it over the blit (drawLive).
    if live and L.pot then drawPotLabel(tbl, L.pot, fonts, anims_on) end

    -- Legacy KO: the binary-outcome pot is always empty, so the felt-center
    -- pot slot shows the HAND x/x tournament counter instead (the payout ladder
    -- spans the full bottom band below).
    if L.pot and tbl.state ~= "idle"
       and gtype and gtype.hand_count and not gtype.chip_stack_table then
        local hands_won = (tbl.ko and tbl.ko.hands_won) or 0
        local fh  = fonts.sm:getHeight()
        -- Center vertically in the OPEN gap between the community and hole cards
        -- (L.pot.text_y is offset low for the cash pile, which lands on the
        -- hole cards when there's no pile).
        local top = (L.community and (L.community.y + L.community.card_h)) or L.pot.text_y
        local bot = (L.hole and L.hole.y) or (top + fh)
        local hy  = top + math.floor((bot - top - fh) / 2)
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.sm)
        love.graphics.printf(string.format("HAND %d/%d", hands_won, gtype.hand_count or 8),
            L.pot.text_x, hy, L.pot.text_w, "center")
    end

    -- Payout-bar hover (tournaments): a tooltip-only hit_box over the
    -- bottom band. Lazy (tooltip_fn): the lines were built for every
    -- tournament panel every frame for a tooltip at most one can show.
    if hit_boxes and L.bottom and L.bottom.band
       and gtype and (gtype.chip_stack_table or gtype.hand_count) then
        local b  = L.bottom.band
        local hb = hbNew(tbl, hit_boxes)
        hb.x, hb.y, hb.w, hb.h = b.x, b.y, b.w, b.h
        hb.tooltip_fn, hb.tooltip_arg1, hb.tooltip_arg2 = bandTooltip, tbl, controller
    end

    -- (The showdown hand-name label is drawn in the top layer, over the
    -- chip flights: queued by TablePanel.draw, drawn by flushHandLabels.)

    if live then
        -- Stack vignette — colored wash over the felt area when a stack
        -- resolution is fading. Drawn AFTER the gauge so the colored tint
        -- sits over everything inside the panel.
        -- Status wash sits under the resolution vignette: a tilt is the
        -- table's standing condition, the vignette is what just happened.
        Effects.drawStatusWash(tbl, felt_x, felt_y, felt_w, felt_h)
        -- The heater burns along the felt's bottom edge, over the wash and
        -- the felt's own content, under the resolution vignette.
        Effects.drawStatusFire(tbl, felt_x, felt_y, felt_w, felt_h)
        Effects.drawVignette(tbl, felt_x, felt_y, felt_w, felt_h)

        -- Radial-glow halo (stack wins). Additive shader pass over the
        -- whole panel rect; lasts ~0.7s after a stack win.
        Effects.drawStatusRing(tbl, x, y, w, h)
        Effects.drawStatusGlow(tbl, x, y, w, h)
        Effects.drawGlow(tbl, x, y, w, h)
    end
end

-- The live layers over a blitted slot, in the order the body draws them:
-- the stack pile's bookkeeping every frame and its draw while it moves,
-- the pot (pile and rolling number), then the status FX, which are last
-- in the body's z-order too.
-- The cards of a street still landing or turning, over the cached picture
-- (their slots are empty in it: dealLive). Positions are the recorded
-- anchors the static render set and draw replayed; the gate says hidden,
-- flip, fade or down for each.
local function drawLiveCards(tbl, L, sl, row_live)
    local fx = tbl._deal_fx
    local lu = fx and fx.live_until
    if not lu or tbl.state == "idle" then return end
    local now = love.timer.getTime()
    local hd  = handData(tbl)
    CardSprites.batchBegin()
    local ob = L.opponents
    -- (A live seat row draws its own cards.)
    if ob and not row_live then
        for i = 1, #tbl.opponents do
            local u = lu[OPP_SLOT[i]]
            if u and now < u then
                local gate, gp = dealGate(tbl, OPP_SLOT[i])
                if gate ~= "hidden" then
                    local a1 = Anchors.get(Table.anchorKey(tbl, OPP_CARD_1[i]))
                    local a2 = Anchors.get(Table.anchorKey(tbl, OPP_CARD_2[i]))
                    if a1 and a2 then
                        local alpha = (gate == "fade") and gp or 1
                        drawCardBack(sl, _deal_back, a1[1], a1[2], a1[3], a1[4], alpha, ob.shadow, ob.back_plate)
                        drawCardBack(sl, _deal_back, a2[1], a2[2], a2[3], a2[4], alpha, ob.shadow, ob.back_plate)
                    end
                end
            end
        end
    end
    local comm = L.community
    if comm then
        local count = communityCardCount(tbl)
        for i = 1, 5 do
            local u = lu[BOARD_SLOT[i]]
            if u and now < u and i <= count and hd.community and hd.community[i] then
                local gate, gp = dealGate(tbl, BOARD_SLOT[i])
                local a = (gate ~= "hidden") and Anchors.get(Table.anchorKey(tbl, BOARD_SLOT[i]))
                if a then
                    if gate == "flip" then
                        drawCardTurn(sl, hd.community[i], a[1], a[2], a[3], a[4], gp, comm.shadow, comm.back_plate)
                    else
                        drawCardFront(sl, hd.community[i], a[1], a[2], a[3], a[4],
                                      (gate == "fade") and gp or 1, comm.plate, comm.shadow)
                    end
                end
            end
        end
    end
    local hole = L.hole
    local u = lu.you
    if hole and u and now < u and hd.player_hole then
        local gate, gp = dealGate(tbl, "you")
        local a1 = (gate ~= "hidden") and Anchors.get(Table.anchorKey(tbl, "cards_you_1"))
        local a2 = a1 and Anchors.get(Table.anchorKey(tbl, "cards_you_2"))
        if a1 and a2 then
            if gate == "flip" then
                drawCardTurn(sl, hd.player_hole[1], a1[1], a1[2], a1[3], a1[4], gp, hole.shadow, hole.back_plate)
                drawCardTurn(sl, hd.player_hole[2], a2[1], a2[2], a2[3], a2[4], gp, hole.shadow, hole.back_plate)
            elseif holeVisible(tbl) then
                local alpha = (gate == "fade") and gp or 1
                drawCardFront(sl, hd.player_hole[1], a1[1], a1[2], a1[3], a1[4], alpha, hole.plate, hole.shadow)
                drawCardFront(sl, hd.player_hole[2], a2[1], a2[2], a2[3], a2[4], alpha, hole.plate, hole.shadow)
            end
        end
    end
    CardSprites.batchEnd()
end

local function drawLive(tbl, x, y, w, h, game, ly)
    local L, fonts = ly.L, game.fonts
    local gtype = ly.gtype
    local sl    = game.sprite_loader
    -- The gates read as the immediate path does here: a slot is drawn
    -- when its card is down, whatever the last static render did.
    _static = false
    -- Zoom's seats fading in (left out of the picture), with the dealer
    -- button one of them parks; then the street's cards still landing.
    local row_live = rerollLive(tbl)
    if row_live then
        CardSprites.batchBegin()
        _dealer_btn.d = nil
        drawOpponentRow(tbl, L, sl, fonts, _deal_back, ly.felt_color)
        CardSprites.batchEnd()
        if _dealer_btn.d then
            FeltDecor.drawButton(_dealer_btn.x, _dealer_btn.y, _dealer_btn.d, _dealer_btn.alpha)
        end
    end
    drawLiveCards(tbl, L, sl, row_live)
    -- The tied-up line while its number rolls (blank in the picture).
    if L.bottom and L.bottom.tied and not (gtype and gtype.chip_stack_table) and tiedRolling(tbl) then
        local bt = L.bottom.tied
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.sm)
        love.graphics.print(tiedText(tbl, bt.parts), bt.x, bt.y)
    end
    -- The lamp over the table and a result's border pulse, over the cached
    -- picture. On the immediate path the light sits under the cards; here
    -- it washes them too, a few percent of warm at rest and a quarter
    -- second of pop on the deal. The alternative was no cache at all on a
    -- Zoom board, where a table is almost never between those two.
    local surf = L.rail
    if surf then
        local rw = surf.width
        Effects.drawFeltLight(tbl, surf.x + rw, surf.y + rw,
                              surf.w - 2 * rw, surf.h - 2 * rw,
                              math.max(0, (surf.radius or 0) - 1))
    else
        Effects.drawFeltLight(tbl, ly.felt_x, ly.felt_y, ly.felt_w, ly.felt_h, Theme.space.radius)
    end
    Effects.drawBorderPulse(tbl, x, y, w, h)
    if L.bottom and not (gtype and gtype.chip_stack_table) then
        local you_key = youPileSync(tbl, L.bottom, nil)
        if not ChipPile.quiet(you_key) then
            -- Dead material at idle goes grey with the rest of the hand.
            local sh, amount = desatOf(tbl)
            desatBegin(sh, amount)
            ChipPile.draw(you_key)
            desatEnd(sh)
        end
    end
    if L.pot then drawPotLabel(tbl, L.pot, fonts, true) end
    Effects.drawStatusWash(tbl, ly.felt_x, ly.felt_y, ly.felt_w, ly.felt_h)
    Effects.drawStatusFire(tbl, ly.felt_x, ly.felt_y, ly.felt_w, ly.felt_h)
    Effects.drawVignette(tbl, ly.felt_x, ly.felt_y, ly.felt_w, ly.felt_h)
    Effects.drawStatusRing(tbl, x, y, w, h)
    Effects.drawStatusGlow(tbl, x, y, w, h)
    Effects.drawGlow(tbl, x, y, w, h)
end

-- ── The dirty key ───────────────────────────────────────────────────
-- Everything the static picture is a function of, as a flat list compared
-- field by field (no strings built). PANEL_KEY, by index:
--    1 view_rev            2 picture signature   3 state
--    4 last_hand (id)      5 _status_rev         6 tied cents (_tied_c)
--    7 EV cents (_ev_c)    8 stack% (_pct_t)     9 loss% (_loss_t)
--   10 tournament KOs     11 depth bb           12 EV colour (id)
--   13 header text (id)   14 slot index         15 w
--   16 h                  17 ui_s               18 fonts.sm (id)
--   19 Theme.bg (id)      20 layout L (id)      21 back sprite
--   22 Motion.rev         23 steady felt light  24 cursor_on
--   25 rebuy_cursor_on    26 banked             27 anti_banked
--   28 busted             29 rebuy cost         30 can_rebuy
--   31 ko_payout_boost    32 pending_close      33 cursor_muted
--   34 cursor_rebuy_muted 35 hover X            36 hover D
--   37 hover R            38 hover DEAL/REBUY   39 flash X (/16)
--   40 flash D (/16)      41 flash R (/16)      42 flash DEAL (/16)
--   43 desat amount       44 stack pile rev     45 stack pile quiet
--   46 sheet generation   47 cards in their live window (count)
--   48 seat row fading in (Zoom reroll)
-- Field 6 is the roll itself while the number rolls (the digits are then
-- drawn live). A pile in motion, a pot, a pulse, a glow are LIVE layers or
-- bypass reasons, never keys: the key is only what a resting panel shows.
-- What a cash hand's script changes in the PICTURE: who is still in, how
-- many board cards are out, whether the opponent's hole is shown. A bet
-- moves the pot (a live layer) and the tied-up number (field 6) and
-- nothing else the static render paints, so the script index itself was
-- a rebuild per action: on a board of thirty-six fast Zooms, twenty-six
-- panel renders a frame, most of them for a call. A chip-stack table
-- keeps the index (its seats print their stacks).
local function pictureSig(tbl, gtype)
    if gtype and gtype.chip_stack_table then return tbl.script_idx end
    local ps = tbl.playback_state
    if not ps then return tbl.script_idx end
    local sig = (ps.community_count or 0) * 2 + (ps.opp_revealed and 1 or 0)
    local ins = ps.in_seats
    if ins then
        local bit = 16
        for i = 1, (ps.n_seats or 0) do
            if ins[i] then sig = sig + bit end
            bit = bit * 2
        end
    end
    return sig
end

local KN = 48
local K  = {}
-- HUD counters: the first key field that moved on each rebuild ("key:7"),
-- so a cache that rebuilds at rest names the field that is not resting.
local KEY_COUNTER = {}
for i = 1, KN do KEY_COUNTER[i] = "key:" .. i end
TablePanel.KEY_COUNTER = KEY_COUNTER
local function buildKey(tbl, idx, w, h, game, controller, ly)
    local ctx     = controller and controller.ctx
    local gtype   = ly.gtype
    local you_key = Table.anchorKey(tbl, "you")
    local busted  = (tbl.stack or 0) <= 0
    local cost, can_rebuy = nil, nil
    if busted and tbl.state == "idle" then
        cost      = rebuyCost(tbl, idx, controller)
        can_rebuy = game.state.bankroll >= cost
    end
    local ko_n, depth_n = nil, nil
    if gtype and gtype.chip_stack_table then
        local _, _, kos = tourneyCounts(tbl, gtype)
        ko_n, depth_n = kos, depthBB(tbl)
    end
    local cursor_on       = (ctx and ctx.cursor_unlocked) or false
    local rebuy_cursor_on = (ctx and ctx.cursor_rebuy_unlocked) or false
    local rid  = Table.rollingKey(tbl, "remove_table")
    local cid  = Table.rollingKey(tbl, "toggle_cursor")
    local rcid = Table.rollingKey(tbl, "toggle_rebuy_cursor")
    local fid  = ACTION_KEY[busted and "rebuy" or "deal"][tbl._id]
    local RS   = FeltStyle.residue or EMPTY
    K[1]  = tbl.view_rev
    K[2]  = pictureSig(tbl, gtype)
    K[3]  = tbl.state
    K[4]  = tbl.last_hand
    K[5]  = tbl._status_rev
    K[6]  = tiedRolling(tbl) and "roll" or tbl._tied_c
    K[7]  = tbl._ev_c
    K[8]  = tbl._pct_t
    K[9]  = tbl._loss_t
    K[10] = ko_n
    K[11] = depth_n
    K[12] = ly.ev_metrics and ly.ev_metrics.color
    K[13] = headerText(tbl)
    K[14] = idx
    K[15] = w
    K[16] = h
    K[17] = ly.ui_s
    K[18] = game.fonts.sm
    K[19] = Theme.bg
    K[20] = ly.L
    K[21] = _deal_back
    K[22] = Motion.rev
    K[23] = 0   -- the felt light is a live layer now; was the steady-light flag
    K[24] = cursor_on
    K[25] = rebuy_cursor_on
    K[26] = (controller and controller:bountyBanked(tbl.stake_id, tbl.game_type_id)) and true or false
    K[27] = (controller and controller.antiBountyBanked
             and controller:antiBountyBanked(tbl.stake_id, tbl.game_type_id)) and true or false
    K[28] = busted
    K[29] = cost
    K[30] = can_rebuy
    K[31] = ctx and ctx.ko_payout_boost
    K[32] = tbl.pending_close == true
    K[33] = tbl.cursor_muted == true
    K[34] = tbl.cursor_rebuy_muted == true
    K[35] = Hover.is("hit", rid)
    K[36] = cursor_on and Hover.is("hit", cid) or false
    K[37] = rebuy_cursor_on and Hover.is("hit", rcid) or false
    K[38] = Hover.dwell("hit", fid)
    K[39] = math.floor(ClickFlash.alpha("hit", rid) * 16)
    K[40] = math.floor(ClickFlash.alpha("hit", cid) * 16)
    K[41] = math.floor(ClickFlash.alpha("hit", rcid) * 16)
    K[42] = math.floor(ClickFlash.alpha("hit", fid) * 16)
    K[43] = residueOf(tbl) and (RS.desat or 0.85) or 0
    K[44] = ChipPile.rev(you_key)
    K[45] = ChipPile.quiet(you_key)
    K[46] = PanelSheet.generation()
    K[47] = dealLiveCount(tbl)
    K[48] = rerollLive(tbl)
end

-- ── The bypass classifier ───────────────────────────────────────────
-- Is anything painted INTO the panel's picture moving this frame? Then
-- the panel draws in full and the slot is left alone. Transforms (shake,
-- bump, lean, the deal's spring) are not reasons: they apply to the blit.
-- Each reason is a treatment the body paints from a clock or a tween:
--   held          the picked-up panel draws at a scaled size anyway
--   size          the sheet's slots are one size; a settle draws scaled
-- (The deal's cards are a live layer, not a reason: dealLive.)
-- (Zoom's seats fading in after a reroll are a live layer too: rerollLive.)
--   showdown pop  the winning five popping for a quarter second
--   seat KO       a busted seat's flash and stamping tag
--   border pulse  the result's frame, and the deal's light pop
--   felt light    the lamp easing up (lift_t between 0 and 0.99)
--   residue ease  the finished hand greying in
--   back pulse    the deck level-up flash on every back
--   punch flash   low motion's frame flash
--   ladder        the KO bar's fill still easing
-- Returns the reason the panel cannot be cached this frame, or nil. The
-- reasons are fixed strings that double as Perf counter names, so the HUD
-- can say WHICH window is keeping a board out of the cache (a Zoom table
-- is in one or another for most of a hand; which one decides the fix).
TablePanel.BYPASS_REASONS = {
    "bypass:held", "bypass:size", "bypass:poke",
    "bypass:showdown", "bypass:ko", "bypass:residue", "bypass:deck",
    "bypass:punch", "bypass:ladder",
}
local function panelIsAnimating(tbl, w, h, ly)
    if tbl._held then return "bypass:held" end
    local _, sw, sh = PanelSheet.debugSize()
    if w ~= sw or h ~= sh then return "bypass:size" end
    -- A clicked card jumping, or the stack pile hopping (it bakes into the
    -- picture when it is quiet): live for that quarter second.
    if Poke.anyActive(cardPrefix(tbl)) or Poke.active(PILE_POKE[Table.anchorKey(tbl, "you")])
       or Poke.active(HIT_POKE[ACTION_KEY.rebuy[tbl._id]]) then
        return "bypass:poke"
    end
    local st = tbl.state
    if st ~= "settling" and st ~= "idle" and opponentFaceUp(tbl)
       and (tbl.state_timer or 0) < 0.25 then return "bypass:showdown" end
    if Effects.hasSeatKO(tbl) then return "bypass:ko" end
    -- (The border pulse and the felt light are live layers over the blit,
    -- so neither stops the cache.)
    if residueOf(tbl) then
        local RS = FeltStyle.residue or EMPTY
        if (tbl.state_timer or 0) < (RS.ease_secs or 0.35) then return "bypass:residue" end
    end
    if _back_pulse > 0 then return "bypass:deck" end
    if Effects.punchFlash(tbl) > 0 then return "bypass:punch" end
    local gtype, L = ly.gtype, ly.L
    if gtype and gtype.chip_stack_table and L.bottom and L.bottom.band
       and ladderRolling(tbl, gtype, L.bottom.band) then return "bypass:ladder" end
    return nil
end

-- ─── Public API ──────────────────────────────────────────────────────

-- Open the frame's sheet for `n` panels of `w` x `h`. Called once per
-- grid draw before any prepare; returns whether the cache is on for this
-- frame (the switch up and a sheet that fits).
function TablePanel.sheetBegin(n, w, h)
    _frame = _frame + 1
    if Constants.FEATURES.PANEL_CACHE then
        _sheet_ok = PanelSheet.ensure(n, w, h)
    else
        PanelSheet.release()
        _sheet_ok = false
    end
    -- The HUD's sheet and atlas rows, re-gauged each frame so they read
    -- even when the HUD was opened after the build (a gauge set at build
    -- time with the meters off was lost).
    Perf.gauge("sheet_mb", (PanelSheet.bytes() or 0) / 1048576)
    local _, _, _, atlas_bytes = Chips.atlasInfo()
    Perf.gauge("atlas_mb", (atlas_bytes or 0) / 1048576)
    return _sheet_ok
end

-- Close the frame's write session (a no-op when nothing was rebuilt).
function TablePanel.sheetEnd()
    PanelSheet.endWrite()
end

-- Pass A. Stamps the model, plays the script events, classifies, and
-- rebuilds the panel's slot when its key moved. Nothing is drawn to the
-- frame here; draw does that.
function TablePanel.prepare(tbl, idx, x, y, w, h, game, controller)
    if not (tbl and _sheet_ok) then return end
    local s, ui_s = setScale(w, h, game)
    local n_tables = stamp(tbl, x, y, w, controller)
    dispatchEvents(tbl, game)
    local back_sprite = frameSetup(tbl, game)
    tbl._pf, tbl._pw, tbl._ph = _frame, w, h
    local ly = solveLayout(tbl, x, y, w, h, game, controller, s, ui_s, n_tables)
    local why = panelIsAnimating(tbl, w, h, ly)
    if why then
        tbl._pmode = MODE_BYPASS
        Perf.count("panel_bypass")
        Perf.count(why)
        return
    end
    tbl._pmode = MODE_CACHED
    Perf.count("panel_cached")
    -- The stack pile's bookkeeping runs before the key reads its revision:
    -- a pile placed and synced for the first time inside the render would
    -- otherwise move the key and cost a second rebuild next frame.
    local L = ly.L
    if L.bottom and not (ly.gtype and ly.gtype.chip_stack_table) then
        youPileSync(tbl, L.bottom, nil)
    end
    buildKey(tbl, idx, w, h, game, controller, ly)
    local pk = tbl._pk
    local dirty = (pk == nil)
    if pk then
        for i = 1, KN do
            if pk[i] ~= K[i] then dirty = true; Perf.count(KEY_COUNTER[i]); break end
        end
    end
    if not dirty then return end
    if not pk then pk = {}; tbl._pk = pk end
    for i = 1, KN do pk[i] = K[i] end

    -- The static render, into the slot: the panel's own coordinates,
    -- translated so its origin lands on the slot's. Anchors and hit boxes
    -- are recorded at these coordinates and replayed by draw shifted to
    -- wherever the panel is that frame.
    PanelSheet.beginWrite()
    PanelSheet.clearSlot(idx, tbl)
    local ox, oy = PanelSheet.slotOffset(idx, x, y)
    love.graphics.push()
    love.graphics.translate(ox, oy)
    local rec = tbl._anch_rec
    if not rec then rec = {}; tbl._anch_rec = rec end
    Anchors.beginRecord(rec)
    local hbs = tbl._hb_static
    if not hbs then hbs = {}; tbl._hb_static = hbs end
    tbl._hbs_n = 0
    renderBody(tbl, idx, x, y, w, h, game, controller, hbs, STATIC, ly, back_sprite)
    Anchors.endRecord()
    love.graphics.pop()
    -- Each box keeps its rendered position; draw rewrites x/y (and the
    -- visual rect) from these every frame, then the fixup adds the
    -- transforms.
    local n = tbl._hbs_n
    for i = 1, n do
        local hb = hbs[i]
        hb.rx, hb.ry, hb.rvx, hb.rvy = hb.x, hb.y, hb.visual_x, hb.visual_y
    end
    for i = #hbs, n + 1, -1 do hbs[i] = nil end
    tbl._px, tbl._py, tbl._pslot = x, y, idx
    Perf.count("panel_rebuild")
end

-- The resting drop shadow, or a slam's deeper one. Drawn BEFORE the
-- transform push so it stays at the panel's resting position. The panel
-- no longer lifts during a hand (Effects.liftSlamOffset), so the resting
-- shadow is drawn at rest whatever lift_t says; only a slam, which does
-- rear the panel up toward the camera, deepens it. Proxy tables because
-- Table:update owns the real lift_t. GrindView draws every panel's shadow
-- before any panel when the cache is on (one batch; no panel over a
-- neighbour's shadow); draw does it itself otherwise.
local _lift_shadow = { lift_t = 0 }
function TablePanel.drawShadow(tbl, x, y, w, h)
    local _, _, _, _, bump_lift = Effects.bumpOffset(tbl)
    if bump_lift > 0.01 then
        _lift_shadow.lift_t = bump_lift
        Effects.drawHoverShadow(_lift_shadow, x, y, w, h)
    else
        Effects.drawHoverShadow(REST_SHADOW, x, y, w, h)
    end
end

-- Pass B. Draw one panel and append any clickable hit-zones to hit_boxes.
-- `shadow_done`: the caller drew the shadow already (the grid, cache on).
-- Showdown hand-name labels, queued per table by TablePanel.draw and drawn
-- by TablePanel.flushHandLabels in the top layer (GrindView: over the chip
-- flights, item triggers and cursors, under the hover cards and tooltips),
-- so the name of the hand that just won is never under the chips it pays.
local _labels, _labels_n = {}, 0
local function drawHandLabel(tbl, L, felt_x, felt_y, felt_w, fonts)
    local hd = handData(tbl)
    local player_won = (hd.outcome_delta or 0) > 0
-- Showdown hand-name label — the prefix-free name ("two pair, Ks and 3s")
-- of the WINNING hand, parked AT the winner so position names who: just
-- above your hole cards when you win, centered under the winning opp's seat
-- when they win (the seat's cards are glowing green to match). Dark pill,
-- on top, sized to the text and clamped inside the felt so it never crops.
    local hand = player_won and hd.player_hand_name or hd.opponent_hand_name
    if hand and hand ~= "" then
        local f = fonts.sm
        love.graphics.setFont(f)
        local tw = math.min(felt_w - 8, f:getWidth(hand) + 16)
        local th = f:getHeight() + 4

        -- Center-x + baseline depend on who won.
        local cx, by
        if player_won and L.hole then
            cx = felt_x + felt_w * 0.5
            by = L.hole.y + math.floor((L.hole.card_h - th) / 2)  -- centered OVER your cards
        elseif (not player_won) and L.opponents
               and hd.opponent_idx and L.opponents.seats[hd.opponent_idx] then
            local seat = L.opponents.seats[hd.opponent_idx]
            cx = seat.x + seat.w * 0.5
            by = L.opponents.y + L.opponents.cards_y_offset
                 + L.opponents.card_h + 2              -- just under their cards
        else
            cx = felt_x + felt_w * 0.5                 -- fallback: top-center
            by = felt_y + 2
        end

        -- Clamp the pill fully inside the felt (so a wide name under a
        -- narrow edge seat slides in rather than cropping).
        local bx = math.floor(cx - tw / 2)
        bx = math.max(felt_x + 4, math.min(bx, felt_x + felt_w - 4 - tw))

        Theme.setColor(Theme.bg.window, 0.9)
        love.graphics.rectangle("fill", bx, by, tw, th, Theme.space.radius)
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", bx, by, tw, th, Theme.space.radius)
        -- Gold text to match the gold cards it labels (one win language).
        Theme.setColor(Theme.currency.chip)
        love.graphics.printf(hand, bx, by + 2, tw, "center")
    end
end

function TablePanel.flushHandLabels(game)
    local fonts = game.fonts
    for i = 1, _labels_n do
        local e = _labels[i]
        if fonts then drawHandLabel(e.tbl, e.L, e.fx, e.fy, e.fw, fonts) end
        e.tbl, e.L = nil, nil
    end
    _labels_n = 0
end

-- A hovered upgrade's change on one table, queued by draw and drawn by
-- TablePanel.flushPreviewCards after the chip flights, floaters and cursors
-- so nothing flies over it.
local _cards, _cards_n = {}, 0
local function drawPreviewCard(tbl, pv, idx, x, y, w, h, game)
-- A hovered upgrade's change on this table (set per frame by
-- GrindView:_updatePreview): a card above the readout with the numbers,
-- "now" and "next" bars (the segments the upgrade moves bright, the
-- rest faint), outlined in the upgrade's colour and pulsing.
    local ek = EV_KEY[idx]
    local a = Anchors.get(ek)
    local f = game.fonts and (game.fonts.xs or game.fonts.sm)
    if f then
        local th   = f:getHeight()
        local pad  = 4
        local text = pv.text
        local lab_w = f:getWidth("next") + 4
        local bar_w = math.floor(th * 6)
        local max_w = w - 2 * pad - 8
        local tw = IconText.measure(text, f)
        if tw > max_w and pv.short then text = pv.short; tw = IconText.measure(text, f) end
        local cw = math.min(max_w, math.max(tw, lab_w + bar_w))
        bar_w = math.max(8, math.min(bar_w, cw - lab_w))
        local ch = th * 3 + 2
        local bx = (a and Anchors.age(ek) <= 1) and (a[1] + a[3] - cw - pad) or (x + (w - cw) * 0.5 - pad)
        bx = math.max(x + 4, math.min(bx, x + w - cw - 2 * pad - 4))
        local by = ((a and Anchors.age(ek) <= 1) and a[2] or (y + h - th * 2)) - ch - 2 * pad - 4
        by = math.max(y + 2, by)
        Theme.setColor(Theme.bg.chrome, 0.95)
        love.graphics.rectangle("fill", bx, by, cw + 2 * pad, ch + 2 * pad, 4, 4)
        local pulse = 0.6 + 0.4 * math.sin(love.timer.getTime() * 7)
        Theme.setColor(pv.color or Theme.sem.won, pulse)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", bx, by, cw + 2 * pad, ch + 2 * pad, 4, 4)
        love.graphics.setLineWidth(1)
        love.graphics.setFont(f)
        local cx, cy = bx + pad, by + pad
        IconText.draw(game, text, cx, cy, f, pv.color or Theme.sem.won, 1)
        love.graphics.setFont(f)
        local bh = math.max(3, math.floor(th * 0.55))
        local o = _pv_opts
        o.focus, o.highlight, o.ghost, o.alpha = pv.focus, nil, nil, nil
        Theme.setColor(Theme.fg.muted)
        love.graphics.print("now", cx, cy + th + 1)
        OutcomeBar.draw(cx + lab_w, cy + th + 1 + math.floor((th - bh) * 0.5), bar_w, bh, pv.now, o)
        Theme.setColor(Theme.fg.heading)
        love.graphics.print("next", cx, cy + 2 * th + 2)
        OutcomeBar.draw(cx + lab_w, cy + 2 * th + 2 + math.floor((th - bh) * 0.5), bar_w, bh, pv.next, o)
    end
end

function TablePanel.flushPreviewCards(game)
    for i = 1, _cards_n do
        local c = _cards[i]
        drawPreviewCard(c.tbl, c.pv, c.idx, c.x, c.y, c.w, c.h, game)
        c.tbl, c.pv = nil, nil
    end
    _cards_n = 0
end

function TablePanel.draw(tbl, idx, x, y, w, h, game, controller, hit_boxes, shadow_done)
    if not tbl then
        TablePanel.drawEmpty(x, y, w, h, game.fonts)
        return
    end

    local s, ui_s = setScale(w, h, game)
    local n_tables = stamp(tbl, x, y, w, controller)

    -- Per-table FX transform stack. Ordered: lift+slam (vertical hover/
    -- punch) → shake (random shudder on top). All sub-elements (chrome,
    -- felt, cards, chips) inherit the transform so the panel moves as a
    -- single object. State decays in Table:update; we just read.
    local shake_x, shake_y = Effects.shakeOffset(tbl)
    -- The shove: this table lunging at a neighbour it just affected, or
    -- reeling from one. Unlike shake, this one DOES move the click
    -- targets — it is a deliberate motion the player is watching, not
    -- jitter, and a button that stayed behind would feel broken.
    local bump_x, bump_y, bump_sx, bump_sy, bump_lift = Effects.bumpOffset(tbl)
    -- The deal's press: a short dip and squash that springs back and is
    -- gone. Its dy rides where the lift used to (the hit boxes follow it,
    -- below); its squash multiplies into the shove's scale about the
    -- panel's bottom edge.
    local lift_y, deal_sx, deal_sy = Effects.dealSpring(tbl)
    bump_sx, bump_sy = bump_sx * deal_sx, bump_sy * deal_sy
    -- A tilted table stays leaning until it settles.
    local lean             = Effects.statusRotation(tbl)
    local transformed = (shake_x ~= 0 or shake_y ~= 0 or lift_y ~= 0
                         or bump_x ~= 0 or bump_y ~= 0)

    -- Hit-box offset: hit_boxes are pushed during sub-element rendering
    -- with un-transformed coords. After the panel finishes drawing, we
    -- walk the entries added during THIS panel and offset their y by
    -- lift_y so the click target tracks the visually-lifted button.
    -- Shake is intentionally excluded — folding random per-frame jitter
    -- into the hit-test would make click targets dance around.
    local hit_boxes_start = hit_boxes and #hit_boxes or 0

    if not shadow_done then
        if bump_lift > 0.01 then
            _lift_shadow.lift_t = bump_lift
            Effects.drawHoverShadow(_lift_shadow, x, y, w, h)
        else
            Effects.drawHoverShadow(REST_SHADOW, x, y, w, h)
        end
    end

    -- A shove swells the panel slightly when it hits everyone at once;
    -- grow about the centre so it pushes out evenly.
    -- Squash and stretch pivot on the panel's BOTTOM edge, so a slammed
    -- table compresses onto the felt like something heavy landed on it
    -- rather than shrinking toward its own middle.
    local scaled = (bump_sx ~= 1 or bump_sy ~= 1)
    if transformed or scaled then
        love.graphics.push()
        love.graphics.translate(shake_x + bump_x, shake_y + lift_y + bump_y)
        if scaled then
            local px, py = x + w / 2, y + h
            love.graphics.translate(px, py)
            love.graphics.scale(bump_sx, bump_sy)
            love.graphics.translate(-px, -py)
        end
    end
    -- The lean is its own transform so the rotation pivots on the panel's
    -- centre rather than on wherever the shove has pushed it.
    if lean ~= 0 then Effects.pushRotated(x + w / 2, y + h / 2, lean) end

    -- Screen-space center for floating-text spawn (read by GrindController
    -- via AnchorRegistry; written here once per draw). Carries the panel's
    -- SIZE as well, so effects that should be scaled to this table rather
    -- than to the screen — the pot detonation, which otherwise throws the
    -- same 600px cloud over a panel a quarter that wide — have something
    -- to measure against. Point readers only touch [1]/[2].
    Anchors.set(Table.anchorKey(tbl, "center"), x + w / 2, y + h / 2, w, h)
    -- The same panel as a proper RECT anchor (top-left + dims) for
    -- hint/story marks — the center anchors above are centre-point
    -- convention and a highlight ring would draw half-offset.
    Anchors.set(TABLE_KEY[idx], x, y, w, h)
    -- Shared names for "the table that ...", for story marks: the panel
    -- whose (stake, game type) has banked its bounty this run, and the
    -- panel with heat on it right now. Last drawn wins when several do.
    do
        if controller and controller.bountyBanked
           and controller:bountyBanked(tbl.stake_id, tbl.game_type_id) then
            Anchors.set("table:banked", x, y, w, h)
        end
        for _, st in ipairs(tbl.statuses or EMPTY) do
            if st.kind == "heater" then Anchors.set("table:heater", x, y, w, h) break end
        end
        for _, st in ipairs(tbl.statuses or EMPTY) do
            if st.kind == "tilt" then Anchors.set("table:tilt", x, y, w, h) break end
        end
    end

    -- Seed a default pot anchor BEFORE the script-event loop below runs. The
    -- first bet of a hand flies its chips to the "pot" anchor during that loop,
    -- but the precise pile position isn't computed until drawPotLabel later in
    -- this frame — so on a table's very first bet the anchor would be unset and
    -- the chips would fly to (0,0). Default it to the panel center (on the
    -- felt); drawPotLabel overwrites it with the exact pile spot each frame.
    if not Anchors.get(Table.anchorKey(tbl, "pot")) then
        Anchors.set(Table.anchorKey(tbl, "pot"), x + w / 2, y + h / 2)
    end

    -- Cached: prepared THIS frame, at rest, at the sheet's size, with a
    -- picture in its slot. Anything else (a bypass, the held panel, the
    -- settle's scaled draw, the cache off) draws the whole panel.
    local cached = _sheet_ok and tbl._pf == _frame and tbl._pmode == MODE_CACHED
                   and tbl._pw == w and tbl._ph == h and tbl._pk ~= nil
                   and PanelSheet.available()
    if not cached then
        dispatchEvents(tbl, game)
        local back_sprite = frameSetup(tbl, game)
        local ly = solveLayout(tbl, x, y, w, h, game, controller, s, ui_s, n_tables)
        tbl._hb_n = 0
        renderBody(tbl, idx, x, y, w, h, game, controller, hit_boxes, IMMEDIATE, ly, back_sprite)
    else
        local ly = solveLayout(tbl, x, y, w, h, game, controller, s, ui_s, n_tables)
        local dx, dy = x - tbl._px, y - tbl._py
        PanelSheet.blit(tbl._pslot, x, y)
        -- The recorded anchors first, so the live layers' own (the pile's
        -- "you" spot, the pot) win where they overlap.
        Anchors.replay(tbl._anch_rec, dx, dy)
        drawLive(tbl, x, y, w, h, game, ly)
        -- The recorded hit boxes, at this frame's position and index (the
        -- cursor swarm and GrindView read x/y/visual_x/visual_y/idx between
        -- draws; a reorder or a slide since the render must not leave a
        -- target behind). The same entry objects every frame.
        if hit_boxes then
            local hbs = tbl._hb_static
            for i = 1, tbl._hbs_n do
                local hb = hbs[i]
                hb.x, hb.y = hb.rx + dx, hb.ry + dy
                if hb.rvx then hb.visual_x, hb.visual_y = hb.rvx + dx, hb.rvy + dy end
                hb.idx = idx
                hit_boxes[#hit_boxes + 1] = hb
            end
        end
    end

    -- The odds bar, a live layer (the cached picture holds only its rect):
    -- it eases from the old odds to the new ones instead of jumping.
    do
        local bk = BAR_KEY[idx]
        local a = Anchors.get(bk)
        local m = tbl._ev_metrics
        if a and m and m.stats and Anchors.age(bk) <= 1 then
            local d = tbl._bar_disp
            if not d then
                d = { win_dist = {}, loss_dist = {} }
                tbl._bar_disp = d
                OutcomeBar.ease(d, m.stats, 1)
            else
                local dt = (love.timer.getDelta and love.timer.getDelta()) or (1 / 60)
                OutcomeBar.ease(d, m.stats, 1 - math.exp(-dt * BAR_EASE))
            end
            local o = nil
            if tbl._preview then
                o = _bar_live_opts
                o.focus, o.highlight = tbl._preview.focus, tbl._preview.color
            end
            OutcomeBar.draw(a[1], a[2], a[3], a[4], d, o)
        end
    end

    -- A hovered upgrade's change on this table: queued, drawn on top of
    -- everything by TablePanel.flushPreviewCards (GrindView, last).
    local pv = tbl._preview
    if pv and pv.text and pv.now and pv.next then
        _cards_n = _cards_n + 1
        local c = _cards[_cards_n]
        if not c then c = {}; _cards[_cards_n] = c end
        c.tbl, c.pv, c.idx, c.x, c.y, c.w, c.h = tbl, pv, idx, x, y, w, h
    end

    -- Click surfaces (services/ClickSurfaces), under the panel's transform
    -- so a shaken or shoved panel registers where it is drawn: the chrome,
    -- the felt in its stake's colour, the chip piles, the cards on show.
    do
        local lys = solveLayout(tbl, x, y, w, h, game, controller, s, ui_s, n_tables)
        -- The showdown hand name, for the top layer (flushHandLabels).
        if opponentFaceUp(tbl) and lys.L then
            _labels_n = _labels_n + 1
            local e = _labels[_labels_n]
            if not e then e = {}; _labels[_labels_n] = e end
            e.tbl, e.L, e.fx, e.fy, e.fw = tbl, lys.L, lys.felt_x, lys.felt_y, lys.felt_w
        end
        ClickSurfaces.addLocal("chrome", x, y, w, h)
        _felt_opts.tint = lys.felt_color
        ClickSurfaces.addLocal("felt", lys.felt_x, lys.felt_y, lys.felt_w, lys.felt_h, _felt_opts)
        -- Busted and broke: the REBUY has no hit box, so the felt refuses.
        if tbl.state == "idle" and (tbl.stack or 0) <= 0
           and game.state.bankroll < rebuyCost(tbl, idx, controller) then
            _deny_opts.poke = HIT_POKE[ACTION_KEY.rebuy[tbl._id]]
            ClickSurfaces.addLocal("denied", lys.felt_x, lys.felt_y, lys.felt_w, lys.felt_h, _deny_opts)
        end
        for _, slot in ipairs(PILE_SLOTS) do
            local pk = Table.anchorKey(tbl, slot)
            local bx, by, bw, bh = ChipPile.bounds(pk)
            if bx then
                _pile_opts.pile = pk     -- the column under the click hops
                ClickSurfaces.addLocal("chips", bx, by, bw, bh, _pile_opts)
            end
        end
        if holeVisible(tbl) then
            cardSurface(tbl, "cards_you_1"); cardSurface(tbl, "cards_you_2")
            for i = 1, #tbl.opponents do cardSurface(tbl, OPP_CARD_1[i]); cardSurface(tbl, OPP_CARD_2[i]) end
        end
        for i = 1, communityCardCount(tbl) do cardSurface(tbl, BOARD_SLOT[i]) end
    end

    -- The stack box takes in the parked result readout above the pile
    -- (registered by the floater renderer last frame) while it is there,
    -- so "the readout, tied up and the chips" is one mark.
    do
        local sa = Anchors.get(STACK_KEY[idx])
        local rk = Table.rollingKey(tbl, "result")
        local ra = Anchors.get(rk)
        if sa and ra and Anchors.age(rk) <= 2 then
            local x1 = math.min(sa[1], ra[1]);            local y1 = math.min(sa[2], ra[2])
            local x2 = math.max(sa[1] + sa[3], ra[1] + ra[3]); local y2 = math.max(sa[2] + sa[4], ra[2] + ra[4])
            Anchors.set(STACK_KEY[idx], x1, y1, x2 - x1, y2 - y1)
            sa = { x1, y1, x2 - x1, y2 - y1 }
        end
        -- The same box under a shared name on the table whose (stake, game
        -- type) has banked its bounty this run: "the stack that paid", for
        -- the beats about it. Last drawn wins when several have.
        if sa and controller and controller.bountyBanked
           and controller:bountyBanked(tbl.stake_id, tbl.game_type_id) then
            Anchors.set("stack:banked", sa[1], sa[2], sa[3], sa[4])
        end
    end

    -- Close the shake/lift transform before the hover-hit-test stash, so
    -- the mouse-vs-panel rect calculation in the debug tooltip uses the
    -- panel's actual (un-transformed) screen rect.
    if lean ~= 0 then Effects.popRotated() end
    if transformed or scaled then
        love.graphics.pop()
    end

    -- Sync hit_boxes pushed during this panel's render with the panel's
    -- visible position, so clicking a button hits where it is DRAWN.
    -- Three of the four transforms are included:
    --   lift  — the hover rise; without this a raised DEAL button eats a
    --           click into empty space below it.
    --   bump  — a deliberate shove the player is watching.
    --   lean  — a tilted table's whole panel is rotated, so its targets
    --           rotate with it about the same centre.
    -- Shake stays excluded on purpose: it is per-frame random jitter, and
    -- folding it in would make every click target dance.
    if hit_boxes and #hit_boxes > hit_boxes_start
       and (lift_y ~= 0 or bump_x ~= 0 or bump_y ~= 0 or lean ~= 0) then
        local cx, cy = x + w / 2, y + h / 2
        for i = hit_boxes_start + 1, #hit_boxes do
            local hb = hit_boxes[i]
            hb.x = hb.x + bump_x
            hb.y = hb.y + lift_y + bump_y
            if hb.visual_x then hb.visual_x = hb.visual_x + bump_x end
            if hb.visual_y then hb.visual_y = hb.visual_y + lift_y + bump_y end
            if lean ~= 0 then
                -- Boxes stay axis-aligned; their centres follow the
                -- rotation. At a few degrees the corner error is under a
                -- pixel or two, and the alternative (rotated hit-testing)
                -- would mean a bespoke test path for one status.
                local bcx, bcy = hb.x + (hb.w or 0) / 2, hb.y + (hb.h or 0) / 2
                local rx, ry = Effects.rotatePoint(bcx, bcy, cx, cy, lean)
                hb.x, hb.y = hb.x + (rx - bcx), hb.y + (ry - bcy)
                if hb.visual_x and hb.visual_y then
                    local vcx = hb.visual_x + (hb.visual_w or 0) / 2
                    local vcy = hb.visual_y + (hb.visual_h or 0) / 2
                    local vrx, vry = Effects.rotatePoint(vcx, vcy, cx, cy, lean)
                    hb.visual_x = hb.visual_x + (vrx - vcx)
                    hb.visual_y = hb.visual_y + (vry - vcy)
                end
            end
        end
    end

    -- Backtick-toggled debug tooltip — only stashes the hovered panel's
    -- (tbl, ctx). Actual render happens in TablePanelStats.flushDebugOverlay
    -- AFTER the caller has drawn every panel, so the tooltip is never
    -- overdrawn by adjacent panels.
    Stats.stashDebugTooltipIfHover(tbl, x, y, w, h, game, controller)
end

-- The cache's per-table state, for the checks: mode (1 bypass, 2 cached)
-- and the slot the picture is in.
function TablePanel.debugPanelMode(tbl) return tbl._pmode, tbl._pslot, tbl._pf == _frame end

-- Empty grid slot — placeholder when table_slots cap allows more tables
-- than are currently active.
function TablePanel.drawEmpty(x, y, w, h, fonts)
    Theme.setColor(Theme.bg.sunken, 0.4)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("empty slot", x, y + math.floor(h / 2) - 8, w, "center")
end

return TablePanel
