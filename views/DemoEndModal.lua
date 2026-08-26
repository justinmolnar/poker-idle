-- views/DemoEndModal.lua
--
-- End-of-demo overlay (FEATURES.DEMO_CUT): win Runout 1, lose Runout 2 —
-- the Act 1 cliffhanger. Two buttons — Continue Playing / Exit to Title;
-- ShoveState reads :resolved() ("continue" | "exit"). Thin wrapper over
-- views/widgets/ActionModal.

local Theme       = require("views.Theme")
local ActionModal = require("views.widgets.ActionModal")

local DemoEndModal = {}

function DemoEndModal:new(game)
    return ActionModal:new{
        game    = game,
        title   = "DEMO COMPLETE",
        w       = 520,
        buttons = {
            { text = "Continue Playing", value = "continue", primary = true },
            { text = "Exit to Title",    value = "exit" },
        },
        keys = { space = "continue", ["return"] = "continue",
                 kpenter = "continue", escape = "exit" },
        -- Neutral copy — no runout/gauntlet structure, so first-timers
        -- aren't spoiled on what's still ahead in the full game.
        body = function(ui, fonts, _s)
            ui:para("That's the end of the demo.", "md", Theme.fg.heading, "center")
            ui:gap(18)
            ui:para(
                "Thanks for playing!"
                .. "\n\nYou can keep grinding from here. The run resets,"
                .. " and the full game picks up where this leaves off.",
                "sm", Theme.fg.muted, "center")
        end,
    }
end

return DemoEndModal
