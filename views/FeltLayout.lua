-- views/FeltLayout.lua
--
-- The single source of truth for where everything sits on a poker-table felt.
-- ONE pure function maps the felt rect -> explicit rects / anchors for every
-- element, so bands can't overlap and edges are real anchors (chips + their
-- $ amount -> left, EV readout -> right).
--
-- Sizing philosophy: the cards are sized to FILL the felt's height (grow when
-- there's room, shrink only when genuinely tight, never below a readable
-- floor) so the table is never microscopic-with-wasted-space. Every BAND
-- survives at every felt size -- opponents included -- and what adapts instead
-- is what goes INSIDE them: a name with no room is dropped, the pot keeps its
-- number and loses its pile, the bottom row sheds its label and then its
-- Stack%, and a card too small for its sprite falls back to a rank plate.
-- Nothing shrinks below 8px, because there is no font below 8px to shrink to.
--
-- PURE (architecture rule 2): no rendering calls, no state mutation. It is
-- geometry only -- text widths (the EV readout) are MEASURED by the
-- caller and passed in as numbers, so this needs neither a font nor a canvas.
-- The reusable 1-D math lives in services/BandStack (rule 4, engine-agnostic).

local BandStack = require("services.BandStack")
local Data      = require("data.felt_layout")
local Style     = require("data.felt_style")

local CARD_ASPECT = 56 / 80   -- card sprite native aspect; heights derive from width

-- Cards scale to fill the felt, clamped to this readable/sane range. Below MIN
-- the layout drops the hole band rather than crushing the cards; MAX stops a
-- very tall felt from blowing the cards up absurdly.
local MIN_CARD_SCALE = 0.3
local MAX_CARD_SCALE = 1.5

-- Bottom-row shed order, most to least worth keeping. The money itself never
-- leaves; the "Tied up" label is chrome and goes before the Stack% does, since
-- the number's position under the pile already says what it is. Module-level
-- because compute() runs once per panel per frame.
local BOTTOM_LADDER = {
    { tied = "full",  ev = "full"  },
    { tied = "short", ev = "full"  },
    { tied = "short", ev = "money" },
    { tied = "full",  ev = nil     },
    { tied = "short", ev = nil     },
}

local FeltLayout = {}

local function ifloor(v) return math.floor(v) end
local function scaled(v, s) return math.max(1, ifloor(v * (s or 1))) end

-- Panel-relative base card sizes (sourced from data/felt_layout's fractions).
function FeltLayout.cardSizes(panel_w)
    local f  = Data.card_frac
    local pw = ifloor(panel_w * f.player)
    local cw = ifloor(panel_w * f.community)
    local ow = ifloor(panel_w * f.opponent)
    return {
        player_w = pw, player_h = ifloor(pw / CARD_ASPECT),
        comm_w   = cw, comm_h   = ifloor(cw / CARD_ASPECT),
        opp_w    = ow, opp_h    = ifloor(ow / CARD_ASPECT),
    }
end

local function scaleSizes(sz, k)
    if k == 1 then return sz end
    return {
        player_w = math.max(1, ifloor(sz.player_w * k)), player_h = math.max(1, ifloor(sz.player_h * k)),
        comm_w   = math.max(1, ifloor(sz.comm_w   * k)), comm_h   = math.max(1, ifloor(sz.comm_h   * k)),
        opp_w    = math.max(1, ifloor(sz.opp_w    * k)), opp_h    = math.max(1, ifloor(sz.opp_h    * k)),
    }
end

-- Compute the full felt layout.
--
-- p = { felt_x, felt_y, felt_w, felt_h, hu, n_opps, sizes (cardSizes result),
--       s (per-panel scale), sm_h, md_h, xs_h (font heights),
--       ev_w / ev_money_w / tied_w / tied_short_w (bottom-row widths),
--       name_ch_w (one character's advance in the seat-name font),
--       bottom_extra = number? (taller bottom band; default thin) }
--
-- Returns a layout table. `.tier` ("full" | "compact" | "micro") is a DERIVED
-- label for the debug overlay — nothing branches on it. The real decisions are
-- per-element flags, each gated by the dimension that constrains it:
--   • opponent names   → seat width   (L.opponents.show_names)
--   • pot pile         → felt height  (L.pot.allow_chips)
--   • bottom-row parts → felt width   (L.bottom.tied.parts / .ev.parts)
--   • card art vs plate→ card width   (L.community.plate / .hole.plate /
--                                      .opponents.plate — one decision per
--                                      band, so the showdown pop can't flip a
--                                      card's representation mid-animation)
--
-- DECOR (data/felt_style) follows the same rule and is published the same way,
-- so views/FeltDecor never re-derives a threshold — it draws what it is handed
-- and skips what is nil:
--   • rail             → felt height  (L.rail)
--   • community plate  → card width   (L.community.plate_rect)
--   • card shadows     → card width   (L.community/.hole/.opponents .shadow,
--                                      per band, same reason as .plate)
--   • seat plates      → the NAME flag (L.opponents.seats[i].plate_rect)
--   • dealer button    → its diameter (L.button)
function FeltLayout.compute(p)
    local sp       = Data.space
    local pile_cfg = Data.pile
    local edge     = scaled(sp.edge_pad,   p.s)
    local botp     = scaled(sp.bottom_pad, p.s)
    local gap      = scaled(sp.band_gap,   p.s)
    local name_gap = scaled(sp.name_gap,   p.s)

    local sm_h = p.sm_h
    local xs_h = p.xs_h or sm_h                             -- opp names + pot text (smaller tier)
    local fx, fy, fw, fh = p.felt_x, p.felt_y, p.felt_w, p.felt_h

    -- ── Rail: the table's outer ring ─────────────────────────────────────
    -- Decided FIRST, before anything measures the felt, because the band solve
    -- runs on the surface INSIDE the ring. Insetting fx/fy/fw/fh here is what
    -- makes every rect below respect the rail automatically -- no draw site
    -- has to know the ring exists and no card can land on the trim.
    --
    -- Gated on felt HEIGHT: the ring costs 2*width off BOTH axes, and height is
    -- the scarce one (the whole point of the pot-band work was reclaiming it).
    -- The 4*rw guard means a felt too small to hold a ring and still have a
    -- surface left simply doesn't get one.
    local rail_cfg = Style.rail
    local rail = nil
    if fh >= (rail_cfg.min_felt_h or math.huge) then
        local short = math.min(fw, fh)
        local rw = ifloor(short * (rail_cfg.frac or 0) + 0.5)
        rw = math.max(rail_cfg.min_w or 1, math.min(rail_cfg.max_w or rw, rw))
        if fw > 4 * rw and fh > 4 * rw then
            rail = {
                x = fx, y = fy, w = fw, h = fh, width = rw,
                radius = math.min(rail_cfg.radius_max or 0,
                                  ifloor(short / (rail_cfg.radius_div or 12))),
            }
            fx, fy = fx + rw, fy + rw
            fw, fh = fw - 2 * rw, fh - 2 * rw
        end
    end

    local usable_h = fh - botp                              -- leave the border clear

    local bottom_min = math.max(sm_h, p.bottom_extra or 0)  -- cash row OR MTT ladder
    local opp_name_h = xs_h                                 -- all seat names are xs (incl. HU)

    -- ── Opponent names: a WIDTH decision, made before the height solve ────
    -- There is no font below 8px to fall back on, so a name that doesn't fit
    -- its seat can only be dropped. Reserving the row anyway would spend 10px
    -- of felt on nothing. The caller measures the font's character advance
    -- (same contract as ev_w) so this stays pure geometry.
    local opp_cfg    = Data.opp or {}
    -- HU's single duel seat is sized by hu_seat, not by fw/n_opps. Estimated
    -- off the UNSCALED opponent card so this stays out of the card-scale solve
    -- it would otherwise be circular with; the duel seat has a generous floor,
    -- so the estimate never lands near the threshold.
    local seat_w_b
    if (p.n_opps or 0) == 1 then
        local hs = Data.hu_seat
        seat_w_b = math.min(fw, math.max(hs.min_w, p.sizes.opp_w * hs.card_mult + hs.extra_w))
    elseif (p.n_opps or 0) > 1 then
        seat_w_b = fw / p.n_opps
    else
        seat_w_b = fw
    end
    local name_chars = (p.name_ch_w and p.name_ch_w > 0)
        and ifloor((seat_w_b - (opp_cfg.name_pad or 0)) / p.name_ch_w)
        or 0
    local show_names = name_chars >= (opp_cfg.name_min_chars or 0)

    -- ── Card scaling: size the cards so the stack FILLS the felt ──────────
    -- card-driven height scales with the cards; font-driven height is fixed.
    -- Solve for the scale that makes (card_parts*k + fixed_parts) == usable_h,
    -- then clamp to [MIN, MAX]. This grows cards into spare room (no wasted
    -- space) and only shrinks them when genuinely tight.
    local base = p.sizes
    local opp_card_b = p.hu and (base.opp_h * Data.hu_seat.card_mult) or base.opp_h
    local chip_frac  = pile_cfg.chip_frac  or 0
    local min_chip_d = pile_cfg.min_chip_d or 0

    -- The pot pile is sized off the COMMUNITY CARD, not off the chip's own base
    -- radius, so growing the chip art can't shrink every card on the felt. The
    -- band reserves the base chip's BOTTOM half only — the pile grows UPWARD
    -- over the community row by design (see the pot block below), so the top
    -- half was always reserving space the pile doesn't sit in.
    --
    -- Both terms are card-proportional, so the solve stays non-circular: the
    -- pot's share of card_parts is a fraction of base.comm_w, which scales with
    -- everything else.
    local function solveScale(with_pile)
        local card_parts = opp_card_b + base.comm_h + base.player_h
        if with_pile then card_parts = card_parts + 0.5 * chip_frac * base.comm_w end
        local fixed_parts = (name_gap + xs_h)         -- gap + pot text, below the pile
                          + name_gap                  -- hole below-cards gap
                          + bottom_min                -- bottom row
                          + 4 * gap                   -- gaps between the 5 bands
        if show_names then
            fixed_parts = fixed_parts + opp_name_h + name_gap
        end
        if card_parts <= 0 then return 1 end
        local k = (usable_h - fixed_parts) / card_parts
        return math.max(MIN_CARD_SCALE, math.min(MAX_CARD_SCALE, k))
    end

    -- Pot-pile presence is the one HEIGHT decision. Solve with the pile, and if
    -- the chip it produces is too small to be anything but a dot, re-solve
    -- without it and let the felt show "Pot: $X" alone. Two passes, terminating:
    -- dropping the pile only ever raises card_scale, so the second solve can't
    -- send the decision back the other way.
    local card_scale = solveScale(true)
    local has_pile   = ifloor(chip_frac * math.max(1, ifloor(base.comm_w * card_scale)))
                       >= min_chip_d
    if not has_pile then card_scale = solveScale(false) end
    local sz = scaleSizes(base, card_scale)

    -- Multi-way seat clamp: each opponent seat is fw/n_opps wide and
    -- draws two cards side by side. The base opponent fraction fits 5
    -- seats (6-max); with 7 (8-max KO) the cards overflow their seat —
    -- cap opponent card width to fit the seat (card gap + inter-seat
    -- breathing room), aspect preserved. Runs AFTER the height solve so
    -- MAX_CARD_SCALE growth can't reintroduce the overflow; the copy
    -- keeps the caller's base sizes table untouched (scaleSizes returns
    -- it unchanged at k == 1). HU (n_opps 1) has its own duel seat.
    if (p.n_opps or 0) > 1 then
        local seat_w = fw / p.n_opps
        local max_ow = ifloor((seat_w - scaled(9, p.s)) / 2)
        if max_ow > 0 and sz.opp_w > max_ow then
            sz = {
                player_w = sz.player_w, player_h = sz.player_h,
                comm_w   = sz.comm_w,   comm_h   = sz.comm_h,
                opp_w    = max_ow,
                opp_h    = ifloor(max_ow / CARD_ASPECT),
            }
        end
    end

    -- ── Chip sizes, from the card each pile sits beside ───────────────────
    -- The pot measures against a community card, the player's pile against a
    -- hole card, so a chip stays roughly two thirds of its neighbour's width at
    -- every panel size. Published as a SCALE against the chip's base radius,
    -- which is the unit views/ChipPile.place takes.
    -- Capped at the chip's AUTHORED diameter: past that the procedural art is
    -- just being stretched, and a chip wider than the card beside it is what
    -- this whole change exists to stop.
    local base_d     = 2 * (p.pile_r or 0)
    local function chipD(card_w)
        local d = math.max(min_chip_d, ifloor(chip_frac * card_w))
        if base_d > 0 then d = math.min(d, base_d) end
        return d
    end
    local pot_chip_d = has_pile and chipD(sz.comm_w) or 0
    local you_chip_d = chipD(sz.player_w)

    -- Card art vs. the small-card plate, decided ONCE per band. The cards in a
    -- band are all one size, and deciding per draw call would let the showdown
    -- pop (which redraws the winning cards ~1.26x larger) flip a card near the
    -- threshold from plate to art mid-animation.
    local plate_below = (Data.card and Data.card.plate_below_w) or 0
    local function platedAt(card_w) return card_w < plate_below end
    local function chipScale(d)
        if base_d <= 0 then return card_scale end
        return d / base_d
    end

    -- Card drop shadows, decided per band for exactly the same reason `plate`
    -- is: the showdown pop redraws the winning cards up to 1.26x larger, and a
    -- per-draw size test would hand a shadow to a card that didn't have one
    -- half a second earlier. 0 = no shadow.
    local sh_cfg     = Style.shadow
    local shadow_off = math.max(1, ifloor((sh_cfg.offset or 0) * (p.s or 1)))
    local function shadowAt(card_w)
        return (card_w >= (sh_cfg.min_card_w or math.huge)) and shadow_off or 0
    end
    -- The opponent card the seat ornaments measure against. HU's duel seat
    -- draws at card_mult, so it crosses every threshold later than the
    -- per-seat boxes do.
    local opp_draw_w = p.hu and (sz.opp_w * Data.hu_seat.card_mult) or sz.opp_w

    -- Minimums with the scaled cards.
    local opp_card_h = p.hu and (sz.opp_h * Data.hu_seat.card_mult) or sz.opp_h
    local opp_min    = opp_card_h + (show_names and (opp_name_h + name_gap) or 0)
    local pot_half   = ifloor(pot_chip_d / 2)
    local comm_min   = sz.comm_h                       -- community cards band only
    -- Pot band: the base chip's BOTTOM half + gap + pot-text line. It carries
    -- the slack weight, so on a roomy felt it expands and the pot floats CENTERED
    -- in the open space between the cards rather than jamming under them.
    local pot_min    = pot_half + name_gap + xs_h
    local hole_min   = sz.player_h + name_gap

    -- Opponents (TOP) -- never dropped. Community cards below them. The POT band
    -- carries the slack weight, so leftover space lands THERE and the pot floats
    -- centered in the gap between the community and hole cards (not jammed under
    -- the cards). Hole cards + bottom row pinned to the BOTTOM.
    -- NOTHING is ever dropped. Every band is required; the cards shrink (down
    -- to MIN_CARD_SCALE) to make room, and if a felt is so tiny that even that
    -- overflows, the bands pack with a little overlap rather than anything
    -- disappearing.
    local bands = {
        { min_h = opp_min,    weight = 0 },   -- 1 opponents
        { min_h = comm_min,   weight = 0 },   -- 2 community cards
        { min_h = pot_min,    weight = 1 },   -- 3 pot (absorbs the slack/gap)
        { min_h = hole_min,   weight = 0 },   -- 4 hole cards
        { min_h = bottom_min, weight = 0 },   -- 5 chips / EV / YOU
    }
    -- No band carries a drop_priority, so allocate never returns nil: every
    -- band is required and the ladder above already decided what exists.
    local rects = BandStack.allocate(usable_h, bands, gap)

    -- `tier` is a DERIVED label, not a switch anything branches on — the real
    -- decisions are the per-element flags below, each gated by the dimension
    -- that actually constrains it. It exists so the backtick debug overlay can
    -- say what the felt gave up.
    local L = {
        tier  = (show_names and "full") or (has_pile and "compact") or "micro",
        sizes = sz, card_scale = card_scale,
        show_names = show_names,
        -- Nil below its gate. views/FeltDecor draws it or skips it; nothing
        -- else on the felt has to know whether there's a ring around it,
        -- because the band rects below are already inside it.
        rail  = rail,
    }

    -- Dealer button size. The layout only says how big the disc is and how far
    -- off the cards it sits; views/TablePanel decides WHICH seat holds it, from
    -- playback_state.button_seat. Sized off the opponent card because that seat
    -- is the tighter of the two places it can land.
    do
        local bc = Style.button
        local d  = ifloor(opp_draw_w * (bc.card_frac or 0) + 0.5)
        if bc.max_d then d = math.min(d, bc.max_d) end
        if d >= (bc.min_d or math.huge) then
            L.button = { d = d, gap = scaled(bc.gap or 1, p.s) }
        end
    end

    -- Opponents band (seats pre-split; HU = one centered duel seat). Never
    -- dropped at any felt size — below the plate threshold the seats' cards
    -- render as plates instead (views/CardSprites), which is what keeps them
    -- readable once they're a dozen pixels wide.
    do
        local r  = rects[1]
        local oy = fy + r.y
        local seats = {}
        if (p.n_opps or 0) == 1 then
            local hs = Data.hu_seat
            local seat_w = math.min(fw, math.max(hs.min_w, sz.opp_w * hs.card_mult + hs.extra_w))
            seats[1] = { x = fx + ifloor((fw - seat_w) / 2), w = seat_w }
        else
            local each = (p.n_opps and p.n_opps > 0) and ifloor(fw / p.n_opps) or fw
            for i = 1, (p.n_opps or 0) do
                seats[i] = { x = fx + (i - 1) * each, w = each }
            end
        end
        local name_band = show_names and (opp_name_h + name_gap) or 0

        -- Seat plate: the backing behind a seat's name + cards, so the seat
        -- reads as a position rather than two cards floating in space. Gated on
        -- the NAME flag rather than a size of its own -- the plate IS the
        -- nameplate, so one flag governs one idea and there is no felt size
        -- where a plate frames nothing.
        -- CLAMPED to the surface: the plate's padding would otherwise push it
        -- off the top of the opponents band, which is flush with the top of the
        -- felt, and paint it onto the rail.
        if show_names then
            local spc  = Style.seat_plate
            local px, py = scaled(spc.pad_x, p.s), scaled(spc.pad_y, p.s)
            local top  = math.max(fy, oy - py)
            local bot  = math.min(fy + fh, oy + name_band + opp_card_h + py)
            for _, seat in ipairs(seats) do
                local sx = math.max(fx, seat.x + px)
                local sr = math.min(fx + fw, seat.x + seat.w - px)
                if sr > sx and bot > top then
                    seat.plate_rect = { x = sx, y = top, w = sr - sx, h = bot - top }
                end
            end
        end

        L.opponents = {
            x = fx, y = oy, w = fw, h = r.h,
            name_h = show_names and opp_name_h or 0, card_h = opp_card_h,
            show_names = show_names, name_chars = name_chars,
            -- HU's duel seat draws at card_mult, so it crosses the plate
            -- threshold later than the per-seat boxes do.
            plate  = platedAt(opp_draw_w),
            shadow = shadowAt(opp_draw_w),
            cards_y_offset = name_band,
            anchor_y = oy + name_band + ifloor(opp_card_h / 2),
            hu = p.hu, seats = seats,
        }
    end

    -- Community cards (rects[2]).
    local cb     = rects[2]
    local cb_y   = fy + cb.y
    local cgap   = scaled(sp.comm_gap, p.s)
    -- Recessed strip behind the five slots, so an empty slot reads as a place
    -- at the table rather than a hole in the felt. `plate_rect` is decor;
    -- `plate` right below it is step 3's card-ART boolean. Different things.
    local comm_plate_rect = nil
    do
        local cp = Style.comm_plate
        if sz.comm_w >= (cp.min_card_w or math.huge) then
            local px, py = scaled(cp.pad_x, p.s), scaled(cp.pad_y, p.s)
            local pw = math.min(fw, sz.comm_w * 5 + 4 * cgap + 2 * px)
            comm_plate_rect = {
                x = fx + ifloor((fw - pw) / 2), y = cb_y - py,
                w = pw, h = sz.comm_h + 2 * py,
            }
        end
    end
    L.community = {
        x = fx, y = cb_y, w = fw,
        card_w = sz.comm_w, card_h = sz.comm_h, gap = cgap,
        plate  = platedAt(sz.comm_w),
        shadow = shadowAt(sz.comm_w),
        plate_rect = comm_plate_rect,
    }
    -- Pot (rects[3], the weighted band): center the pile + text BLOCK in this
    -- band's open space, so the chips sit DOWN in the gap between the community
    -- and hole cards with breathing room, not jammed under the community row.
    -- Only the base chip's BOTTOM half is inside this band, so chips_y (the base
    -- chip's CENTER) sits at the block's top edge and the pile grows up out of
    -- the band, over the community row.
    local pbnd      = rects[3]
    local pbnd_y    = fy + pbnd.y
    local block_h   = pot_half + name_gap + xs_h
    local block_top = pbnd_y + ifloor((pbnd.h - block_h) / 2)
    local chips_y    = block_top                       -- base chip center; pile grows UP
    local pot_text_y = chips_y + pot_half + name_gap   -- text below the base chip
    L.pot = {
        center_x   = fx + ifloor(fw / 2),
        chips_y     = chips_y,
        text_x      = fx, text_w = fw, text_y = pot_text_y,
        max_w       = fw - 4 * edge,
        max_cols    = pile_cfg.pot_cols,
        max_rows    = pile_cfg.pot_rows,
        -- Dropped once a chip would be too small to be anything but a dot; the
        -- "Pot: $X" text carries the whole readout from there down.
        allow_chips = has_pile,
        chip_d      = pot_chip_d,
        chip_scale  = chipScale(pot_chip_d),
    }

    -- Hole-card band (rects[4]).
    do
        local r = rects[4]
        local below_y = fy + r.y + sz.player_h + name_gap
        L.hole = {
            x = fx, y = fy + r.y, w = fw,
            card_w = sz.player_w, card_h = sz.player_h, gap = scaled(sp.hole_gap, p.s),
            plate  = platedAt(sz.player_w),
            shadow = shadowAt(sz.player_w),
            hand_name_y = below_y,
            below_y = below_y,
        }
    end

    -- Bottom row (rects[5]): the player chip pile hugs the LEFT edge with its
    -- "Tied up $X" line beneath it (the money sits with the chips it prices),
    -- and the EV readout is pinned to the RIGHT edge — the caller measured
    -- ev_w so the layout can right-align its left-anchored draw.
    local bot = rects[5]
    local base_bottom = fy + bot.y + bot.h
    local text_top    = base_bottom - sm_h
    -- Wide enough for the whole pile on ONE row in the common case. This
    -- was a quarter of the felt back when a chip was 26px across; at 44px
    -- that budget clipped a $1.96 stack down to a single 25c chip. Nothing
    -- else sits on this row, so the space is free.
    local chips_w     = ifloor(fw * 0.55)

    -- Two left/right-anchored strings on ONE line, and no font below 8px to
    -- shrink into, so the row can only SHED (see BOTTOM_LADDER). This used to
    -- be `show = ev_w > 0`, which is always true, so the two ran into each
    -- other on any felt narrower than about 220px.
    local tied_full  = p.tied_w or 0
    local tied_short = p.tied_short_w or tied_full
    local ev_full    = p.ev_w or 0
    local ev_money   = p.ev_money_w or ev_full
    local pad        = scaled(sp.you_pad, p.s)
    local inner_w    = fw - 2 * edge

    local tied_parts, tied_w = "short", tied_short
    local ev_parts, ev_w, ev_x = nil, 0, fx + fw - edge
    for _, rung in ipairs(BOTTOM_LADDER) do
        local tw = (rung.tied == "full") and tied_full or tied_short
        local ew = (rung.ev == "full" and ev_full)
                or (rung.ev == "money" and ev_money) or 0
        if ew > 0 then
            local t = BandStack.threeUp(inner_w, tw, ew, 0, pad)
            if t.center_show then
                tied_parts, tied_w = rung.tied, tw
                ev_parts, ev_w, ev_x = rung.ev, ew, fx + edge + t.right_x
                break
            end
        elseif tw <= inner_w then
            tied_parts, tied_w = rung.tied, tw
            break
        end
    end

    L.bottom = {
        baseline_y = text_top,
        -- The player's pile is sized off a HOLE card, the same way the pot is
        -- sized off a community card — not off card_scale, which tied it to the
        -- chip art's own base radius.
        chip_scale = chipScale(you_chip_d),
        chip_d     = you_chip_d,
        band  = { x = fx, y = fy + bot.y, w = fw, h = bot.h },
        -- Chips raised just above the tied-up line so the pile sits on top of it.
        chips = { x = fx + edge, y = text_top - name_gap, align = "left",
                  max_w = chips_w,
                  max_cols = pile_cfg.player_cols, max_rows = pile_cfg.player_rows },
        tied  = { x = fx + edge, y = text_top, align = "left",
                  w = tied_w, parts = tied_parts },
        ev    = { x = ev_x, y = text_top, w = ev_w,
                  show = ev_parts ~= nil, parts = ev_parts },
        inner_w = inner_w,          -- for callers laying out their own L/R pair
        pad     = pad,
        right_x = fx + fw - edge,   -- right text edge (tournament labels)
    }

    return L
end

return FeltLayout
