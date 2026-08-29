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
local Icons       = require("views.Icons")
local IconText    = require("views.IconText")
local AwardGlow   = require("views.AwardGlow")
local Anchors     = require("services.AnchorRegistry")
local MiniButton  = require("views.widgets.MiniButton")

-- Icon row sizes — recomputed by CR.setScale at boot/resize.
local ICON_SIZE_BASE    = 64
local ICON_SPACING_BASE = 12

local ICON_SIZE    = ICON_SIZE_BASE
local ICON_SPACING = ICON_SPACING_BASE
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

-- Total vertical padding inside a button (top+bottom). Scaled in
-- CR.setScale so the multi-line stake-add buttons grow with the
-- window — without this, content gets cramped at large resolutions
-- where the font has 2× breathing room but the button doesn't.
local BTN_PAD_BASE = 8
local BTN_PAD      = BTN_PAD_BASE
-- Sidebar buttons render as chunky pushable buttons via views/Button.lua.
-- Allocation = content_h + BTN_DEPTH + lift; the face inside is content_h.
local BTN_DEPTH_BASE = 5
local BTN_DEPTH      = BTN_DEPTH_BASE

-- Rescale icon-row + button dimensions against the live ui_scale.
-- main.lua calls this at boot + on resize.
function CR.setScale(s)
    s = s or 1
    ICON_SIZE    = math.floor(ICON_SIZE_BASE    * s)
    ICON_SPACING = math.floor(ICON_SPACING_BASE * s)
    ICON_ROW_H   = ICON_SIZE + math.floor(20 * s)
    BTN_PAD      = math.floor(BTN_PAD_BASE      * s)
    BTN_DEPTH    = math.max(2, math.floor(BTN_DEPTH_BASE * s))
end

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
-- Subtracts the right-segment's width (rendered in fonts.sm) from the
-- available wrap width so a heading + right badge that overflows wraps
-- into multiple visual rows and the button allocates the right height.
local function lineRenderedHeight(line, game, content_w)
    local style  = line.style or "body"
    local font   = styleFont(style, game)
    -- Icon-bearing lines render single-line via IconText (no wrapping).
    if (line.text or ""):find("{", 1, true) then
        return LINE_H[style] or font:getHeight()
    end
    local indent = lineIndent(style)
    local right_w = 0
    if line.right and game.fonts and game.fonts.sm then
        right_w = game.fonts.sm:getWidth(line.right) + 8
        if line.right_icon then right_w = right_w + game.fonts.sm:getHeight() + 4 end
    end
    -- A second badge (line.right2 / right2_icon) sits left of the first.
    if line.right2 and game.fonts and game.fonts.sm then
        right_w = right_w + game.fonts.sm:getWidth(line.right2) + 8
        if line.right2_icon then right_w = right_w + game.fonts.sm:getHeight() + 4 end
    end
    local wrap_w = math.max(1, content_w - indent - 4 - right_w)
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

-- ─── Type registry (data-driven dispatch) ───────────────────────────────────
--
-- Adding a new component type = one entry here. No if/elseif chains on
-- comp.type anywhere; both draw and hit-test walk the registry.
--
-- Per-type slots (all optional except `measureH`):
--   draw(comp, px, pw, p, y, game) → h         renders, returns allocated h
--   hit (comp, px, pw, p, y, h, cx, cy) → res  hit-test, returns comp/item or nil
--   measureH(comp, content_w, game) → h        height the layout walker should
--                                              advance by, computed before draw
--                                              so hit-test knows the rect
--
-- Note: `draw` may return the same value `measureH` reports — the registry
-- doesn't enforce equality, but layout drift is the consequence if they
-- diverge.

local function _drawDivider(comp, px, pw, p, y, _game)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("fill", px + p, y + 2, pw - p * 2, Theme.space.hairline)
    return comp.h or 6
end

local function _drawSpacer(comp, _px, _pw, _p, _y, _game)
    return comp.h or 8
end

local function _drawCustom(comp, px, pw, _p, y, game)
    local h = comp.h or 0
    if comp.draw_fn then comp.draw_fn(px, y, pw, h, game) end
    return h
end

-- Where a button's trailing action strip lives, and how big each square is.
-- One source for the layout so the draw and the hit test cannot disagree
-- about which pixels belong to an action vs. to the button underneath.
local ACTION_PAD = 3

local function actionSize(h, n)
    n = math.max(1, n or 1)
    local pad = (n >= 3) and 2 or ACTION_PAD
    local avail_h = h - pad * (n + 1)
    local max_s = math.floor(avail_h / n)
    local size = math.max(10, math.min(max_s, 22))
    return size, pad
end

local function actionRect(comp, panel_x, panel_w, p, y, h, i)
    local n = #(comp.actions or {})
    local size, pad = actionSize(h, n)
    local total_column_h = n * size + (n - 1) * pad
    local start_y = y + math.floor((h - total_column_h) * 0.5)
    local x = panel_x + panel_w - p - size - pad
    local ay = start_y + (i - 1) * (size + pad)
    return x, ay, size
end

-- Horizontal space the action strip eats, so the button's own text can be
-- measured/clipped against what is actually left.
function CR.actionStripW(comp, h)
    local n = comp and comp.actions and #comp.actions or 0
    if n == 0 then return 0 end
    local size, pad = actionSize(h, n)
    return size + pad * 2
end

local function _hitButton(comp, panel_x, panel_w, p, cursor_y, h, cx, cy)
    -- Trailing actions are hit-tested FIRST and independently of the button's
    -- own disabled state: "cash out every table of this type" is exactly the
    -- thing you want when the parent +ADD is greyed out because you're broke.
    -- Each returns its own descriptor, so the dispatcher routes on its id.
    if comp.actions and cy >= cursor_y and cy < cursor_y + h then
        local depth = BTN_DEPTH
        local face_h = math.max(2, h - depth - 1)
        local face_y = cursor_y + 1
        local fx = panel_x + p
        local fw = panel_w - p * 2
        for i, act in ipairs(comp.actions) do
            local ax, ay, size = actionRect(comp, fx, fw, 4, face_y, face_h, i)
            if cx >= ax and cx < ax + size and cy >= ay and cy < ay + size then
                -- No tooltip on a dead action: it has nothing to tell you.
                -- (Unlike the parent button, where "can't afford" is the
                -- information you actually want while deciding to save.)
                if act.disabled then return nil end
                if act.tooltip then
                    local mx, my = love.mouse.getPosition()
                    require("services.Tooltip").set(act.tooltip, mx, my)
                end
                if act.id then HoverSvc.set("button", act.id) end
                return act
            end
        end
    end

    if cy >= cursor_y and cy < cursor_y + h
       and cx >= panel_x + p and cx < panel_x + panel_w - p then
        -- Tooltip shows even when the button is disabled (can't afford / would
        -- strand) — the player needs the info to decide whether to save up.
        if comp.tooltip then
            local mx, my = love.mouse.getPosition()
            require("services.Tooltip").set(comp.tooltip, mx, my)
        end
        if comp.disabled then return nil end
        if comp.id then HoverSvc.set("button", comp.id) end
        return comp
    end
    return nil
end

local function _hitIconRow(comp, panel_x, _panel_w, p, cursor_y, _h, cx, cy)
    if cy >= cursor_y and cy < cursor_y + (ICON_SIZE + 4) then
        local icon_x = panel_x + p + 5
        for _, item in ipairs(comp.items or {}) do
            if cx >= icon_x and cx < icon_x + ICON_SIZE then
                return item
            end
            icon_x = icon_x + ICON_SIZE + ICON_SPACING
        end
    end
    return nil
end

local function _hitCustom(comp, panel_x, panel_w, _p, cursor_y, h, cx, cy)
    if comp.hit_fn and cy >= cursor_y and cy < cursor_y + h then
        local result = comp.hit_fn(panel_x, cursor_y, panel_w, h, cx, cy)
        if result then return result end
    end
    return nil
end

local function _staticH(default)
    return function(comp, _w, _game) return comp.h or default end
end

CR.types = {
    label    = { draw = nil,           hit = nil,        measureH = _staticH(24) },
    button   = { draw = nil,           hit = _hitButton, measureH = function(comp, w, game) return buttonH(comp, w, game) end },
    -- icon_row reads ICON_ROW_H live: CR.setScale mutates the upvalue at
    -- runtime, so a captured default would freeze at the boot value.
    icon_row = { draw = nil,           hit = _hitIconRow, measureH = function(comp, _w, _g) return comp.h or ICON_ROW_H end },
    divider  = { draw = _drawDivider,  hit = nil,        measureH = _staticH(6) },
    spacer   = { draw = _drawSpacer,   hit = nil,        measureH = _staticH(8) },
    custom   = { draw = _drawCustom,   hit = _hitCustom, measureH = _staticH(0) },
}

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

function CR._drawComp(comp, px, pw, p, y, game, _scroll_view)
    local def = CR.types[comp.type]
    if not (def and def.draw) then return comp.h or 0 end
    return def.draw(comp, px, pw, p, y, game)
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

    -- Optional identity face (the add-table rows wear their stake's felt).
    -- State still speaks: hover lightens the same color, disabled falls
    -- back to the sunken grey above.
    if comp.face_color and not disabled then
        local f = comp.face_color
        if hovered then
            fill = { math.min(1, f[1] * 1.35 + 0.03),
                     math.min(1, f[2] * 1.35 + 0.03),
                     math.min(1, f[3] * 1.35 + 0.03) }
        else
            fill = f
        end
    end

    -- Optional explicit border override (e.g. a gold "{chip} banked" trim on
    -- the add-table button). Stays through hover; when the button is disabled
    -- (can't afford / tables full) it persists but DIMMED, so the banked state
    -- still reads even when you can't open another.
    if comp.border_color then
        if disabled then
            local g = comp.border_color
            border = { g[1] * 0.5, g[2] * 0.5, g[3] * 0.5 }
        else
            border = comp.border_color
        end
    end

    Button.draw(px + p, y, content_w, total_h, {
        fill_color   = fill,
        border_color = border,
        hovered      = hovered,
        press_alpha  = press,
        disabled     = disabled,
        depth        = BTN_DEPTH,
    }, function(fx, fy, fw, fh)
        -- Measure total lines height to center text stack vertically on the button face
        local total_lines_h = 0
        for _, line in ipairs(comp.lines or {}) do
            total_lines_h = total_lines_h + lineRenderedHeight(line, game, fw)
        end
        local cursor = fy + math.max(2, math.floor((fh - total_lines_h) * 0.5))

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
            -- Give up the right end to the action strip, so right-aligned
            -- text ("+2 {chip}", "buy-in $2.00") stops where the buttons
            -- start instead of rendering underneath them.
            local printf_w = fw - indent - 4 - CR.actionStripW(comp, total_h)

            local right_font = (game.fonts and game.fonts.sm) or font
            local right_w    = 0
            if line.right then
                right_w = right_font:getWidth(line.right) + 8
            end

            local left_printf_w = math.max(1, printf_w - right_w)
            if (line.text or ""):find("{", 1, true) then
                IconText.draw(game, line.text, fx + indent, cursor, font, color)
            else
                love.graphics.printf(line.text or "",
                    fx + indent, cursor, left_printf_w, line.align or "left")
            end

            if line.right then
                local right_color = color
                if line.right_color_token then
                    right_color = (Theme.data and Theme.data[line.right_color_token])
                               or (Theme.status and Theme.status[line.right_color_token])
                               or (Theme.fg and Theme.fg[line.right_color_token])
                               or color
                end
                love.graphics.setFont(right_font)
                Theme.setColor(right_color)
                local right_y = cursor + math.floor((font:getHeight() - right_font:getHeight()) / 2)
                local icon_d = line.right_icon and right_font:getHeight() or 0
                local text_w = (icon_d > 0) and math.max(1, printf_w - icon_d - 4) or printf_w
                love.graphics.printf(line.right,
                    fx + indent, right_y, text_w, "right")
                if line.right_icon == "achip" then
                    Icons.drawAntiChip(game, fx + indent + printf_w - icon_d, right_y, icon_d,
                        line.right_icon_alpha, line.right_icon_shade)
                elseif line.right_icon then
                    Icons.drawChip(game, fx + indent + printf_w - icon_d, right_y, icon_d,
                        line.right_icon_alpha, line.right_icon_shade)
                end
                if comp.badge_anchor and icon_d > 0 then
                    local bx0 = fx + indent + text_w
                                - right_font:getWidth(line.right)
                    local sx, sy = love.graphics.transformPoint(bx0, right_y)
                    Anchors.set(comp.badge_anchor, sx, sy,
                        (fx + indent + printf_w) - bx0,
                        right_font:getHeight())
                end
                -- Second badge: the same shape, immediately left of the
                -- first (the add-table button shows "+N {achip}" beside
                -- "+N {chip}" in Act 3, when a stake pays both).
                if line.right2 then
                    local color2 = color
                    if line.right2_color_token then
                        color2 = (Theme.data and Theme.data[line.right2_color_token])
                              or (Theme.status and Theme.status[line.right2_color_token])
                              or (Theme.fg and Theme.fg[line.right2_color_token])
                              or color
                    end
                    local first_w = right_font:getWidth(line.right) + icon_d + 4
                    local icon2_d = line.right2_icon and right_font:getHeight() or 0
                    local text2_w = math.max(1, printf_w - first_w - 8 - icon2_d - 4)
                    Theme.setColor(color2)
                    love.graphics.printf(line.right2, fx + indent, right_y, text2_w, "right")
                    local ix2 = fx + indent + text2_w + 4
                    if line.right2_icon == "achip" then
                        Icons.drawAntiChip(game, ix2, right_y, icon2_d,
                            line.right2_icon_alpha, line.right2_icon_shade)
                    elseif line.right2_icon then
                        Icons.drawChip(game, ix2, right_y, icon2_d,
                            line.right2_icon_alpha, line.right2_icon_shade)
                    end
                end
                Theme.setColor(color)
                love.graphics.setFont(font)
            end

            cursor = cursor + lineRenderedHeight(line, game, fw)
        end

        -- Render action sub-buttons inside the post-press face rect
        if comp.actions then
            for i, act in ipairs(comp.actions) do
                local ax, ay, size = actionRect(comp, fx, fw, 4, fy, fh, i)
                MiniButton.draw{
                    x = ax, y = ay, size = size,
                    label      = act.label,
                    icon       = act.icon,
                    game       = game,
                    fonts      = game and game.fonts,
                    muted      = act.muted,
                    disabled   = act.disabled,
                    tint_token = act.tint_token,
                    fill_token = act.fill_token,
                    hovered    = act.id and HoverSvc.is("button", act.id),
                    press_alpha = (act.id and ClickFlash.alpha("button", act.id)) or 0,
                }
            end
        end
    end)

    -- Chip-award fanfare: a gold pulse over the button face the moment a
    -- bounty banks (GrindView fires it; shared with the game-type tab strip).
    AwardGlow.draw(comp.id, px + p, y, content_w, total_h)

    -- Optional named anchor (tutorial-hint highlight target). Panel draws
    -- components under a scroll translate, so run the local rect through
    -- the current transform to land in screen space.
    if comp.anchor then
        local sx, sy = love.graphics.transformPoint(px + p, y)
        Anchors.set(comp.anchor, sx, sy, content_w, total_h)
    end

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
        local def = CR.types[comp.type]
        local h = def and def.measureH(comp, panel_w - p * 2, game) or (comp.h or 0)
        if def and def.hit then
            local result = def.hit(comp, panel_x, panel_w, p, cursor_y, h, cx, cy)
            if result then return result end
        end
        cursor_y = cursor_y + h
    end

    return nil
end

-- Wire the draw slots that depend on private renderers defined above.
-- Done at the bottom because CR._label / CR._button / CR._iconRow are
-- only assigned during the file's top-to-bottom load — referencing them
-- inside the registry literal would capture nil.
CR.types.label.draw    = function(c, px, pw, p, y, g) return CR._label   (c, px, pw, p, y, g) end
CR.types.button.draw   = function(c, px, pw, p, y, g) return CR._button  (c, px, pw, p, y, g) end
CR.types.icon_row.draw = function(c, px, pw, p, y, g) return CR._iconRow (c, px, pw, p, y, g) end

return CR
