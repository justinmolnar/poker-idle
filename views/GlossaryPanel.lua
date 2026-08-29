-- views/GlossaryPanel.lua
--
-- The GLOSSARY behind THE HOUSE poster (click the "?"): a compact list of
-- terms rising from the House, one row per data/glossary.lua entry.
--
-- EXPOSURE IS THE STORY: an entry is readable once its beat has played
-- (state.story_seen). Everything else renders as a "???" row — the same
-- visible-but-blank promise the locked game-type tabs make. There is no
-- other unlock path; the beats teach, this remembers.
--
-- Hovering an exposed term opens its card beside the list: the
-- written-down version of the lesson, word-wrapped with live {icon}
-- glyphs. "???" rows are inert.
--
-- Host contract (GrindState, unchanged from the old hint-log panel):
-- :update(dt) drives the drop-down reveal (self.done true once retracted,
-- drop the reference then); :beginClose() starts the retract;
-- :mousepressed returns true when the click was inside the dropdown
-- (outside clicks = host closes); :wheelmoved scrolls when the list
-- outgrows the screen. MVC: reads state, never mutates it.

local Theme    = require("views.Theme")
local IconText = require("views.IconText")
local Anchors  = require("services.AnchorRegistry")
local Glossary = require("data.glossary")
local HintView = require("views.HintView")

local GlossaryPanel = {}
GlossaryPanel.__index = GlossaryPanel

local MIN_W_BASE  = 150
local MAX_W_BASE  = 280
local CARD_W_BASE = 260   -- hover card text-wrap width, pre-scale
local SLIDE_TIME  = 0.12  -- seconds for the drop-down reveal
local HIDDEN_ROW  = "???"

function GlossaryPanel:new(game)
    -- Snapshot exposure at open; a beat playing behind the panel is a
    -- frame-perfect edge case not worth live reads.
    local seen = game.state.story_seen or {}
    local entries = {}
    for _, e in ipairs(Glossary) do
        entries[#entries + 1] = { def = e, exposed = seen[e.beat] == true }
    end

    return setmetatable({
        game    = game,
        entries = entries,
        slide   = 0,      -- 0 = retracted, 1 = fully dropped
        closing = false,
        done    = false,  -- fully retracted — host drops the panel
        scroll  = 0,
        _rect   = nil,    -- dropdown rect, for the host's hit-test
    }, GlossaryPanel)
end

function GlossaryPanel:beginClose()
    self.closing = true
end

function GlossaryPanel:update(dt)
    local step = (dt or 0) / SLIDE_TIME
    if self.closing then
        self.slide = self.slide - step
        if self.slide <= 0 then self.slide, self.done = 0, true end
    elseif self.slide < 1 then
        self.slide = math.min(1, self.slide + step)
    end
end

-- The hover card: term as heading, then the entry text (string or list of
-- paragraph strings) wrapped beneath. Sits LEFT of the list so the rows
-- stay readable under the cursor; clamped on screen.
local function drawCard(game, entry, px, row_y, s)
    local fonts = game.fonts
    local sm    = fonts.sm
    local fl    = math.floor
    local pad   = fl(10 * s)
    local lh    = sm:getHeight()
    local gap   = fl(6 * s)
    local max_w = fl(CARD_W_BASE * s)

    local paras = entry.text
    if type(paras) ~= "table" then paras = { paras } end
    local blocks, text_w = {}, IconText.measure(entry.term, sm)
    local text_h = lh + gap   -- the heading line
    for _, para in ipairs(paras) do
        local lines, w = HintView.wrapLines(para, sm, max_w)
        blocks[#blocks + 1] = lines
        text_w = math.max(text_w, w)
        text_h = text_h + #lines * lh + gap
    end
    text_h = text_h - gap

    local cw = text_w + pad * 2
    local ch = text_h + pad * 2
    local H  = love.graphics.getHeight()
    local cx = px - cw - fl(8 * s)
    if cx < fl(8 * s) then cx = fl(8 * s) end
    local cy = math.max(fl(8 * s), math.min(row_y, H - ch - fl(8 * s)))

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", cx, cy, cw, ch)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", cx, cy, cw, ch)

    love.graphics.setFont(sm)
    local ty = cy + pad
    IconText.draw(game, entry.term, cx + pad, ty, sm, Theme.fg.heading)
    ty = ty + lh + gap
    for _, lines in ipairs(blocks) do
        for _, l in ipairs(lines) do
            IconText.draw(game, l, cx + pad, ty, sm, Theme.fg.primary)
            ty = ty + lh
        end
        ty = ty + gap
    end
end

function GlossaryPanel:draw()
    if self.slide <= 0 then return end
    local game  = self.game
    local sm    = game.fonts.sm
    local s     = game.ui_scale or 1
    local fl    = math.floor
    local W, H  = love.graphics.getDimensions()

    -- ── Geometry: rises from THE HOUSE poster — right-aligned to it,
    -- bottom edge just above its roof, growing upward. Fallback:
    -- top-right corner. Width fits the longest exposed term.
    local pad    = fl(10 * s)
    local lh     = sm:getHeight()
    local row_h  = lh + fl(10 * s)
    local title_w = sm:getWidth("GLOSSARY")
    for _, row in ipairs(self.entries) do
        if row.exposed then
            title_w = math.max(title_w, IconText.measure(row.def.term, sm))
        end
    end
    local pw = math.max(fl(MIN_W_BASE * s),
               math.min(fl(MAX_W_BASE * s), title_w + pad * 2))

    local header_h = lh + pad
    local list_h   = #self.entries * row_h
    local house    = Anchors.get("house")
    local px, py, view_h
    if house and house[3] then
        local bottom  = house[2] - fl(6 * s)
        local top_min = fl(56 * s)   -- keep clear of the top bar
        view_h = math.max(row_h,
                 math.min(list_h, bottom - top_min - header_h))
        px = math.min(house[1] + house[3], W - fl(8 * s)) - pw
        py = bottom - header_h - view_h
    else
        px, py = W - pw - fl(8 * s), fl(56 * s)
        view_h = math.min(list_h, H - py - header_h - fl(12 * s))
    end
    local full_h = header_h + view_h
    local ph     = fl(full_h * self.slide)
    -- Reveal from the BOTTOM (house side) while sliding.
    local reveal_y = py + (full_h - ph)
    self._rect = { x = px, y = py, w = pw, h = full_h }

    local max_scroll = math.max(0, list_h - view_h)
    if self.scroll > max_scroll then self.scroll = max_scroll end
    if self.scroll < 0 then self.scroll = 0 end

    -- ── Layout rows + hover pick (only when fully dropped; "???" rows
    -- are inert).
    local mx, my = love.mouse.getPosition()
    local list_y = py + header_h
    local hovered
    local rows = {}
    for i, row in ipairs(self.entries) do
        local ry = list_y + (i - 1) * row_h - self.scroll
        rows[#rows + 1] = { row = row, y = ry }
        if self.slide >= 1 and row.exposed
           and mx >= px and mx < px + pw
           and my >= ry and my < ry + row_h
           and ry >= list_y and ry + row_h <= list_y + view_h then
            hovered = rows[#rows]
        end
    end

    love.graphics.setScissor(px, reveal_y, pw, ph)

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", px, py, pw, full_h)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", px, py, pw, full_h)

    love.graphics.setFont(sm)
    Theme.setColor(Theme.fg.faint)
    love.graphics.print("GLOSSARY", px + pad, py + fl(pad * 0.5))

    love.graphics.setScissor(px, list_y, pw, view_h)
    for _, r in ipairs(rows) do
        if r.y + row_h >= list_y and r.y <= list_y + view_h then
            if r == hovered then
                Theme.setColor(Theme.bg.widget_hover)
                love.graphics.rectangle("fill", px, r.y, pw, row_h)
            end
            if r.row.exposed then
                local color = (r == hovered) and Theme.fg.heading
                                             or Theme.fg.primary
                IconText.draw(game, r.row.def.term,
                    px + pad, r.y + fl(5 * s), sm, color)
            else
                Theme.setColor(Theme.fg.faint)
                love.graphics.print(HIDDEN_ROW, px + pad, r.y + fl(5 * s))
            end
        end
    end
    love.graphics.setScissor(px, reveal_y, pw, ph)

    if max_scroll > 0 then
        local thumb_h = math.max(16, view_h * (view_h / list_h))
        local thumb_y = list_y + (view_h - thumb_h)
                        * (self.scroll / max_scroll)
        Theme.setColor(Theme.fg.muted, 0.5)
        love.graphics.rectangle("fill", px + pw - 4, thumb_y, 3, thumb_h, 2)
    end

    love.graphics.setScissor()

    if hovered then
        drawCard(game, hovered.row.def, px, hovered.y, s)
    end
end

function GlossaryPanel:containsPoint(x, y)
    local r = self._rect
    return r ~= nil and x >= r.x and x < r.x + r.w
       and y >= r.y and y < r.y + r.h
end

-- True when the click landed inside the dropdown (consumed — rows are
-- hover-only). False = outside; the host closes.
function GlossaryPanel:mousepressed(x, y)
    return self:containsPoint(x, y)
end

function GlossaryPanel:wheelmoved(_, dy)
    self.scroll = self.scroll - dy * 30
end

return GlossaryPanel
