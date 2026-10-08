-- views/StoryView.lua
--
-- The box the House speaks in. A bordered panel with a speaker label, the
-- medium font, and the block of text wrapped inside it: it reads as
-- dialogue, not as a caption painted on the felt. Each screen says where
-- the box sits by registering the anchor "story:band" (a rect) every draw;
-- the panel is centred on that rect and grows away from the nearer screen
-- edge, so the grind's sits above the bankroll pile and a modal's along
-- its bottom edge.
--
-- No dim of its own: the game keeps running while he talks. The thing he
-- is pointing at gets the same pulsing mark a popup would give it
-- (views/HintMarks). A FORCED line (line.force) does dim — main.lua draws
-- the hint-style dim under this panel and locks clicks to the marks.
-- A faint "click" cue sits in the panel's corner while a block is waiting
-- on the player.
--
-- A screen can instead give a FIXED box (the anchor "story:box", a rect):
-- the grind's, above the House's poster. That box never moves, buzzes or
-- resizes; the text is the small font, wrapped to it, and a block that
-- needs more lines than it holds pages: the box shows what fits, and a
-- click shows the rest (:nextPage) before one advances the story.
--
-- ShoveView draws its own one-line headline through drawLine, which is the
-- plain caption style (no box); the shove's band was designed that way.

local Theme        = require("views.Theme")
local IconText     = require("views.IconText")
local HintMarks    = require("views.HintMarks")
local HintView     = require("views.HintView")
local RadioVoice   = require("services.RadioVoice")
local StoryDynamic = require("models.story_dynamic")

local Motion = require("services.Motion")
local StoryView = {}
StoryView.__index = StoryView

-- No speaker label: the voice is never named, not even here. The poster,
-- the intercom, and the shout-burst tail say who is talking.
local MAX_W_BASE  = 640     -- panel width cap, before ui_scale
local PAD_BASE    = 14
local WORDS_PER_SEC = 9     -- typewriter reveal rate (the speaking cadence)
local CUE_TEXT    = "click anywhere to continue"

function StoryView:new(game)
    return setmetatable({
        game      = game,
        band_rect = nil,   -- the panel drew last frame here, for the click
    }, StoryView)
end

-- One plain line, centred in a rect. Used by views/ShoveView for its
-- headline; the story box does not use it.
function StoryView.drawLine(game, text, rect, opts)
    opts = opts or {}
    local fonts = game.fonts
    local font  = fonts[opts.font or "lg"] or fonts.lg
    local fl    = math.floor
    local tw    = IconText.measure(text, font)
    IconText.draw(game, text,
        fl(rect.x + (rect.w - tw) / 2), fl(rect.y + (rect.h - font:getHeight()) / 2),
        font, Theme.fg.heading)
end

-- The panel for one block of the House's text.
--   line = { text, anchor?, font?, force? }  (the director's payload)
--   opts = { holding = bool (click cue), graced = bool (draw even when the
--            block's target is not on screen: the anchor grace elapsed) }
function StoryView:draw(line, opts)
    opts = opts or {}
    self.band_rect = nil
    if not line then return end
    local fixed = HintMarks.freshAnchor("story:box")
    if fixed and not fixed[3] then fixed = nil end
    local band = fixed or HintMarks.freshAnchor("story:band")
    if not band or not band[3] then return end
    local marks = line.anchor and HintMarks.fresh(line.anchor) or {}
    -- Presence follows the target: a block about a widget that is not on
    -- screen waits for it, unless the director gave up waiting.
    if line.anchor and #marks == 0 and not opts.graced then return end
    if #marks > 0 then HintMarks.draw(self.game, marks) end

    local game  = self.game
    local fonts = game.fonts
    local s     = game.ui_scale or 1
    local fl    = math.floor
    local W, H  = love.graphics.getDimensions()
    local font  = fixed and fonts.sm or (fonts[line.font or "md"] or fonts.md)
    local pad   = fixed and fl(10 * s) or fl(PAD_BASE * s)
    local pw    = fixed and band[3] or math.min(band[3], fl(MAX_W_BASE * s))

    -- Typewriter: the block SPEAKS itself in, word by word. The reveal
    -- window is what everything else keys on — the balloon buzz here,
    -- the speaker rattle, and the chopped radio voice (services/
    -- RadioVoice, which also fires the mic-key cold open the frame a new
    -- block lands). The panel is sized from the FULL text, so nothing
    -- moves while the words arrive. Advancing only while the band
    -- actually draws means a paused beat pauses mid-word too.
    -- {dyn:*} tokens resolve HERE, once per block, the moment it lands:
    -- the House reads the numbers off the player's actual game
    -- (models/story_dynamic), and everything below uses the resolved text.
    local key = tostring(line.beat or "") .. ":" .. tostring(line.index or 0)
        .. (fixed and ":box" or "")
    local rv = self._reveal
    local lh    = font:getHeight()
    local cue_h = fonts.sm:getHeight() + fl(4 * s)
    if not rv or rv.key ~= key then
        local text = StoryDynamic.resolve(game, tostring(line.text))
        rv = { key = key, text = text, page = 1 }
        -- A fixed box pages: the block wrapped to the box, cut into pages
        -- of the lines it holds. A free panel is one page, sized to it.
        local all = HintView.wrapLines(text, font, pw - pad * 2)
        local per = fixed and math.max(1, fl((band[4] - pad * 2 - cue_h) / lh)) or #all
        rv.pages = {}
        for i = 1, #all, math.max(1, per) do
            local pg = {}
            for j = i, math.min(#all, i + per - 1) do pg[#pg + 1] = all[j] end
            rv.pages[#rv.pages + 1] = table.concat(pg, " ")
        end
        if #rv.pages == 0 then rv.pages[1] = "" end
        self._reveal = rv
        self:_startPage(rv)
        RadioVoice.lineStarted()
    end

    local lines = HintView.wrapLines(rv.pages[rv.page], font, pw - pad * 2)
    -- A cue row is always reserved (drawn only on a finished hold), so the
    -- panel never resizes the instant the typewriter completes.
    local ph    = fixed and band[4] or (pad + #lines * lh + cue_h + pad)
    if rv.shown < #rv.words then
        -- Motion: Medium speaks twice as fast; Low and below the whole
        -- block is there at once.
        local lvl = Motion.level("text")
        if lvl <= Motion.LOW then
            rv.acc = #rv.words
        else
            rv.acc = rv.acc + love.timer.getDelta() * WORDS_PER_SEC * ((lvl == Motion.MEDIUM) and 2 or 1)
        end
        rv.shown = math.min(#rv.words, math.floor(rv.acc))
    end
    local typing = rv.shown < #rv.words
    local shown_lines = lines
    if typing then
        shown_lines = (rv.shown == 0) and {}
            or HintView.wrapLines(table.concat(rv.words, " ", 1, rv.shown),
                                  font, pw - pad * 2)
    end

    -- Centred on the band; grows away from the nearer screen edge. A fixed
    -- box is exactly its rect.
    local bx, by, bw, bh = band[1], band[2], band[3], band[4]
    local px = fl(bx + (bw - pw) / 2)
    local py
    if fixed then
        py = by
    else
        if by + bh / 2 > H / 2 then py = by + bh - ph else py = by end
        py = math.max(fl(4 * s), math.min(py, H - ph - fl(4 * s)))
    end

    -- Never sit on what you're pointing at. If the panel covers more than
    -- ~30% of any of this line's marks, slide it up until clear of the
    -- topmost such mark (down past the bottom one when up would leave the
    -- screen). The box saying "BANKED is yours to keep" was covering the
    -- banked readout.
    if #marks > 0 and not fixed then
        local gap = fl(8 * s)
        local top, bottom
        for _, m in ipairs(marks) do
            local mw, mh = m.w or 0, m.h or 0
            local ix = math.max(0, math.min(px + pw, m.x + mw) - math.max(px, m.x))
            local iy = math.max(0, math.min(py + ph, m.y + mh) - math.max(py, m.y))
            if ix * iy > 0.30 * math.max(1, mw * mh) then
                if not top or m.y < top then top = m.y end
                if not bottom or m.y + mh > bottom then bottom = m.y + mh end
            end
        end
        if top then
            local up = top - gap - ph
            if up >= fl(4 * s) then
                py = up
            elseif bottom + gap + ph <= H - fl(4 * s) then
                py = bottom + gap
            end
        end
    end

    -- The balloon. When the intercom on the House's poster is on screen,
    -- the box grows a jagged comic shout-burst tail to it (the box is
    -- what the speaker is blaring) and the WHOLE balloon — panel and
    -- tail, never the text — buzzes while he talks.
    local spk = HintMarks.freshAnchor("house:speaker")
    local jx, jy = 0, 0
    if spk and spk[3] and typing and not fixed then
        local t = love.timer.getTime()
        jx = math.sin(t * 43) * 0.8 * s
        jy = math.cos(t * 57) * 0.6 * s
    end
    love.graphics.push()
    love.graphics.translate(fl(jx), fl(jy))

    Theme.setColor(Theme.bg.window, 0.96)
    love.graphics.rectangle("fill", px, py, pw, ph, fl(4 * s))
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(Theme.space.line_strong or 2)
    love.graphics.rectangle("line", px, py, pw, ph, fl(4 * s))
    love.graphics.setLineWidth(1)

    -- A fixed box (the grind's, right above the poster) points at the
    -- speaker with a plain tail: a short triangle from its bottom edge to
    -- the speaker's top, filled with the box and outlined on its two
    -- sides, so box and tail read as one balloon.
    if fixed and spk and spk[3] then
        local tipx = spk[1] + spk[3] * 0.5
        local tipy = spk[2] - fl(1 * s)
        local half = fl(9 * s)
        local edge = fl(10 * s)
        local cx = math.min(px + pw - half - edge, math.max(px + half + edge, tipx))
        local by = py + ph
        if tipy > by + fl(2 * s) then
            local lw = Theme.space.line_strong or 2
            Theme.setColor(Theme.bg.window, 0.96)
            love.graphics.polygon("fill", cx - half, by - lw, cx + half, by - lw, tipx, tipy)
            Theme.setColor(Theme.border.strong)
            love.graphics.setLineWidth(lw)
            love.graphics.line(cx - half, by - lw * 0.5, tipx, tipy, cx + half, by - lw * 0.5)
            love.graphics.setLineWidth(1)
        end
        spk = nil   -- the free balloon's shout tail is not drawn
    end

    -- The tail leaves whichever edge FACES the speaker (a level speaker
    -- gets a side tail, one above gets a top tail), so the sawtooth
    -- never stretches into a sideways bolt. Fill first (covers the panel
    -- border at the base so bubble and tail merge), then only the two
    -- zigzag edges are stroked. Concave, so it fills via triangulate.
    if spk and spk[3] then
        local tipx = spk[1] + spk[3] * 0.5
        local tipy = spk[2] + spk[4] + fl(2 * s)
        local half = fl(26 * s)
        local m    = fl(8 * s)
        local cx0  = math.min(math.max(tipx, px), px + pw)
        local cy0  = math.min(math.max(tipy, py), py + ph)
        local b1x, b1y, b2x, b2y
        if math.abs(tipx - cx0) > math.abs(tipy - cy0) then
            local ex  = (tipx > cx0) and (px + pw - fl(3 * s)) or (px + fl(3 * s))
            local eyc = math.min(py + ph - half - m, math.max(py + half + m, tipy))
            b1x, b1y, b2x, b2y = ex, eyc - half, ex, eyc + half
        else
            local ey  = (tipy > cy0) and (py + ph - fl(3 * s)) or (py + fl(3 * s))
            local exc = math.min(px + pw - half - m, math.max(px + half + m, tipx))
            b1x, b1y, b2x, b2y = exc - half, ey, exc + half, ey
        end
        local bcx, bcy = (b1x + b2x) / 2, (b1y + b2y) / 2
        local function sidePts(x0, y0)
            local pts = { x0, y0 }
            local dx, dy = tipx - x0, tipy - y0
            local len = math.max(1, math.sqrt(dx * dx + dy * dy))
            local nx, ny = -dy / len, dx / len
            -- Spikes flare OUTWARD, away from the tail's centreline:
            -- hard sawtooth, barely tapered — a shout, not a whisper.
            if nx * (x0 - bcx) + ny * (y0 - bcy) < 0 then nx, ny = -nx, -ny end
            for i = 1, 5 do
                local f = i / 6
                local amp = ((i % 2 == 1) and fl(14 * s) or fl(1 * s))
                            * (1 - f * 0.35)
                pts[#pts + 1] = x0 + dx * f + nx * amp
                pts[#pts + 1] = y0 + dy * f + ny * amp
            end
            pts[#pts + 1] = tipx
            pts[#pts + 1] = tipy
            return pts
        end
        local left  = sidePts(b1x, b1y)
        local right = sidePts(b2x, b2y)
        local poly = {}
        for i = 1, #left do poly[#poly + 1] = left[i] end
        for i = #right - 2, 1, -2 do
            poly[#poly + 1] = right[i - 1]
            poly[#poly + 1] = right[i]
        end
        Theme.setColor(Theme.bg.window, 0.96)
        local ok, tris = pcall(love.math.triangulate, poly)
        if ok and tris then
            for _, tri in ipairs(tris) do love.graphics.polygon("fill", tri) end
        end
        Theme.setColor(Theme.border.strong)
        love.graphics.setLineWidth(Theme.space.line_strong or 2)
        love.graphics.line(left)
        love.graphics.line(right)
        love.graphics.setLineWidth(1)
    end

    love.graphics.pop()   -- the text below stays planted while the box buzzes

    local ty = py + pad
    for i, l in ipairs(shown_lines) do
        IconText.draw(game, l, px + pad, ty + (i - 1) * lh, font, Theme.fg.heading)
    end

    -- The advance affordance: play is blocked while a line is up, and any
    -- click continues, so the cue says exactly that — centred in the
    -- reserved bottom row, pulsing hard enough to be found. A page with
    -- more after it waits on a click too, line held or not.
    if (opts.holding or rv.page < #rv.pages) and not typing then
        local cf  = fonts.sm
        local cw  = cf:getWidth(CUE_TEXT)
        local pulse = Motion.at("text", Motion.HIGH)
            and (0.55 + 0.35 * math.sin(love.timer.getTime() * 3)) or 0.8
        love.graphics.setFont(cf)
        Theme.setColor(Theme.fg.muted, pulse)
        love.graphics.print(CUE_TEXT,
            fl(px + (pw - cw) / 2), py + ph - pad - cf:getHeight())
    end

    self.band_rect = { x = px, y = py, w = pw, h = ph }
end

-- A page starts its typewriter from nothing.
function StoryView:_startPage(rv)
    rv.words = {}
    for wd in (rv.pages[rv.page] or ""):gmatch("%S+") do rv.words[#rv.words + 1] = wd end
    rv.shown, rv.acc = 0, 0
end

-- The block's next page, if it has one: true when it turned a page (the
-- click is spent on that, not on advancing the story).
function StoryView:nextPage()
    local rv = self._reveal
    if not (rv and rv.pages and rv.page < #rv.pages) then return false end
    rv.page = rv.page + 1
    self:_startPage(rv)
    return true
end

-- True while the current block is mid-typewriter — the "speaking"
-- window. main.lua feeds this to RadioVoice; the speaker rattles on it.
function StoryView:isTyping()
    local rv = self._reveal
    return rv ~= nil and rv.shown < #rv.words
end

-- Finish the reveal instantly (a click mid-type skips to the full text
-- instead of advancing past it).
function StoryView:revealAll()
    local rv = self._reveal
    if rv then rv.shown, rv.acc = #rv.words, #rv.words end
end

-- True if (x, y) is on the panel drawn last frame.
function StoryView:hitBand(x, y)
    local r = self.band_rect
    if not r then return false end
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

return StoryView
