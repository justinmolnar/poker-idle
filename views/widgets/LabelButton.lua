-- views/widgets/LabelButton.lua
--
-- Single-text chunky button. Wraps views/Button.lua with sane defaults
-- so call sites that just want "draw a button at this rect with this
-- text" don't repeat the same Button.draw + setFont + center-y +
-- printf("center") boilerplate.
--
-- Stateless — call LabelButton.draw(...) per frame. Caller owns the
-- rect, hover state, click flash. Used by:
--   • GrindView top-bar buttons (CATALOG, CASH OUT, SETTINGS)
--   • ConfirmDialog Cancel / Confirm buttons
--   • Anywhere else that needs a chunky button with a single text label.

local Theme  = require("views.Theme")
local Button = require("views.Button")

local LabelButton = {}

-- opts:
--   x, y, w, h    (required)        — button rect
--   text          (string, required)
--   fonts         (table, required) — DI'd font set; uses .sm by default
--   font          (Font, optional)  — overrides fonts.sm if provided
--   hovered       (bool, default false)
--   press_alpha   (number 0–1, default 0)
--   disabled      (bool, default false)
--   depth         (int, default 4)
--   fill_token    (token, default Theme.bg.widget_hover)
--   border_token  (token, default Theme.fg.heading)
--   text_token    (token, default Theme.fg.heading; overridden by
--                  Theme.fg.disabled when disabled)
function LabelButton.draw(opts)
    local font = opts.font or (opts.fonts and opts.fonts.sm)

    local fill   = opts.fill_token   or Theme.bg.widget_hover
    local border = opts.border_token or Theme.fg.heading
    local text_c
    if opts.disabled then
        text_c = Theme.fg.disabled
    else
        text_c = opts.text_token or Theme.fg.heading
    end

    Button.draw(opts.x, opts.y, opts.w, opts.h, {
        fill_color   = fill,
        border_color = border,
        hovered      = opts.hovered,
        press_alpha  = opts.press_alpha or 0,
        disabled     = opts.disabled,
        depth        = opts.depth or 4,
    }, function(fx, fy, fw, fh)
        Theme.setColor(text_c)
        if font then love.graphics.setFont(font) end
        local fh_text = font and font:getHeight() or 0
        local text_y  = fy + math.floor((fh - fh_text) * 0.5)
        love.graphics.printf(opts.text, fx, text_y, fw, "center")
    end)
end

return LabelButton
