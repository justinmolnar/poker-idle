-- views/ComponentRenderer.lua
-- Draws a flat list of component descriptors stacked vertically.
-- Has no knowledge of what the components represent.
--
-- draw(components, panel_x, panel_w, game, scroll_view?) → total_h
-- hitTest(components, panel_x, panel_w, cx, cy, game) → component or nil
--
-- Lifted from cosmic courier. The `datagrid` component type was dropped —
-- DataGrid isn't lifted into poker-idle. If we need scrolling sub-regions
-- inside a tab in the future, lift it then.

local CR = {}

local Theme       = require("views.Theme")
local Button      = require("views.Button")
local HoverSvc    = require("services.HoverService")
local ClickFlash  = require("services.ClickFlash")

local ICON_SIZE    = 64
local ICON_SPACING = 12
local ICON_ROW_H   = ICON_SIZE + 20

-- Single-row line heights per style. Used as the floor — when a line wraps
-- to multiple visual rows, height becomes N * font:getHeight() instead.
-- Reconfigured from font metrics in CR.configureFromFonts so pixel-font
-- glyphs get visual breathing room between rows; raw font:getHeight is
-- often tighter than the eye expects with chunky pixel fonts.
local LINE_H = { body = 28, small = 22, heading = 28, muted = 22 }

function CR.configureFromFonts(fonts)
    if not (fonts and fonts.md and fonts.sm) then return end
    -- Just the font's natural line height — no extra padding. Pixel
    -- fonts already include leading inside getHeight() so anything
    -- more produces visible empty space between rows.
    LINE_H.body    = fonts.md:getHeight()
    LINE_H.heading = fonts.md:getHeight()
    LINE_H.warning = fonts.md:getHeight()
    LINE_H.small   = fonts.sm:getHeight()
    LINE_H.muted   = fonts.sm:getHeight()
end
local BTN_PAD = 8   -- total vertical padding inside a button (top+bottom)
-- Sidebar buttons render as chunky pushable buttons via views/Button.lua.
-- Allocation = content_h + BTN_DEPTH + lift; the face inside is content_h.
local BTN_DEPTH = 5

-- Resolve a style → font selection. Centralized so buttonH and _button
-- agree on which font is used per line (otherwise wrap math drifts from
-- render math).
local function styleFont(style, game)
    if style == "small" or style == "muted" then return game.fonts.sm end
    return game.fonts.md  -- body / heading / warning
end

local function lineIndent(style)
    return (style == "body" or style == "heading" or style == "warning") and 4 or 10
end

-- How tall does this line render, given the available content width?
-- Returns max(LINE_H[style], rows × font:getHeight()) so single-row lines
-- keep their existing breathing room and wrapped lines grow honestly.
local function lineRenderedHeight(line, game, content_w)
    local style  = line.style or "body"
    local font   = styleFont(style, game)
    local indent = lineIndent(style)
    local wrap_w = math.max(1, content_w - indent - 4)
    local _, wrapped = font:getWrap(line.text or "", wrap_w)
    local n  = math.max(1, #wrapped)
    local fh = font:getHeight()
    local floor_h = LINE_H[style] or fh
    if n == 1 then return floor_h end
    return n * fh
end

-- Inner content height (face content size only, no chrome/depth).
local function contentH(comp, content_w, game)
    local lines = comp.lines
    if not lines or #lines == 0 then return 32 end
    if not (game and game.fonts) then
        local h = BTN_PAD
        for _, line in ipairs(lines) do
            h = h + (LINE_H[line.style or "body"] or 20)
        end
        return h
    end
    local h = BTN_PAD
    for _, line in ipairs(lines) do
        h = h + lineRenderedHeight(line, game, content_w)
    end
    return h
end

-- Total allocation: face content + chunky depth + hover lift.
local function buttonH(comp, content_w, game)
    return Button.allocatedH(contentH(comp, content_w, game), BTN_DEPTH)
end

-- ─── Draw ────────────────────────────────────────────────────────────────────

function CR.draw(components, panel_x, panel_w, game, scroll_view)
    if not components then return 0 end
    local cursor_y = 0
    local p = 10

    for _, comp in ipairs(components) do
        local h = CR._drawComp(comp, panel_x, panel_w, p, cursor_y, game, scroll_view)
        cursor_y = cursor_y + h
    end
    return cursor_y
end

function CR._drawComp(comp, px, pw, p, y, game, scroll_view)
    local t = comp.type

    if t == "label" then
        return CR._label(comp, px, pw, p, y, game)
    elseif t == "button" then
        return CR._button(comp, px, pw, p, y, game)
    elseif t == "icon_row" then
        return CR._iconRow(comp, px, pw, p, y, game)
    elseif t == "divider" then
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("fill", px + p, y + 2, pw - p * 2, Theme.space.hairline)
        return comp.h or 6
    elseif t == "spacer" then
        return comp.h or 8
    elseif t == "custom" then
        local h = comp.h or 0
        if comp.draw_fn then comp.draw_fn(px, y, pw, h, game) end
        return h
    end
    return comp.h or 0
end

function CR._label(comp, px, pw, p, y, game)
    local h     = comp.h or 24
    local style = comp.style or "body"

    love.graphics.setFont(style == "small" and game.fonts.sm or game.fonts.md)

    if style == "heading" then
        Theme.setColor(Theme.fg.heading)
        love.graphics.print(comp.text or "", px + p, y + 4)
        Theme.setColor(Theme.border.default)
        love.graphics.rectangle("fill", px + p, y + h - 2, pw - p * 2, Theme.space.hairline)
    elseif style == "muted" then
        Theme.setColor(Theme.fg.muted)
        love.graphics.print(comp.text or "", px + p, y + 4)
    else
        Theme.setColor(Theme.fg.primary)
        love.graphics.print(comp.text or "", px + p, y + 4)
    end
    return h
end

function CR._button(comp, px, pw, p, y, game)
    local content_w = pw - p * 2
    local total_h   = buttonH(comp, content_w, game)
    local disabled  = comp.disabled
    local hovered   = (not disabled) and comp.id and HoverSvc.is("button", comp.id)
    local press     = (comp.id and ClickFlash.alpha("button", comp.id)) or 0

    -- Resolve face / border colours based on state. The chunky chrome,
    -- hover lift, press depth, and juice scale are all applied by
    -- Button.draw — we just pick the right colour tokens.
    local fill, border
    if disabled then
        fill   = Theme.bg.sunken
        border = Theme.border.soft
    elseif hovered then
        fill   = Theme.bg.widget_hover
        border = Theme.border.strong
    else
        fill   = Theme.bg.chrome
        border = Theme.border.default
    end

    Button.draw(px + p, y, content_w, total_h, {
        fill_color   = fill,
        border_color = border,
        hovered      = hovered,
        press_alpha  = press,
        disabled     = disabled,
        depth        = BTN_DEPTH,
    }, function(fx, fy, fw, fh)
        -- Render line stack inside the (post-press) face rect so labels
        -- move with the button.
        local cursor = fy + (BTN_PAD * 0.5)
        for _, line in ipairs(comp.lines or {}) do
            local style = line.style or "body"
            local font  = styleFont(style, game)
            love.graphics.setFont(font)

            local color
            if disabled then
                color = Theme.fg.disabled
            elseif line.color_token then
                color = (Theme.data and Theme.data[line.color_token])
                     or (Theme.status and Theme.status[line.color_token])
                     or (Theme.fg and Theme.fg[line.color_token])
                     or Theme.fg.primary
            elseif style == "small" or style == "muted" then
                color = Theme.fg.muted
            elseif style == "heading" then
                color = Theme.fg.heading
            elseif style == "warning" then
                color = Theme.status.warn
            else
                color = Theme.fg.primary
            end
            Theme.setColor(color)

            local indent = lineIndent(style)
            local printf_w = fw - indent - 4
            love.graphics.printf(line.text or "",
                fx + indent, cursor, printf_w, line.align or "left")

            -- Optional right-aligned segment on the same row. Lets a
            -- single line carry "name (left) | value (right)" without
            -- spending a second LINE_H worth of vertical space.
            if line.right then
                local right_color = color
                if line.right_color_token then
                    right_color = (Theme.data and Theme.data[line.right_color_token])
                               or (Theme.status and Theme.status[line.right_color_token])
                               or (Theme.fg and Theme.fg[line.right_color_token])
                               or color
                end
                Theme.setColor(right_color)
                love.graphics.printf(line.right,
                    fx + indent, cursor, printf_w, "right")
                Theme.setColor(color)
            end

            cursor = cursor + lineRenderedHeight(line, game, fw)
        end
    end)

    return total_h
end

-- icon_row uses an `emoji_ui` font in CC. Poker-idle has no emoji font yet,
-- so it falls back to `ui` — emoji glyphs will render as "?" tofu, which is
-- fine for now; icon_row is only used if/when we want pictographic catalog
-- displays. Plain text labels still render correctly.
function CR._iconRow(comp, px, pw, p, y, game)
    local h = comp.h or ICON_ROW_H
    local icon_x = px + p + 5

    for _, item in ipairs(comp.items or {}) do
        Theme.setColor(Theme.bg.widget_hover)
        love.graphics.rectangle("fill", icon_x, y + 4, ICON_SIZE, ICON_SIZE)
        Theme.setColor(Theme.border.default)
        love.graphics.rectangle("line", icon_x, y + 4, ICON_SIZE, ICON_SIZE)

        love.graphics.setFont(game.fonts.emoji_ui or game.fonts.md)
        Theme.setColor(Theme.fg.primary)
        love.graphics.printf(item.icon or "?", icon_x, y + 8, ICON_SIZE, "center")

        local label_h = 16
        Theme.setColor(Theme.bg.sunken, 0.6)
        love.graphics.rectangle("fill", icon_x + 1, y + 4 + ICON_SIZE - label_h, ICON_SIZE - 2, label_h - 1)
        love.graphics.setFont(game.fonts.sm)
        Theme.setColor(Theme.fg.primary)
        love.graphics.printf(item.name or "", icon_x, y + 4 + ICON_SIZE - label_h + 2, ICON_SIZE, "center")

        icon_x = icon_x + ICON_SIZE + ICON_SPACING
    end

    return h
end

-- ─── Hit test ────────────────────────────────────────────────────────────────

function CR.hitTest(components, panel_x, panel_w, cx, cy, game)
    if not components then return nil end
    local cursor_y = 0
    local p = 10

    for _, comp in ipairs(components) do
        local h

        if comp.type == "button" then
            h = buttonH(comp, panel_w - p * 2, game)
            if not comp.disabled
            and cy >= cursor_y and cy < cursor_y + h
            and cx >= panel_x + p and cx < panel_x + panel_w - p then
                if comp.id then
                    require("services.HoverService").set("button", comp.id)
                end
                -- Stash the tooltip if the component carries one. The
                -- raw screen-space mouse position is what the Tooltip
                -- service wants for anchoring; the caller passes panel-
                -- content-space `cy`, but `cx` is screen-space.
                if comp.tooltip then
                    local mx, my = love.mouse.getPosition()
                    require("services.Tooltip").set(comp.tooltip, mx, my)
                end
                return comp
            end

        elseif comp.type == "icon_row" then
            h = comp.h or ICON_ROW_H
            if cy >= cursor_y and cy < cursor_y + (ICON_SIZE + 4) then
                local icon_x = panel_x + p + 5
                for _, item in ipairs(comp.items or {}) do
                    if cx >= icon_x and cx < icon_x + ICON_SIZE then
                        return item
                    end
                    icon_x = icon_x + ICON_SIZE + ICON_SPACING
                end
            end

        elseif comp.type == "custom" then
            h = comp.h or 0
            if comp.hit_fn and cy >= cursor_y and cy < cursor_y + h then
                local result = comp.hit_fn(panel_x, cursor_y, panel_w, h, cx, cy)
                if result then return result end
            end

        else
            h = comp.h or 0
        end

        cursor_y = cursor_y + (h or 0)
    end

    return nil
end

return CR
