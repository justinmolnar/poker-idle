-- views/StoryView.lua
--
-- The box the House speaks in: one fixed box, the same place and size on
-- every screen, directly above where the grind hangs the House's poster
-- (GrindView.storyBoxRect, which the grind also registers as the anchor
-- "story:box"). It never moves, buzzes or resizes whatever it says. The
-- text is the small font wrapped to the box; a block that needs more lines
-- than the box holds pages: the box shows what fits, and a click shows the
-- rest (:nextPage) before one advances the story. When the House's
-- intercom is on screen (the grind's poster), a short tail points at it.
--
-- No dim of its own: the game keeps running while he talks. The thing he
-- is pointing at gets the same pulsing mark a popup would give it
-- (views/HintMarks). A FORCED line (line.force) does dim — main.lua draws
-- the hint-style dim under this panel and locks clicks to the marks.
-- A "click" cue sits in the box's bottom row while a block is waiting on
-- the player. A screen still says the House may speak there by
-- registering "story:band" (controllers/StoryDirector pauses without it).
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
-- the intercom and the tail say who is talking.
local PAD_BASE    = 10
local WORDS_PER_SEC = 9     -- typewriter reveal rate (the speaking cadence)
local CUE_TEXT    = "click anywhere to continue"
local FORCE_CUE   = "Your move"   -- a forced line with no cue of its own
local PULSE_SECS  = 0.5           -- the box's border brightens as a block lands

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

-- The House's box, as { x, y, w, h }: the grind's anchor when it drew
-- this frame, else the same rect computed for the window.
function StoryView.boxRect(game)
    local a = HintMarks.freshAnchor("story:box")
    if a and a[3] then return a end
    local r = require("views.GrindView").storyBoxRect(game)
    return { r.x, r.y, r.w, r.h }
end

-- The box for one block of the House's text.
--   line = { text, anchor?, force? }  (the director's payload)
--   opts = { holding = bool (click cue), graced = bool (draw even when the
--            block's target is not on screen: the anchor grace elapsed) }
function StoryView:draw(line, opts)
    opts = opts or {}
    self.band_rect = nil
    if not line then return end
    local marks = line.anchor and HintMarks.fresh(line.anchor) or {}
    -- Presence follows the target: a block about a widget that is not on
    -- screen waits for it, unless the director gave up waiting.
    if line.anchor and #marks == 0 and not opts.graced then return end
    if #marks > 0 then HintMarks.draw(self.game, marks) end

    local game  = self.game
    local fonts = game.fonts
    local s     = game.ui_scale or 1
    local fl    = math.floor
    local box   = StoryView.boxRect(game)
    local px, py, pw, ph = box[1], box[2], box[3], box[4]
    local font  = fonts.sm
    local pad   = fl(PAD_BASE * s)
    local lh    = font:getHeight()
    local cue_h = fonts.sm:getHeight() + fl(4 * s)

    -- Typewriter: the block SPEAKS itself in, word by word, a page at a
    -- time. The reveal window is what everything else keys on: the
    -- speaker rattle and the chopped radio voice (services/RadioVoice,
    -- which also fires the mic-key cold open the frame a new block lands).
    -- Advancing only while the box actually draws means a paused beat
    -- pauses mid-word too. {dyn:*} tokens resolve HERE, once per block,
    -- the moment it lands: the House reads the numbers off the player's
    -- actual game (models/story_dynamic).
    local key = tostring(line.beat or "") .. ":" .. tostring(line.index or 0)
    local rv = self._reveal
    if not rv or rv.key ~= key or rv.w ~= pw then
        local text = StoryDynamic.resolve(game, tostring(line.text))
        rv = { key = key, text = text, page = 1, w = pw, landed = love.timer.getTime() }
        -- Pages: the block is cut at every {page} first, then each part
        -- into pages of the lines the box holds. A page keeps its own
        -- line breaks (a newline in the copy is a line, not a space).
        local per = math.max(1, fl((ph - pad * 2 - cue_h) / lh))
        rv.pages = {}
        for part in (text .. "{page}"):gmatch("(.-){page}") do
            local all = HintView.wrapLines(part, font, pw - pad * 2)
            for i = 1, #all, per do
                local pg = {}
                for j = i, math.min(#all, i + per - 1) do pg[#pg + 1] = all[j] end
                rv.pages[#rv.pages + 1] = table.concat(pg, "\n")
            end
        end
        if #rv.pages == 0 then rv.pages[1] = "" end
        self._reveal = rv
        self:_startPage(rv)
        RadioVoice.lineStarted()
    end

    if rv.shown < #rv.words then
        -- Motion: Medium speaks twice as fast; Low and below the whole
        -- page is there at once.
        local lvl = Motion.level("text")
        if lvl <= Motion.LOW then
            rv.acc = #rv.words
        else
            rv.acc = rv.acc + love.timer.getDelta() * WORDS_PER_SEC * ((lvl == Motion.MEDIUM) and 2 or 1)
        end
        rv.shown = math.min(#rv.words, math.floor(rv.acc))
    end
    local typing = rv.shown < #rv.words
    -- The words shown so far, with the page's line breaks kept (a word is
    -- "\n" where the copy broke the line).
    local shown_lines
    if typing then
        shown_lines = (rv.shown == 0) and {}
            or HintView.wrapLines((table.concat(rv.words, " ", 1, rv.shown):gsub(" ?\n ?", "\n")), font, pw - pad * 2)
    else
        shown_lines = HintView.wrapLines(rv.pages[rv.page], font, pw - pad * 2)
    end

    -- The landing: the border brightens the moment a block lands and
    -- settles back over PULSE_SECS, so the eye finds the box. Still below
    -- Medium motion.
    local pulse = 0
    if Motion.at("text", Motion.MEDIUM) then
        pulse = math.max(0, 1 - (love.timer.getTime() - (rv.landed or 0)) / PULSE_SECS)
    end
    Theme.setColor(Theme.bg.window, 0.96)
    love.graphics.rectangle("fill", px, py, pw, ph, fl(4 * s))
    local bc, hc = Theme.border.strong, Theme.fg.heading
    love.graphics.setColor(bc[1] + (hc[1] - bc[1]) * pulse, bc[2] + (hc[2] - bc[2]) * pulse,
                           bc[3] + (hc[3] - bc[3]) * pulse, 1)
    love.graphics.setLineWidth((Theme.space.line_strong or 2) + fl(2 * s * pulse))
    love.graphics.rectangle("line", px, py, pw, ph, fl(4 * s))
    love.graphics.setLineWidth(1)

    -- The tail: when the House's intercom is on screen below the box, a
    -- short triangle from the box's bottom edge to it, filled with the box
    -- and outlined on its two sides, so box and tail read as one balloon.
    local spk = HintMarks.freshAnchor("house:speaker")
    if spk and spk[3] then
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
    end

    local ty = py + pad
    for i, l in ipairs(shown_lines) do
        IconText.draw(game, l, px + pad, ty + (i - 1) * lh, font, Theme.fg.heading)
    end

    -- The bottom row says what moves things on. A click line: the muted
    -- "click anywhere to continue". A FORCED line, on its last page: the
    -- action it waits for (line.cue, or "Your move") in the chip gold,
    -- pulsing. A page with more after it waits on a click too.
    if not typing then
        local cf  = fonts.sm
        local more = rv.page < #rv.pages
        local text, color
        if line.forced and not more then
            text, color = line.cue or FORCE_CUE, (Theme.currency and Theme.currency.chip) or Theme.sem.chip or Theme.fg.heading
        elseif opts.holding or more then
            text, color = CUE_TEXT, Theme.fg.heading
        end
        if text then
            local cw  = cf:getWidth(text)
            local beat = Motion.at("text", Motion.HIGH)
                and (0.55 + 0.35 * math.sin(love.timer.getTime() * 3)) or 0.8
            love.graphics.setFont(cf)
            Theme.setColor(color, beat)
            love.graphics.print(text, fl(px + (pw - cw) / 2), py + ph - pad - cf:getHeight())
        end
    end

    self.band_rect = { x = px, y = py, w = pw, h = ph }
end

-- A page starts its typewriter from nothing. Its line breaks are words of
-- their own ("\n"), so the reveal keeps them.
function StoryView:_startPage(rv)
    rv.words = {}
    local page = rv.pages[rv.page] or ""
    for para in (page .. "\n"):gmatch("(.-)\n") do
        for wd in para:gmatch("%S+") do rv.words[#rv.words + 1] = wd end
        rv.words[#rv.words + 1] = "\n"
    end
    rv.words[#rv.words] = nil   -- the trailing break
    rv.shown, rv.acc = 0, 0
    rv.landed = love.timer.getTime()
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

-- The page before, for the beat browser's walk back: true when it turned.
function StoryView:prevPage()
    local rv = self._reveal
    if not (rv and rv.pages and rv.page > 1) then return false end
    rv.page = rv.page - 1
    self:_startPage(rv)
    return true
end

-- Where the block is in its pages: page, count (1, 1 for a one-page block).
function StoryView:pageInfo()
    local rv = self._reveal
    if not (rv and rv.pages) then return 1, 1 end
    return rv.page or 1, #rv.pages
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
