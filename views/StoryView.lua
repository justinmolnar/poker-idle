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
    local band = HintMarks.freshAnchor("story:band")
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
    local font  = fonts[line.font or "md"] or fonts.md
    local pad   = fl(PAD_BASE * s)
    local pw    = math.min(band[3], fl(MAX_W_BASE * s))

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
    local rv = self._reveal
    if not rv or rv.key ~= key then
        local text = StoryDynamic.resolve(game, tostring(line.text))
        local words = {}
        for wd in text:gmatch("%S+") do words[#words + 1] = wd end
        rv = { key = key, text = text, words = words, shown = 0, acc = 0 }
        self._reveal = rv
        RadioVoice.lineStarted()
    end

    local lines = HintView.wrapLines(rv.text, font, pw - pad * 2)
    local lh    = font:getHeight()
    -- A cue row is always reserved (drawn only on a finished hold), so the
    -- panel never resizes the instant the typewriter completes.
    local cue_h = fonts.sm:getHeight() + fl(4 * s)
    local ph    = pad + #lines * lh + cue_h + pad
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

    -- Centred on the band; grows away from the nearer screen edge.
    local bx, by, bw, bh = band[1], band[2], band[3], band[4]
    local px = fl(bx + (bw - pw) / 2)
    local py
    if by + bh / 2 > H / 2 then py = by + bh - ph else py = by end
    py = math.max(fl(4 * s), math.min(py, H - ph - fl(4 * s)))

    -- Never sit on what you're pointing at. If the panel covers more than
    -- ~30% of any of this line's marks, slide it up until clear of the
    -- topmost such mark (down past the bottom one when up would leave the
    -- screen). The box saying "BANKED is yours to keep" was covering the
    -- banked readout.
    if #marks > 0 then
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
    if spk and spk[3] and typing then
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
    -- reserved bottom row, pulsing hard enough to be found.
    if opts.holding and not typing then
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
