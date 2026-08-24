-- views/PrestigeModal.lua
--
-- The modal that closes a shove. Two faces, one modal:
--
--   • BUSTED       — the all-in did not survive. Reports the {chip} banked
--                    this run, and deliberately not which runout ended it.
--   • an ACT BREAK — this shove won a runout for the first time. Winning
--                    runout 1 opens Act 2, winning runout 2 opens Act 3.
--
-- The act break is not a second modal after the bust summary. A player who
-- wins runout 1 also busts later in the same gauntlet, so showing "BUSTED"
-- and then "congratulations" is two beats where one is right -- and for the
-- whole life of the game the biggest milestone in it was announced with the
-- word BUSTED.
--
-- An act break can name a runout because the player has just watched that
-- runout resolve. The bust face cannot: see the copy below.
--
-- The lede stays narrow on purpose. Act 3's rules change is four lessons
-- (the multiplier is gone, {achip} come from losing, the high tiers are a
-- loss farm, corruption exists); only the first is a rules change the player
-- cannot discover, so only that one is here. The rest are grind hints on
-- first contact -- the same discipline docs/tutorial-teaching-list.md imposes
-- on the shove explainer.
--
-- Thin wrapper over views/widgets/ActionModal; ShoveState reads :resolved().

local Theme       = require("views.Theme")
local ActionModal = require("views.widgets.ActionModal")
local Icons       = require("views.Icons")

local PrestigeModal = {}

-- Data, not an if-chain: adding an act adds a row. `lede` is a list of
-- paragraphs so ActionModal's ui:para wraps each one on its own.
local MILESTONE = {
    act2 = {
        title = "RUNOUT 1",
        lede  = {
            "You beat the first runout. The house is not pleased.",
            "Mid stakes are open, and the deck rack is yours.",
            "The dealer took your catalog out of the second runout. Decks are the only edge that survives it: max five of them and The Master comes out.",
        },
    },
    act3 = {
        title = "RUNOUT 2",
        lede  = {
            "Two runouts down. Nobody gets this far.",
            "So the house changed the terms: your bankroll multiplier is zero. Forever.",
            "Money cannot buy the last runout. Find another way.",
        },
    },
}

-- Returns a configured ActionModal (:resolved() is truthy once dismissed).
-- `milestone` is nil for an ordinary bust. `_busted_at` stays in the signature
-- for the call site's sake and is intentionally unused: see the bust copy below.
function PrestigeModal:new(game, chips_banked, _busted_at, milestone)
    chips_banked = chips_banked or 0
    local m = MILESTONE[milestone or ""]

    return ActionModal:new{
        game    = game,
        title   = m and m.title or "BUSTED",
        -- The act-break lede runs three paragraphs; 480 sets them too narrow.
        w       = m and 560 or 480,
        buttons = { { text = "Continue", value = "ok", primary = true } },
        keys    = { space = "ok", ["return"] = "ok", kpenter = "ok" },
        body    = function(ui, fonts, s)
            if m then
                for i, para in ipairs(m.lede) do
                    if i > 1 then ui:gap(10) end
                    ui:para(para, "sm", Theme.fg.primary, "center")
                end
            else
                -- Deliberately does NOT name the runout it died on, though
                -- busted_at is right there. The gauntlet's multi-runout
                -- structure is a reveal the whole screen is built to protect:
                -- the banner says only ALL-IN, ShoveRate.formatBreakdown omits
                -- R2/R3, and DEMO_CUT collapses the result strip to one slot
                -- so empty ones cannot hint that more is coming. "You busted
                -- on runout 1" would tell a first-time player there is a
                -- runout 2. Once they have seen one the result chips already
                -- show which runout ended it, so naming it here buys nothing
                -- and costs the reveal.
                ui:para("You busted on the all-in.", "md", Theme.fg.muted, "center")
            end

            ui:gap(24)
            ui:para("BANKED THIS RUN", "sm", Theme.fg.muted, "center")
            ui:gap(4)
            -- Chip glyph + amount, centered together as a unit.
            ui:custom(fonts.lg:getHeight(), function(x, y, w)
                local lg    = fonts.lg
                local num   = tostring(chips_banked)
                love.graphics.setFont(lg)
                local num_w = lg:getWidth(num)
                local gsize = lg:getHeight()
                local gap   = math.floor(6 * s)
                local gx    = x + math.floor((w - (gsize + gap + num_w)) / 2)
                Icons.drawChip(game, gx, y, gsize)
                Theme.setColor(Theme.status.good)
                love.graphics.print(num, gx + gsize + gap, y)
            end)
        end,
    }
end

return PrestigeModal
