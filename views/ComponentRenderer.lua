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

local Theme = require("views.Theme")

local ICON_SIZE    = 64
local ICON_SPACING = 12
local ICON_ROW_H   = ICON_SIZE + 20

-- Line heights per style (must match font sizes in game.fonts).
local LINE_H = { body = 20, small = 16, heading = 22, muted = 20 }
local BTN_PAD = 8   -- total vertical padding inside a button (top+bottom)

local function buttonH(comp)
    local lines = comp.lines
    if not lines or #lines == 0 then return 32 end
    local h = BTN_PAD
    for _, line in ipairs(lines) do
        h = h + (LINE_H[line.style or "body"] or 20)
    end
    return h
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

function CR._compHeight(comp, _game)
    local t = comp.type
    if t == "button" then
        return buttonH(comp)
    elseif t == "label"    then return comp.h or 24
    elseif t == "icon_row" then return comp.h or ICON_ROW_H
    elseif t == "divider"  then return comp.h or 6
    elseif t == "spacer"   then return comp.h or 8
    elseif t == "custom"   then return comp.h or 0
    end
    return comp.h or 0
end

function CR._label(comp, px, pw, p, y, game)
    local h     = comp.h or 24
    local style = comp.style or "body"

    love.graphics.setFont(style == "small" and game.fonts.ui_small or game.fonts.ui)

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
    local h        = buttonH(comp)
    local disabled = comp.disabled
    local hovered  = (not disabled) and comp.id
        and require("services.HoverService").is("button", comp.id)

    if disabled then
        Theme.setColor(Theme.bg.sunken, 0.6)
        love.graphics.rectangle("fill", px + p, y, pw - p * 2, h)
    elseif hovered then
        Theme.setColor(Theme.bg.widget_hover, 0.85)
        love.graphics.rectangle("fill", px + p, y, pw - p * 2, h)
    end

    Theme.setColor(disabled and Theme.border.soft
                  or hovered and Theme.border.strong
                  or Theme.border.default)
    love.graphics.setLineWidth(hovered and Theme.space.line_strong or Theme.space.hairline)
    love.graphics.rectangle("line", px + p, y + 1, pw - p * 2, h - 2)
    love.graphics.setLineWidth(Theme.space.hairline)

    local cursor = y + 4
    for _, line in ipairs(comp.lines or {}) do
        local style = line.style or "body"
        local lh    = LINE_H[style] or 20

        local color
        if disabled then
            love.graphics.setFont(style == "small" and game.fonts.ui_small or game.fonts.ui)
            color = Theme.fg.disabled
        elseif style == "small" then
            love.graphics.setFont(game.fonts.ui_small)
            color = Theme.fg.muted
        elseif style == "muted" then
            love.graphics.setFont(game.fonts.ui_small)
            color = Theme.fg.muted
        elseif style == "heading" then
            love.graphics.setFont(game.fonts.ui)
            color = Theme.fg.heading
        elseif style == "warning" then
            love.graphics.setFont(game.fonts.ui)
            color = Theme.status.warn
        else
            love.graphics.setFont(game.fonts.ui)
            color = Theme.fg.primary
        end
        Theme.setColor(color)

        local indent = (style == "body" or style == "heading" or style == "warning") and 4 or 10
        love.graphics.printf(line.text or "", px + p + indent, cursor, pw - p * 2 - indent - 4, "left")
        cursor = cursor + lh
    end

    return h
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

        love.graphics.setFont(game.fonts.emoji_ui or game.fonts.ui)
        Theme.setColor(Theme.fg.primary)
        love.graphics.printf(item.icon or "?", icon_x, y + 8, ICON_SIZE, "center")

        local label_h = 16
        Theme.setColor(Theme.bg.sunken, 0.6)
        love.graphics.rectangle("fill", icon_x + 1, y + 4 + ICON_SIZE - label_h, ICON_SIZE - 2, label_h - 1)
        love.graphics.setFont(game.fonts.ui_small)
        Theme.setColor(Theme.fg.primary)
        love.graphics.printf(item.name or "", icon_x, y + 4 + ICON_SIZE - label_h + 2, ICON_SIZE, "center")

        icon_x = icon_x + ICON_SIZE + ICON_SPACING
    end

    return h
end

-- ─── Hit test ────────────────────────────────────────────────────────────────

function CR.hitTest(components, panel_x, panel_w, cx, cy, _game)
    if not components then return nil end
    local cursor_y = 0
    local p = 10

    for _, comp in ipairs(components) do
        local h

        if comp.type == "button" then
            h = buttonH(comp)
            if not comp.disabled
            and cy >= cursor_y and cy < cursor_y + h
            and cx >= panel_x + p and cx < panel_x + panel_w - p then
                if comp.id then
                    require("services.HoverService").set("button", comp.id)
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
