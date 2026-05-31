-- views/OnboardingModal.lua
--
-- One-page, forced-acknowledge intro shown on a player's first grind (and
-- replayable via the top-bar "?" button). Teaches the loop the itch-page
-- instructions never conveyed in-game: the intro loss is the tutorial, the
-- free Poker Poster lifts it, only the FIRST Stack at each bracket pays a chip
-- (so spread across tables), Shove banks chips, and run upgrades vs catalog.
-- Renders the live UI glyphs ({chip}, {stack}) so the symbols match the HUD.
--
-- Thin wrapper over views/widgets/ActionModal — the body lays content out
-- through the modal's measure/draw layout context, so the frame auto-sizes to
-- the copy and scrolls when it overflows the viewport.

local Theme       = require("views.Theme")
local ActionModal = require("views.widgets.ActionModal")
local IconText    = require("views.IconText")

local OnboardingModal = {}

local INTRO = {
    "The first run is rigged against you — go broke, hit SHOVE.",
    "This introduces you to shoving and the catalog. Grab the free poker poster to start for real.",
}

local LOOP = {
    "Grind away. Open tables, earn money.",
    "Win a {stack} stack to earn {chip} gold chips — once per stake/type, each run.",
    "SHOVE to spend your {chip} and reset the run stronger.",
}

local UPGRADES = {
    "Run upgrades (right side) - purchased with earnings; reset every run.",
    "Catalog: bought with {chip}; permanent, forever.",
}

local TIPS = {
    "Hover anything for details — stats, buttons, upgrades.",
    "bb/h (big blinds per hand) is a table's edge per hand; big green number = winning.",
    "Wins and losses are tiered as {w:small} {w:medium} {w:large} {w:stack} and {l:small} {l:medium} {l:large} {l:stack}. Upgrade for more {w:stack} and less {l:stack}",
    "Purchase cursors from the catalog to unlock the idle-mode"
}

local WINNING = {
    "Beat the SHOVE to beat the prototype (more gameplay will be coming shortly)",
    "Catalog upgrades give base SHOVE %, and your current total earnings multiply it",
}

-- Returns a configured ActionModal (:resolved() is truthy once dismissed).
function OnboardingModal:new(game)
    return ActionModal:new{
        game    = game,
        title   = "HOW TO PLAY",
        title_align = "left",
        aside   = "This is a pre-alpha prototype.\nNothing is final, expect bugs",
        w       = 760,
        buttons      = { { text = "Got it, deal me in", value = "ok", primary = true } },
        note         = "Got feedback or found a bug?\nLeave a comment — it really helps!",
        keys    = { space = "ok", ["return"] = "ok", kpenter = "ok" },
        body    = function(ui, fonts, s)
            local sm    = fonts.sm
            local row_h = sm:getHeight() + math.floor(3 * s)

            local function label(text)
                ui:para(text, "sm", Theme.fg.faint, "left")
                ui:gap(4)
            end
            -- Glyph lines ({chip}/{stack}) are game-specific, so they go
            -- through :custom — the widget stays poker-agnostic.
            local function iconRows(list)
                for _, line in ipairs(list) do
                    ui:custom(row_h, function(x, y)
                        IconText.draw(game, line, x, y, sm, Theme.fg.primary)
                    end)
                end
                ui:gap(12)
            end
            -- Intro is the lede — framed as a recessed callout (dark fill +
            -- border + brass accent bar) so it stands out from the plain text
            -- rows without a bigger font or a new text color.
            local function callout(list)
                local pad_x    = math.floor(14 * s)
                local pad_y    = math.floor(11 * s)
                local bar_w    = math.floor(4 * s)
                local line_gap = math.floor(4 * s)
                local inner_w  = ui.w - pad_x * 2
                local txt_h    = 0
                for i, line in ipairs(list) do
                    local _, wl = sm:getWrap(line, inner_w)
                    txt_h = txt_h + #wl * sm:getHeight()
                    if i < #list then txt_h = txt_h + line_gap end
                end
                local box_h = txt_h + pad_y * 2
                ui:custom(box_h, function(x, y, w)
                    local r = math.floor(3 * s)
                    Theme.setColor(Theme.bg.sunken)
                    love.graphics.rectangle("fill", x, y, w, box_h, r)
                    Theme.setColor(Theme.border.default)
                    love.graphics.rectangle("line", x, y, w, box_h, r)
                    Theme.setColor(Theme.border.strong)
                    love.graphics.rectangle("fill", x, y, bar_w, box_h)
                    love.graphics.setFont(sm)
                    local ty = y + pad_y
                    for _, line in ipairs(list) do
                        Theme.setColor(Theme.fg.heading)
                        love.graphics.printf(line, x + pad_x, ty, w - pad_x * 2, "left")
                        local _, wl = sm:getWrap(line, w - pad_x * 2)
                        ty = ty + #wl * sm:getHeight() + line_gap
                    end
                end)
                ui:gap(14)
            end

            callout(INTRO)
            label("THE LOOP");  iconRows(LOOP)
            label("UPGRADES");  iconRows(UPGRADES)
            label("TIPS");      iconRows(TIPS)
            label("WINNING");   iconRows(WINNING)
        end,
    }
end

return OnboardingModal
