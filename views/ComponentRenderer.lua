-- views/ComponentRenderer.lua
-- Draws a flat list of component descriptors stacked vertically.
-- Has no knowledge of what the components represent.
--
-- The chrome is built from these too (GrindView's rail): `row` lays
-- children out left to right, `column` stacks a nested list, `stat` is a
-- label over a value, and `button` is the one button (the add-table rows,
-- the upgrade cards, the game-type keys, SHOVE, the nav). One component
-- per kind of thing; nothing draws chrome by hand.
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
-- comp.face_h names it outright (a face drawn by face_fn has no lines).
local function contentH(comp, content_w, game)
    if comp.face_h then return comp.face_h end
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
    return Button.allocatedH(contentH(comp, content_w, game), comp.depth or BTN_DEPTH)
end
-- A button's natural width, for a row that sizes it by content: the
-- widest line (text plus its right badge) plus the indents.
local function buttonW(comp, game)
    if comp.w then return comp.w end
    local best = 0
    for _, line in ipairs(comp.lines or {}) do
        local font = styleFont(line.style or "body", game)
        local w = (line.text or ""):find("{", 1, true) and IconText.measure(line.text, font)
                  or font:getWidth(line.text or "")
        if line.right then w = w + game.fonts.sm:getWidth(line.right) + 16 end
        w = w + lineIndent(line.style or "body") * 2 + 8
        if w > best then best = w end
    end
    return best
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

-- Where a button's overlay sits (comp.overlay: a second button descriptor
-- straddling the parent's top edge, the quick-reset rescue over SHOVE).
-- One source for draw and hit.
local function overlayRect(comp, panel_x, panel_w, p, y, game)
    local o = comp.overlay
    if not o then return nil end
    local ow = o.w or buttonW(o, game)
    local oh = buttonH(o, panel_w, game)
    local ox = panel_x + p + math.floor(((panel_w - p * 2) - ow) * 0.5)
    return ox, y - math.floor(oh * 0.5), ow, oh
end
local _hitButton
_hitButton = function(comp, panel_x, panel_w, p, cursor_y, h, cx, cy)
    if comp.overlay then
        local ox, oy, ow, oh = overlayRect(comp, panel_x, panel_w, p, cursor_y, comp.__game)
        if ox and cx >= ox and cx < ox + ow and cy >= oy and cy < oy + oh then
            return _hitButton(comp.overlay, ox, ow, 0, oy, oh, cx, cy)
        end
    end
    -- Trailing actions are hit-tested FIRST and independently of the button's
    -- own disabled state: "cash out every table of this type" is exactly the
    -- thing you want when the parent +ADD is greyed out because you're broke.
    -- Each returns its own descriptor, so the dispatcher routes on its id.
    if comp.actions and cy >= cursor_y and cy < cursor_y + h then
        local depth = comp.depth or BTN_DEPTH
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

-- ── stat: a label over a value (the readout) ──────────────────────────
-- { label (small, on top), value, value_style ("sm"|"md"|"lg"), icon
--   ("chip" | "achip" | an icon id: a glyph on the value line, before the
--   number), value_color (a colour) or value_color_token, value_scale (a
--   pop), value_glow_color (the underflow's glyphs), value_anchor,
--   bar = { frac, color, w } (a short fill on the value line, after the
--   value), suffix = { text, color_token, anchor } (small, after the value
--   and the bar, on the value's baseline), sub = { text, color_token } (a
--   small line under), anchor, tooltip, dim, h (taller than content),
--   valign ("top" | "bottom": where the content sits inside a taller h) }
-- The pixel fonts carry leading inside getHeight(); the label is pulled
-- down onto its value by this much so the two read as one readout.
local function leadTrim(font) return math.floor(font:getHeight() * 0.3) end
CR.leadTrim = leadTrim
local function statHasHead(comp)
    return comp.label ~= nil and comp.label ~= ""
end
local function statContentH(comp, game)
    local fonts = game.fonts
    local vf = fonts[comp.value_style or "md"] or fonts.md
    local h = vf:getHeight() + 2
    if statHasHead(comp) then h = h + fonts.sm:getHeight() - leadTrim(fonts.sm) end
    if comp.sub then h = h + fonts.sm:getHeight() end
    return h
end
local function statH(comp, _w, game)
    if comp.h then return comp.h end
    return statContentH(comp, game)
end
local function statW(comp, game)
    if comp.w then return comp.w end
    local fonts = game.fonts
    local vf = fonts[comp.value_style or "md"] or fonts.md
    local w = vf:getWidth(comp.value or "")
    if comp.icon then w = w + math.floor(vf:getHeight() * 0.62) + 4 end
    if comp.bar then w = w + 6 + (comp.bar.w or 48) end
    if comp.suffix and comp.suffix.text then w = w + 6 + fonts.sm:getWidth(comp.suffix.text) end
    if comp.label and comp.label ~= "" then
        local lw = fonts.sm:getWidth(comp.label)
        if lw > w then w = lw end
    end
    if comp.sub and comp.sub.text then
        local sw = fonts.sm:getWidth(comp.sub.text)
        if sw > w then w = sw end
    end
    return w + 4
end
local function tokenColor(tok, fallback)
    if not tok then return fallback end
    return Theme.semColor(tok)
        or (Theme.status and Theme.status[tok])
        or (Theme.fg and Theme.fg[tok])
        or fallback
end
function CR._stat(comp, px, pw, p, y, game)
    local fonts = game.fonts
    local sm    = fonts.sm
    local vf    = fonts[comp.value_style or "md"] or fonts.md
    local h     = statH(comp, pw, game)
    local x, w  = px + p, pw - p * 2
    local dim   = comp.dim
    local cy    = y + 1
    if comp.valign == "bottom" then cy = y + h - statContentH(comp, game) + 1 end
    -- The label, small, on its value.
    if statHasHead(comp) then
        love.graphics.setFont(sm)
        Theme.setColor(dim and Theme.fg.faint or Theme.fg.muted)
        love.graphics.print(comp.label, x, cy)
        cy = cy + sm:getHeight() - leadTrim(sm)
    end
    -- The value line: a glyph, the number (popping about its centre when
    -- it changes), a small suffix on the same baseline.
    local value = comp.value or ""
    local color = dim and Theme.fg.disabled
               or comp.value_color
               or tokenColor(comp.value_color_token, Theme.fg.primary)
    love.graphics.setFont(vf)
    local vw, vh = vf:getWidth(value), vf:getHeight()
    local vx = x
    if comp.icon then
        -- The glyph at the number's cap height, on its line.
        local size = math.floor(vh * 0.62)
        local iy   = cy + math.floor((vh - size) * 0.5)
        local drew = false
        if comp.icon == "chip" then
            Icons.drawChip(game, x, iy, size, dim and 0.45 or 1); drew = true
        elseif comp.icon == "achip" then
            Icons.drawAntiChip(game, x, iy, size, dim and 0.45 or 1); drew = true
        else
            drew = Icons.draw(game, comp.icon, x, iy, size, size)
        end
        if drew then vx = x + size + 4 end
    end
    local scale = comp.value_scale or 1
    if scale ~= 1 then
        love.graphics.push()
        love.graphics.translate(vx + vw / 2, cy + vh / 2)
        love.graphics.scale(scale, scale)
        love.graphics.translate(-(vx + vw / 2), -(cy + vh / 2))
    end
    if comp.value_glow_color then
        Theme.setColor(comp.value_glow_color, 0.22)
        for _, o in ipairs{ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
            love.graphics.print(value, vx + o[1], cy + o[2])
        end
    end
    Theme.setColor(color)
    love.graphics.print(value, vx, cy)
    if scale ~= 1 then love.graphics.pop() end
    if comp.value_anchor then
        local sx, sy = love.graphics.transformPoint(x, cy)
        Anchors.set(comp.value_anchor, sx, sy, (vx - x) + vw, vh)
    end
    -- Everything after the number sits on the number's BASELINE (the
    -- fonts' line boxes differ; their baselines are what the eye aligns):
    -- the suffix's small text, and the bar centred on its x-height.
    local after_x  = vx + vw
    local baseline = cy + vf:getBaseline()
    local line_y   = baseline - sm:getBaseline()
    if comp.bar then
        local bw, bh = comp.bar.w or 48, math.max(3, math.floor(sm:getHeight() * 0.3))
        local by = baseline - math.floor(sm:getAscent() * 0.45) - math.floor(bh * 0.5)
        local bx = after_x + ((vw > 0) and 6 or 0)   -- no gap when the bar is the value
        Theme.setColor(Theme.bg.sunken)
        love.graphics.rectangle("fill", bx, by, bw, bh, 1)
        Theme.setColor(dim and Theme.fg.disabled or comp.bar.color or Theme.fg.heading)
        love.graphics.rectangle("fill", bx, by, math.floor(bw * math.max(0, math.min(1, comp.bar.frac or 0))), bh, 1)
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", bx, by, bw, bh, 1)
        after_x = bx + bw
    end
    if comp.suffix and comp.suffix.text then
        love.graphics.setFont(sm)
        Theme.setColor(dim and Theme.fg.faint or tokenColor(comp.suffix.color_token, Theme.fg.muted))
        local sfx_x, sfx_y = after_x + 6, line_y
        love.graphics.print(comp.suffix.text, sfx_x, sfx_y)
        if comp.suffix.anchor then
            local sx, sy = love.graphics.transformPoint(sfx_x, sfx_y)
            Anchors.set(comp.suffix.anchor, sx, sy, sm:getWidth(comp.suffix.text), sm:getHeight())
        end
    end
    cy = cy + vh
    -- The sub-line.
    if comp.sub then
        love.graphics.setFont(sm)
        Theme.setColor(dim and Theme.fg.faint or tokenColor(comp.sub.color_token, Theme.fg.muted))
        love.graphics.print(comp.sub.text or "", x, cy)
        cy = cy + sm:getHeight()
    end
    if comp.anchor then
        local sx, sy = love.graphics.transformPoint(x, y)
        Anchors.set(comp.anchor, sx, sy, statW(comp, game), h)
    end
    return h
end
-- A stat is not clickable; hovering it shows its tooltip and nothing else.
local function _hitStat(comp, panel_x, panel_w, p, cursor_y, h, cx, cy)
    if comp.tooltip and cy >= cursor_y and cy < cursor_y + h
       and cx >= panel_x + p and cx < panel_x + p + statW(comp, comp.__game) then
        local mx, my = love.mouse.getPosition()
        require("services.Tooltip").set(comp.tooltip, mx, my)
    end
    return nil
end

-- ── row / column: the layout ──────────────────────────────────────────
-- row: children left to right. A child has `w` (px), `flex` (a share of
-- what is left) or neither (its natural width). Children centre
-- vertically in the row's height (comp.h, else the tallest child).
-- column: children stacked, top down. Both walk the registry for their
-- children's draw / hit / measure, so anything can sit inside either.
local function childW(child, game)
    local def = CR.types[child.type]
    if def and def.measureW then return def.measureW(child, game) end
    return child.w or 0
end
local function rowLayout(comp, pw, p, game)
    local gap  = comp.gap or 8
    local kids = comp.children or {}
    local inner_w = pw - p * 2
    local fixed, flex_total = 0, 0
    for _, c in ipairs(kids) do
        if c.flex then flex_total = flex_total + c.flex else fixed = fixed + childW(c, game) end
    end
    local free = math.max(0, inner_w - fixed - gap * math.max(0, #kids - 1))
    local out, x = {}, p
    for _, c in ipairs(kids) do
        local w = c.flex and math.floor(free * c.flex / math.max(flex_total, 1)) or childW(c, game)
        out[#out + 1] = { comp = c, x = x, w = w }
        x = x + w + gap
    end
    return out
end
local function rowH(comp, pw, game)
    if comp.h then return comp.h end
    local best = 0
    for _, c in ipairs(comp.children or {}) do
        local def = CR.types[c.type]
        local h = def and def.measureH(c, c.w or pw, game) or (c.h or 0)
        if h > best then best = h end
    end
    return best
end
local function _drawRow(comp, px, pw, p, y, game)
    local h = rowH(comp, pw, game)
    for _, slot in ipairs(rowLayout(comp, pw, p, game)) do
        local c   = slot.comp
        local def = CR.types[c.type]
        if def and def.draw then
            local ch = def.measureH(c, slot.w, game)
            local cy = (comp.align == "top") and y or (y + math.floor((h - ch) * 0.5))
            c.__game = game
            def.draw(c, px + slot.x, slot.w, 0, cy, game)
        end
    end
    return h
end
local function _hitRow(comp, panel_x, panel_w, p, cursor_y, h, cx, cy)
    for _, slot in ipairs(rowLayout(comp, panel_w, p, comp.__game)) do
        local c   = slot.comp
        local def = CR.types[c.type]
        if def and def.hit then
            local ch = def.measureH(c, slot.w, comp.__game)
            local y0 = (comp.align == "top") and cursor_y or (cursor_y + math.floor((h - ch) * 0.5))
            c.__game = comp.__game
            local res = def.hit(c, panel_x + slot.x, slot.w, 0, y0, ch, cx, cy)
            if res then return res end
        end
    end
    return nil
end
local function rowW(comp, game)
    if comp.w then return comp.w end
    local w, gap = 0, comp.gap or 8
    for i, c in ipairs(comp.children or {}) do
        w = w + childW(c, game) + (i > 1 and gap or 0)
    end
    return w
end
local function columnH(comp, pw, game)
    if comp.h then return comp.h end
    local h, gap = 0, comp.gap or 0
    for i, c in ipairs(comp.children or {}) do
        local def = CR.types[c.type]
        h = h + (def and def.measureH(c, pw, game) or (c.h or 0)) + (i > 1 and gap or 0)
    end
    return h
end
local function columnW(comp, game)
    if comp.w then return comp.w end
    local w = 0
    for _, c in ipairs(comp.children or {}) do
        local cw = childW(c, game)
        if cw > w then w = cw end
    end
    return w
end
local function _drawColumn(comp, px, pw, p, y, game)
    local cy, gap = y, comp.gap or 0
    for _, c in ipairs(comp.children or {}) do
        local def = CR.types[c.type]
        c.__game = game
        local h = def and def.draw and def.draw(c, px, pw, p, cy, game)
                  or (def and def.measureH(c, pw, game)) or (c.h or 0)
        cy = cy + h + gap
    end
    return columnH(comp, pw, game)
end
local function _hitColumn(comp, panel_x, panel_w, p, cursor_y, _h, cx, cy)
    local y, gap = cursor_y, comp.gap or 0
    for _, c in ipairs(comp.children or {}) do
        local def = CR.types[c.type]
        local h = def and def.measureH(c, panel_w, comp.__game) or (c.h or 0)
        if def and def.hit then
            c.__game = comp.__game
            local res = def.hit(c, panel_x, panel_w, p, y, h, cx, cy)
            if res then return res end
        end
        y = y + h + gap
    end
    return nil
end

CR.types = {
    label    = { draw = nil,           hit = nil,        measureH = _staticH(24) },
    button   = { draw = nil,           hit = _hitButton, measureH = function(comp, w, game) return buttonH(comp, w, game) end,
                 measureW = buttonW },
    stat     = { draw = nil,           hit = _hitStat,   measureH = statH, measureW = statW },
    row      = { draw = _drawRow,      hit = _hitRow,    measureH = rowH, measureW = rowW },
    column   = { draw = _drawColumn,   hit = _hitColumn, measureH = columnH, measureW = columnW },
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
    comp.__game = game
    local content_w = pw - p * 2
    local total_h   = buttonH(comp, content_w, game)
    local disabled  = comp.disabled
    local depth     = comp.depth or BTN_DEPTH
    -- A pressed key (the selected game type) neither lifts nor washes.
    local hovered   = (not disabled) and (not comp.pressed) and comp.id and HoverSvc.is("button", comp.id)
    -- press_alpha may be driven by the builder (the keys' travel animation).
    local press     = comp.press_alpha or (comp.id and ClickFlash.alpha("button", comp.id)) or 0
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
        fill_color    = fill,
        border_color  = border,
        hovered       = hovered,
        press_alpha   = press,
        disabled      = disabled,
        disabled_fill = comp.disabled_face_color,
        depth         = depth,
        line_width    = comp.border_line_width,
    }, function(fx, fy, fw, fh)
        -- A drawn face (the book's cover, the room, the gear, the deck's
        -- art) instead of lines; dimmed under a wash while disabled.
        if comp.face_fn then
            comp.face_fn(fx, fy, fw, fh, game, disabled)
            if disabled then
                Theme.setColor(Theme.bg.sunken, 0.6)
                love.graphics.rectangle("fill", fx, fy, fw, fh, Theme.space.radius)
            end
        end
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
                color = Theme.semColor(line.color_token)
                     or (Theme.status and Theme.status[line.color_token])
                     or (Theme.fg and Theme.fg[line.color_token])
                     or Theme.fg.primary
            elseif style == "small" or style == "muted" then
                color = Theme.fg.muted
            elseif style == "heading" then
                color = Theme.fg.heading
            elseif style == "warning" then
                color = Theme.fg.heading
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

            -- A centred word with a right badge is one centred group: the
            -- word, a gap, the badge (SHOVE with its rate), not a word in
            -- the middle and a number at the edge.
            local group = (line.align == "center") and line.right and not line.right_icon
            local left_printf_w = math.max(1, printf_w - right_w)
            local group_x, group_tw
            if group then
                group_tw = font:getWidth(line.text or "")
                local gap  = 10
                local total = group_tw + gap + right_font:getWidth(line.right)
                group_x = fx + indent + math.floor((printf_w - total) * 0.5)
                left_printf_w = printf_w
            end
            if (line.text or ""):find("{", 1, true) then
                IconText.draw(game, line.text, fx + indent, cursor, font, color)
            elseif group then
                love.graphics.print(line.text or "", group_x, cursor)
            else
                love.graphics.printf(line.text or "",
                    fx + indent, cursor, left_printf_w, line.align or "left")
            end
            -- line.text_anchor: the left text's rect, for story marks (a
            -- readout on a row).
            if line.text_anchor and line.text and line.text ~= "" then
                local tw = (line.text):find("{", 1, true) and IconText.measure(line.text, font)
                           or font:getWidth(line.text)
                tw = math.min(tw, left_printf_w)
                local ax = fx + indent
                if group then ax = group_x
                elseif line.align == "center" then ax = ax + math.floor((left_printf_w - tw) * 0.5)
                elseif line.align == "right" then ax = ax + (left_printf_w - tw) end
                local sx, sy = love.graphics.transformPoint(ax, cursor)
                Anchors.set(line.text_anchor, sx, sy, tw, font:getHeight())
            end
            if line.right then
                local right_color = color
                if line.right_color_token then
                    right_color = Theme.semColor(line.right_color_token)
                               or (Theme.status and Theme.status[line.right_color_token])
                               or (Theme.fg and Theme.fg[line.right_color_token])
                               or color
                end
                love.graphics.setFont(right_font)
                Theme.setColor(right_color)
                local right_y = cursor + font:getBaseline() - right_font:getBaseline()
                local icon_d = line.right_icon and right_font:getHeight() or 0
                local text_w = (icon_d > 0) and math.max(1, printf_w - icon_d - 4) or printf_w
                if group then
                    -- The badge's right edge closes the centred group.
                    text_w = (group_x + group_tw + 10 + right_font:getWidth(line.right)) - (fx + indent)
                end
                love.graphics.printf(line.right,
                    fx + indent, right_y, text_w, "right")
                if line.right_icon == "achip" then
                    Icons.drawAntiChip(game, fx + indent + printf_w - icon_d, right_y, icon_d,
                        line.right_icon_alpha, line.right_icon_shade)
                elseif line.right_icon then
                    Icons.drawChip(game, fx + indent + printf_w - icon_d, right_y, icon_d,
                        line.right_icon_alpha, line.right_icon_shade)
                end
                -- The badge's rect (text + icon): under the component's
                -- badge_anchor (a shared name, e.g. chip_badge:banked) and
                -- the line's own right_anchor (this row's badge by name).
                if comp.badge_anchor or line.right_anchor then
                    local bx0 = fx + indent + text_w
                                - right_font:getWidth(line.right)
                    local sx, sy = love.graphics.transformPoint(bx0, right_y)
                    local bw = (fx + indent + printf_w) - bx0
                    if comp.badge_anchor and icon_d > 0 then
                        Anchors.set(comp.badge_anchor, sx, sy, bw, right_font:getHeight())
                    end
                    if line.right_anchor then
                        Anchors.set(line.right_anchor, sx, sy, bw, right_font:getHeight())
                    end
                end
                -- Second badge: the same shape, immediately left of the
                -- first (the add-table button shows "+N {achip}" beside
                -- "+N {chip}" in Act 3, when a stake pays both).
                if line.right2 then
                    local color2 = color
                    if line.right2_color_token then
                        color2 = Theme.semColor(line.right2_color_token)
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
        -- A second, shared name for the same rect (e.g. add_table:banked).
        if comp.anchor_also then Anchors.set(comp.anchor_also, sx, sy, content_w, total_h) end
    end
    -- The overlay: a second button straddling this one's top edge.
    if comp.overlay then
        local ox, oy, ow = overlayRect(comp, px, pw, p, y, game)
        CR._button(comp.overlay, ox, ow, 0, oy, game)
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
        comp.__game = game   -- rows and columns hit-test their children with it
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
CR.types.stat.draw     = function(c, px, pw, p, y, g) return CR._stat    (c, px, pw, p, y, g) end
CR.types.icon_row.draw = function(c, px, pw, p, y, g) return CR._iconRow (c, px, pw, p, y, g) end

return CR
