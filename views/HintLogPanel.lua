-- views/HintLogPanel.lua
--
-- The "help desk" behind THE HOUSE poster in TUTORIAL builds (click the
-- poster): a COMPACT list of short hint titles rising from the House —
-- deliberately tiny so the live grind stays visible. Hovering a title
-- REPLAYS that hint in-game: the real bubble speaking from the House,
-- highlight rings, dim — exactly as it originally appeared (minus the
-- "click to dismiss" footer). Titles whose targets aren't currently on
-- screen render faint and replay nothing.
--
-- Lists every delivered hint (seen or still pending in the [i] queue) in
-- teaching order; never lists undelivered hints — the log doesn't teach
-- ahead.
--
-- Host contract (GrindState): :update(dt) drives the drop-down reveal
-- (self.done true once retracted — drop the reference then);
-- :beginClose() starts the retract; :mousepressed returns true when the
-- click was inside the dropdown (outside clicks = host closes);
-- :wheelmoved scrolls when the list outgrows the screen. MVC: reads
-- state, never mutates it.

local Theme    = require("views.Theme")
local IconText = require("views.IconText")
local Anchors  = require("services.AnchorRegistry")
local Hints    = require("data.hints")
local HintView = require("views.HintView")
local HintMarks = require("views.HintMarks")

local HintLogPanel = {}
HintLogPanel.__index = HintLogPanel

local MIN_W_BASE  = 150
local MAX_W_BASE  = 280
local SLIDE_TIME  = 0.12   -- seconds for the drop-down reveal
local EMPTY_NOTE  = "Nothing on file yet"

-- `story` (controllers/StoryDirector) supplies the beats the House has
-- told, listed under the hints as THE HOUSE so a missed line can be
-- reread. Optional: without it the section is absent.
function HintLogPanel:new(game, hint_view, story)
    -- Snapshot at open: seen + queued specs in data (teaching) order.
    local state  = game.state
    local seen   = state.hints_seen or {}
    local queued = {}
    for _, id in ipairs(state.hints_queued or {}) do queued[id] = true end
    local entries = {}
    for _, spec in ipairs(Hints) do
        if seen[spec.id] or queued[spec.id] then
            entries[#entries + 1] = spec
        end
    end
    local story_lines = story and story.seenLines and story:seenLines() or {}

    return setmetatable({
        game      = game,
        hint_view = hint_view,   -- shared renderer: dim, rings, bubble
        entries   = entries,
        story_lines = story_lines,
        slide     = 0,      -- 0 = retracted, 1 = fully dropped
        closing   = false,
        done      = false,  -- fully retracted — host drops the panel
        scroll    = 0,
        _rows     = {},     -- built each draw: { spec, y, h, live }
        _rect     = nil,    -- dropdown rect, for the host's hit-test
    }, HintLogPanel)
end

function HintLogPanel:beginClose()
    self.closing = true
end

function HintLogPanel:update(dt)
    local step = (dt or 0) / SLIDE_TIME
    if self.closing then
        self.slide = self.slide - step
        if self.slide <= 0 then self.slide, self.done = 0, true end
    elseif self.slide < 1 then
        self.slide = math.min(1, self.slide + step)
    end
end

function HintLogPanel:draw()
    if self.slide <= 0 then return end
    local game  = self.game
    local fonts = game.fonts
    local sm    = fonts.sm
    local s     = game.ui_scale or 1
    local fl    = math.floor
    local W, H  = love.graphics.getDimensions()

    -- ── Geometry: rises from THE HOUSE poster (the help desk) —
    -- right-aligned to it, bottom edge just above its roof, growing
    -- upward. Fallback: top-right corner. Width fits the longest title.
    local pad    = fl(10 * s)
    local lh     = sm:getHeight()
    local row_h  = lh + fl(10 * s)
    local title_w = 0
    for _, spec in ipairs(self.entries) do
        title_w = math.max(title_w,
            IconText.measure(spec.title or spec.id, sm))
    end
    for _, line in ipairs(self.story_lines) do
        title_w = math.max(title_w, IconText.measure(line.text, sm))
    end
    title_w = math.max(title_w, sm:getWidth("HELP DESK"))
    local pw = math.max(fl(MIN_W_BASE * s),
               math.min(fl(MAX_W_BASE * s), title_w + pad * 2))

    local header_h = lh + pad
    local n_story  = (#self.story_lines > 0) and (#self.story_lines + 1) or 0
    local n_rows   = math.max(1, #self.entries) + n_story   -- 1 = empty-note row
    local list_h   = n_rows * row_h
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

    -- ── Layout rows + hover pick (only when fully dropped).
    local mx, my = love.mouse.getPosition()
    local list_y = py + header_h
    self._rows = {}
    local hovered_spec, hovered_layout
    for i, spec in ipairs(self.entries) do
        local ry   = list_y + (i - 1) * row_h - self.scroll
        local live = #HintView.freshMarksFor(spec) > 0
        self._rows[#self._rows + 1] = { spec = spec, y = ry, live = live }
        if self.slide >= 1 and live
           and mx >= px and mx < px + pw
           and my >= ry and my < ry + row_h
           and ry >= list_y and ry + row_h <= list_y + view_h then
            hovered_spec = spec
        end
    end
    if hovered_spec then
        hovered_layout = self.hint_view:_layoutHint(hovered_spec, false)
    end
    -- THE HOUSE: what he has said so far, after the hints. Hovering a line
    -- whose target is on screen marks it (no bubble: it was never one).
    self._story_rows = {}
    local hovered_line
    local base = math.max(1, #self.entries)
    for i, line in ipairs(self.story_lines) do
        local ry   = list_y + (base + i) * row_h - self.scroll
        local live = line.anchor ~= nil and #HintMarks.fresh(line.anchor) > 0
        self._story_rows[#self._story_rows + 1] = { line = line, y = ry, live = live }
        if self.slide >= 1 and live and not hovered_spec
           and mx >= px and mx < px + pw
           and my >= ry and my < ry + row_h
           and ry >= list_y and ry + row_h <= list_y + view_h then
            hovered_line = line
        end
    end
    local story_header_y = list_y + base * row_h - self.scroll

    -- ── Replay dim first (dropdown + bubble ride in as holes), chrome
    -- next, the hint itself (rings + bubble) on top of everything.
    if hovered_layout then
        local holes = { self._rect, hovered_layout.bubble }
        for _, m in ipairs(hovered_layout.marks) do holes[#holes + 1] = m end
        if hovered_layout.house then
            holes[#holes + 1] = hovered_layout.house
        end
        self.hint_view:_drawDim(holes)
    end

    love.graphics.setScissor(px, reveal_y, pw, ph)

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", px, py, pw, full_h)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", px, py, pw, full_h)

    love.graphics.setFont(sm)
    Theme.setColor(Theme.fg.faint)
    love.graphics.print("HELP DESK", px + pad, py + fl(pad * 0.5))

    if #self.entries == 0 and #self.story_lines == 0 then
        Theme.setColor(Theme.fg.muted)
        love.graphics.print(EMPTY_NOTE, px + pad, list_y + fl(5 * s))
    else
        love.graphics.setScissor(px, list_y, pw, view_h)
        for _, row in ipairs(self._rows) do
            if row.y + row_h >= list_y and row.y <= list_y + view_h then
                local hov = row.spec == hovered_spec
                if hov then
                    Theme.setColor(Theme.bg.widget_hover)
                    love.graphics.rectangle("fill", px, row.y, pw, row_h)
                end
                -- Faint when the hint's targets aren't on screen right
                -- now (nothing to replay).
                local color = (not row.live) and Theme.fg.faint
                            or (hov and Theme.fg.heading or Theme.fg.primary)
                IconText.draw(game, row.spec.title or row.spec.id,
                    px + pad, row.y + fl(5 * s), sm, color)
            end
        end
        if #self.story_lines > 0 then
            if story_header_y + row_h >= list_y and story_header_y <= list_y + view_h then
                Theme.setColor(Theme.fg.faint)
                love.graphics.setFont(sm)
                love.graphics.print("THE HOUSE", px + pad, story_header_y + fl(5 * s))
            end
            local max_tw = pw - pad * 2
            for _, row in ipairs(self._story_rows) do
                if row.y + row_h >= list_y and row.y <= list_y + view_h then
                    local hov = row.line == hovered_line
                    if hov then
                        Theme.setColor(Theme.bg.widget_hover)
                        love.graphics.rectangle("fill", px, row.y, pw, row_h)
                    end
                    -- Trim by CHARACTERS, not bytes: cutting bytes split
                    -- the ellipsis (three bytes) and produced invalid UTF-8.
                    local chars = {}
                    for ch in row.line.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                        chars[#chars + 1] = ch
                    end
                    local text = row.line.text
                    while IconText.measure(text, sm) > max_tw and #chars > 2 do
                        chars[#chars] = nil
                        text = table.concat(chars) .. "\u{2026}"
                    end
                    local color = (not row.live) and Theme.fg.faint
                                or (hov and Theme.fg.heading or Theme.fg.primary)
                    IconText.draw(game, text, px + pad, row.y + fl(5 * s), sm, color)
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
    end

    love.graphics.setScissor()

    if hovered_layout then
        self.hint_view:_drawHint(hovered_layout, false)
    elseif hovered_line then
        HintMarks.draw(game, HintMarks.fresh(hovered_line.anchor))
    end
end

function HintLogPanel:containsPoint(x, y)
    local r = self._rect
    return r ~= nil and x >= r.x and x < r.x + r.w
       and y >= r.y and y < r.y + r.h
end

-- True when the click landed inside the dropdown (consumed — rows are
-- hover-only). False = outside; the host closes.
function HintLogPanel:mousepressed(x, y)
    return self:containsPoint(x, y)
end

function HintLogPanel:wheelmoved(_, dy)
    self.scroll = self.scroll - dy * 30
end

return HintLogPanel
