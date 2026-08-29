-- views/widgets/MiniButton.lua
--
-- A small square icon button: the chunky Button face at toggle size, with a
-- logical icon in it, falling back to a one-or-two-character glyph when that
-- icon has no art yet (views/Icons draws nothing for an id with no sprite, by
-- design, so a label-less mini button would be an invisible click target).
--
-- Lifted out of views/TablePanel's per-table [D] / [R] header toggles, which
-- were two near-identical 30-line blocks. Anything that needs a compact
-- on/off affordance can use this: table headers, the sidebar's trailing
-- action strip, a future room-editor palette.
--
-- Stateless — call per frame. The caller owns the rect, the hover/press
-- lookup and the hit registration, exactly like views/widgets/LabelButton.
--
-- opts:
--   x, y, size    (required)        — square rect
--   label         (string)          — 1-2 chars, drawn when the icon is absent
--   icon          (icon id)         — preferred; silently skipped if unshipped
--   game          — required for icon lookup
--   fonts         — DI'd font set; uses .sm
--   muted         (bool)            — the OFF state: greyed, with a strike
--   disabled      (bool)            — nothing to act on: greyed, NO strike
--   tint_token    (token, default Theme.fg.heading) — the ON colour
--   fill_token    (token) — face-fill override for an armed/queued state
--                  (the sidebar [x] warn-tints while closes are pending,
--                  mirroring the per-table [x])
--   hovered, press_alpha
--
-- `muted` and `disabled` are deliberately different pictures. Muted means
-- "this is switched off" and gets the strike-through; disabled means "there
-- is nothing here to switch" and is merely grey. A disabled button still
-- occupies its slot, because appearing and disappearing with the state of the
-- world shoves every other element on the row sideways.

local Theme  = require("views.Theme")
local Button = require("views.Button")
local Icons  = require("views.Icons")

local MiniButton = {}

function MiniButton.draw(opts)
    local size  = opts.size or 0
    local fonts = opts.fonts
    local off   = opts.muted == true
    local dead  = opts.disabled == true
    local tint  = opts.tint_token or Theme.fg.heading
    local ink   = (off or dead) and Theme.fg.disabled or tint

    Button.draw(opts.x, opts.y, size, size, {
        fill_color   = (off or dead) and Theme.bg.sunken
                       or opts.fill_token or Theme.bg.widget_hover,
        border_color = (off or dead) and Theme.border.soft or tint,
        hovered      = opts.hovered and not dead,
        press_alpha  = (not dead) and (opts.press_alpha or 0) or 0,
        disabled     = dead,
        depth        = (size <= 14) and 1 or 2,
    }, function(fx, fy, fw, fh)
        local drew = false
        if opts.icon and opts.game then
            local pad = math.max(1, math.floor(fw * 0.15))
            drew = Icons.draw(opts.game, opts.icon,
                              fx + pad, fy + pad, fw - pad * 2, fh - pad * 2)
        end
        if not drew and opts.label and fonts then
            local font = (size <= 14 and (fonts.micro or fonts.xs)) or fonts.sm or fonts.xs
            if font then
                Theme.setColor(ink)
                love.graphics.setFont(font)
                -- Compensate for font top leading whitespace for cap-height glyphs (X, D, R)
                local font_h = font:getHeight()
                local text_y = fy + math.floor(fh * 0.5 - font_h * 0.53)
                love.graphics.printf(opts.label, fx, text_y, fw, "center")
            end
        end
        -- Struck through only for OFF. A disabled button has nothing to be
        -- switched off, so a strike would claim a state it does not have.
        if off and not dead then
            Theme.setColor(Theme.fg.disabled)
            love.graphics.setLineWidth(1)
            love.graphics.line(fx + 2, fy + math.floor(fh * 0.5), fx + fw - 2, fy + math.floor(fh * 0.5))
        end
    end)
end

return MiniButton
