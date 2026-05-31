-- views/widgets/Row.lua
--
-- Stateless label-value row helpers. Used inside modals (Settings,
-- future preferences screens, etc.) where the same "left-aligned
-- label, right-aligned value, click anywhere on the row" pattern
-- repeats. Returns a hit-rect; caller is responsible for hit-testing
-- and dispatching action.
--
-- Engine-agnostic — knows about Theme tokens and font metrics, never
-- about poker.

local Theme  = require("views.Theme")
local Button = require("views.Button")

local Row = {}

local PAD_X = 14    -- horizontal text padding inside the row

-- Single chunky-button row with [label .... value].
-- opts:
--   x, y, w, h  (required)
--   label       (string, required)
--   value       (string, optional)
--   fonts       (table, required)
--   hovered     (bool, default false)
--   depth       (int, default 3)
--   fill_token  (token, optional — defaults: bg.widget_hover when
--                hovered else bg.widget)
--   border_token (token, optional — defaults: border.strong when
--                 hovered else border.default)
--   label_token (token, default Theme.fg.heading)
--   value_token (token, default Theme.fg.primary)
--   disabled    (bool, default false — greyed, no hover lift)
function Row.draw(opts)
    local fonts    = opts.fonts
    local disabled = opts.disabled
    local hovered  = opts.hovered and not disabled
    local fill, border, label_tok
    if disabled then
        fill, border, label_tok = Theme.bg.sunken, Theme.border.soft, Theme.fg.disabled
    else
        fill      = opts.fill_token or (hovered and Theme.bg.widget_hover or Theme.bg.widget)
        border    = opts.border_token or (hovered and Theme.border.strong or Theme.border.default)
        label_tok = opts.label_token or Theme.fg.heading
    end

    Button.draw(opts.x, opts.y, opts.w, opts.h, {
        fill_color   = fill,
        border_color = border,
        hovered      = hovered,
        disabled     = disabled,
        depth        = opts.depth or 3,
    }, function(fx, fy, fw, fh)
        local label_y = fy + math.floor((fh - fonts.md:getHeight()) * 0.5)
        Theme.setColor(label_tok)
        love.graphics.setFont(fonts.md)
        love.graphics.print(opts.label, fx + PAD_X, label_y)
        if opts.value then
            Theme.setColor(opts.value_token or Theme.fg.primary)
            local vw = fonts.md:getWidth(opts.value)
            love.graphics.print(opts.value, fx + fw - PAD_X - vw, label_y)
        end
    end)
    return { x = opts.x, y = opts.y, w = opts.w, h = opts.h }
end

-- Split row: [-]  LABEL    VALUE  [+]. The center cell is a flat
-- sunken slab (not a button) since clicking it is a no-op; the +/-
-- buttons flank it.
-- opts:
--   x, y, w, h, label, value, fonts (required)
--   left_label, right_label (strings, default "-" and "+")
-- Returns: { left = rect, right = rect }
function Row.drawSplit(opts)
    local fonts   = opts.fonts
    local btn_w   = math.max(36, math.floor(opts.h))   -- square-ish
    local center_w = opts.w - btn_w * 2 - 8
    local cx      = opts.x + btn_w + 4

    local mx, my = love.mouse.getPosition()
    local lhov = mx >= opts.x and mx < opts.x + btn_w and my >= opts.y and my < opts.y + opts.h
    Button.draw(opts.x, opts.y, btn_w, opts.h, {
        fill_color   = lhov and Theme.bg.widget_hover or Theme.bg.widget,
        border_color = Theme.border.default,
        hovered      = lhov, depth = 3,
    }, function(fx, fy, fw, fh)
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.md)
        love.graphics.printf(opts.left_label or "-", fx,
            fy + math.floor((fh - fonts.md:getHeight()) * 0.5), fw, "center")
    end)

    -- Center slab.
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", cx, opts.y, center_w, opts.h, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", cx, opts.y, center_w, opts.h, Theme.space.radius)
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.md)
    local label_y = opts.y + math.floor((opts.h - fonts.md:getHeight()) * 0.5)
    love.graphics.print(opts.label, cx + PAD_X, label_y)
    if opts.value then
        Theme.setColor(Theme.fg.primary)
        local vw = fonts.md:getWidth(opts.value)
        love.graphics.print(opts.value, cx + center_w - PAD_X - vw, label_y)
    end

    local rx   = opts.x + opts.w - btn_w
    local rhov = mx >= rx and mx < rx + btn_w and my >= opts.y and my < opts.y + opts.h
    Button.draw(rx, opts.y, btn_w, opts.h, {
        fill_color   = rhov and Theme.bg.widget_hover or Theme.bg.widget,
        border_color = Theme.border.default,
        hovered      = rhov, depth = 3,
    }, function(fx, fy, fw, fh)
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.md)
        love.graphics.printf(opts.right_label or "+", fx,
            fy + math.floor((fh - fonts.md:getHeight()) * 0.5), fw, "center")
    end)

    return {
        left  = { x = opts.x, y = opts.y, w = btn_w, h = opts.h },
        right = { x = rx,     y = opts.y, w = btn_w, h = opts.h },
    }
end

-- Section divider label — small muted heading text with a subtle
-- bottom border. Used to break up dense modal content.
function Row.drawSection(opts)
    local fonts = opts.fonts
    local sm    = fonts.sm
    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(sm)
    love.graphics.print(opts.label, opts.x + 4, opts.y)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("fill",
        opts.x, opts.y + sm:getHeight() + 4, opts.w, Theme.space.hairline)
end

return Row
