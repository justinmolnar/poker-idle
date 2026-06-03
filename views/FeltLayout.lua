-- views/FeltLayout.lua
--
-- The single source of truth for where everything sits on a poker-table felt.
-- ONE pure function maps the felt rect -> explicit rects / anchors for every
-- element, so bands can't overlap and edges are real anchors (chips->left,
-- YOU->right).
--
-- Sizing philosophy: the cards are sized to FILL the felt's height (grow when
-- there's room, shrink only when genuinely tight, never below a readable
-- floor) so the table is never microscopic-with-wasted-space. Opponents are
-- NEVER dropped to make room -- the hole-card band yields first, and only on a
-- truly tiny felt does it fall back to the mini (DEAL + pot text) layout.
--
-- PURE (architecture rule 2): no rendering calls, no state mutation. It is
-- geometry only -- text widths (EV readout, YOU label) are MEASURED by the
-- caller and passed in as numbers, so this needs neither a font nor a canvas.
-- The reusable 1-D math lives in services/BandStack (rule 4, engine-agnostic).

local BandStack = require("services.BandStack")
local Data      = require("data.felt_layout")

local CARD_ASPECT = 56 / 80   -- card sprite native aspect; heights derive from width

-- Cards scale to fill the felt, clamped to this readable/sane range. Below MIN
-- the layout drops the hole band rather than crushing the cards; MAX stops a
-- very tall felt from blowing the cards up absurdly.
local MIN_CARD_SCALE = 0.3
local MAX_CARD_SCALE = 1.5

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
--       s (per-panel scale), sm_h, md_h, xs_h (font heights; xs_h is the small
--       tier used by opp names + pot text, so those rows reserve less and the
--       cards grow into it), ev_w, you_w (measured widths),
--       bottom_extra = number? (taller bottom band; default thin) }
--
-- Returns a layout table; `.tier` is "full" | "compact" | "mini".
function FeltLayout.compute(p)
    local sp       = Data.space
    local edge     = scaled(sp.edge_pad,   p.s)
    local botp     = scaled(sp.bottom_pad, p.s)
    local gap      = scaled(sp.band_gap,   p.s)
    local name_gap = scaled(sp.name_gap,   p.s)
    local you_pad  = scaled(sp.you_pad,    p.s)

    local sm_h = p.sm_h
    local xs_h = p.xs_h or sm_h                             -- opp names + pot text (smaller tier)
    local fx, fy, fw, fh = p.felt_x, p.felt_y, p.felt_w, p.felt_h
    local usable_h = fh - botp                              -- leave the border clear

    local bottom_min = math.max(sm_h, p.bottom_extra or 0)  -- cash row OR MTT ladder
    local opp_name_h = p.hu and p.md_h or xs_h              -- per-seat names are xs now

    -- ── Card scaling: size the cards so the stack FILLS the felt ──────────
    -- card-driven height scales with the cards; font-driven height is fixed.
    -- Solve for the scale that makes (card_parts*k + fixed_parts) == usable_h,
    -- then clamp to [MIN, MAX]. This grows cards into spare room (no wasted
    -- space) and only shrinks them when genuinely tight.
    local base = p.sizes
    local opp_card_b = p.hu and (base.opp_h * Data.hu_seat.card_mult) or base.opp_h
    -- The pot floats in its own (weighted) band in the open space below the
    -- community, so reserve the base chip's FULL diameter (2 * pile_r). The pile
    -- scales with the cards (chip_scale = card_scale), so it belongs in
    -- card_parts; the gap + the xs pot-text line are fixed.
    local card_parts = opp_card_b + base.comm_h + 2 * (p.pile_r or 0) + base.player_h
    local fixed_parts = (opp_name_h + name_gap)   -- opponents name line
                      + (name_gap + xs_h)         -- gap + pot text (xs), below the pile
                      + name_gap                  -- hole below-cards gap
                      + bottom_min                -- bottom row
                      + 4 * gap                   -- gaps between the 5 bands
    local card_scale = 1
    if card_parts > 0 then
        card_scale = (usable_h - fixed_parts) / card_parts
        card_scale = math.max(MIN_CARD_SCALE, math.min(MAX_CARD_SCALE, card_scale))
    end
    local sz = scaleSizes(base, card_scale)

    -- Minimums with the scaled cards.
    local opp_card_h = p.hu and (sz.opp_h * Data.hu_seat.card_mult) or sz.opp_h
    local opp_min    = opp_card_h + opp_name_h + name_gap
    local pile_r_eff = ifloor((p.pile_r or 0) * card_scale)
    local comm_min   = sz.comm_h                       -- community cards band only
    -- Pot band: base chip (full diameter) + gap + xs pot-text line. It carries
    -- the slack weight, so on a roomy felt it expands and the pot floats CENTERED
    -- in the open space between the cards rather than jamming under them.
    local pot_min    = 2 * pile_r_eff + name_gap + xs_h
    local hole_min   = sz.player_h + name_gap

    -- Mini: not even community + bottom row fit -- pot text + DEAL.
    local function miniLayout()
        return {
            tier = "mini", sizes = sz, card_scale = card_scale,
            pot  = {
                center_x   = fx + ifloor(fw / 2),
                text_x     = fx, text_w = fw,
                text_y     = fy + ifloor(fh / 2) - ifloor(sm_h / 2),
                chips_y    = fy + ifloor(fh / 2),
                max_w      = fw - 4 * edge,
                allow_chips = false,
            },
        }
    end

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
    local rects = BandStack.allocate(usable_h, bands, gap)
    if not rects then return miniLayout() end

    local has_opp  = rects[1] ~= nil
    local has_hole = rects[4] ~= nil
    local L = {
        tier  = has_opp and "full" or "compact",
        sizes = sz, card_scale = card_scale,
    }

    -- Opponents band (seats pre-split; HU = one centered duel seat).
    if has_opp then
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
        L.opponents = {
            x = fx, y = oy, w = fw, h = r.h,
            name_h = opp_name_h, card_h = opp_card_h,
            cards_y_offset = opp_name_h + name_gap,
            anchor_y = oy + opp_name_h + name_gap + ifloor(opp_card_h / 2),
            hu = p.hu, seats = seats,
        }
    end

    -- Community cards (rects[2]).
    local cb   = rects[2]
    local cb_y = fy + cb.y
    L.community = {
        x = fx, y = cb_y, w = fw,
        card_w = sz.comm_w, card_h = sz.comm_h, gap = scaled(sp.comm_gap, p.s),
    }
    -- Pot (rects[3], the weighted band): center the pile + text BLOCK in this
    -- band's open space, so the chips sit DOWN in the gap between the community
    -- and hole cards with breathing room, not jammed under the community row.
    local pbnd      = rects[3]
    local pbnd_y    = fy + pbnd.y
    local block_h   = 2 * pile_r_eff + name_gap + xs_h
    local block_top = pbnd_y + ifloor((pbnd.h - block_h) / 2)
    local chips_y    = block_top + pile_r_eff           -- base chip center; pile grows UP
    local pot_text_y = chips_y + pile_r_eff + name_gap  -- text below the base chip
    L.pot = {
        center_x   = fx + ifloor(fw / 2),
        chips_y     = chips_y,
        text_x      = fx, text_w = fw, text_y = pot_text_y,
        max_w       = fw - 4 * edge,
        allow_chips = true,
        chip_scale  = card_scale,                -- pot pile scales with the cards
    }

    -- Hole-card band (rects[4]).
    if has_hole then
        local r = rects[4]
        local below_y = fy + r.y + sz.player_h + name_gap
        L.hole = {
            x = fx, y = fy + r.y, w = fw,
            card_w = sz.player_w, card_h = sz.player_h, gap = scaled(sp.hole_gap, p.s),
            hand_name_y = below_y,
            below_y = below_y,
        }
    end

    -- Bottom row (rects[5]): chips (left edge) | EV (centered, droppable) |
    -- YOU (right edge), one bottom_pad above the felt border.
    local bot = rects[5]
    local base_bottom = fy + bot.y + bot.h
    local text_top    = base_bottom - sm_h
    local chips_w     = ifloor(fw * 0.25)
    local tu = BandStack.threeUp(fw - 2 * edge, chips_w, p.you_w or 0, p.ev_w or 0, you_pad)
    L.bottom = {
        baseline_y = text_top,
        chip_scale = card_scale,                -- player pile scales with the cards
        band  = { x = fx, y = fy + bot.y, w = fw, h = bot.h },
        chips = { x = fx + edge,                y = base_bottom, align = "left",  max_w = chips_w },
        you   = { x = fx + fw - edge,           y = text_top,    align = "right" },
        -- The EV readout is ALWAYS shown (never dropped). It renders centered
        -- in the row; on a narrow felt it simply sits closer to the chips/YOU.
        ev    = { x = fx + edge + tu.center_x,  y = text_top, w = p.ev_w or 0,
                  show = (p.ev_w or 0) > 0 },
    }

    return L
end

return FeltLayout
