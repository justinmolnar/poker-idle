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

local Theme     = require("views.Theme")
local IconText  = require("views.IconText")
local HintMarks = require("views.HintMarks")
local HintView  = require("views.HintView")

local StoryView = {}
StoryView.__index = StoryView

local SPEAKER     = "THE HOUSE"
local MAX_W_BASE  = 640     -- panel width cap, before ui_scale
local PAD_BASE    = 14

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
    local lines = HintView.wrapLines(line.text, font, pw - pad * 2)
    local lh    = font:getHeight()
    local label_h = fonts.sm:getHeight()
    local ph    = pad + label_h + fl(4 * s) + #lines * lh + pad

    -- Centred on the band; grows away from the nearer screen edge.
    local bx, by, bw, bh = band[1], band[2], band[3], band[4]
    local px = fl(bx + (bw - pw) / 2)
    local py
    if by + bh / 2 > H / 2 then py = by + bh - ph else py = by end
    py = math.max(fl(4 * s), math.min(py, H - ph - fl(4 * s)))

    Theme.setColor(Theme.bg.window, 0.96)
    love.graphics.rectangle("fill", px, py, pw, ph, fl(4 * s))
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(Theme.space.line_strong or 2)
    love.graphics.rectangle("line", px, py, pw, ph, fl(4 * s))
    love.graphics.setLineWidth(1)

    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.faint)
    love.graphics.print(SPEAKER, px + pad, py + pad)

    local ty = py + pad + label_h + fl(4 * s)
    for i, l in ipairs(lines) do
        IconText.draw(game, l, px + pad, ty + (i - 1) * lh, font, Theme.fg.heading)
    end

    if opts.holding then
        local cue = "click"
        local cf  = fonts.sm
        local cw  = cf:getWidth(cue)
        local pulse = 0.4 + 0.25 * math.sin(love.timer.getTime() * 3)
        love.graphics.setFont(cf)
        Theme.setColor(Theme.fg.faint, pulse)
        love.graphics.print(cue, px + pw - pad - cw, py + pad)
    end

    self.band_rect = { x = px, y = py, w = pw, h = ph }
end

-- True if (x, y) is on the panel drawn last frame.
function StoryView:hitBand(x, y)
    local r = self.band_rect
    if not r then return false end
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

return StoryView
