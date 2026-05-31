-- views/PrototypeEndModal.lua
--
-- End-of-prototype overlay (FEATURES.DEMO_CUT): win runout 1, lose runout 2.
-- Two buttons — Continue Playing / Exit to Title; ShoveState reads :resolved()
-- ("continue" | "exit"). Thin wrapper over views/widgets/ActionModal.

local Theme       = require("views.Theme")
local ActionModal = require("views.widgets.ActionModal")

local PrototypeEndModal = {}

function PrototypeEndModal:new(game)
    return ActionModal:new{
        game    = game,
        title   = "PROTOTYPE COMPLETE",
        w       = 520,
        buttons = {
            { text = "Continue Playing", value = "continue", primary = true },
            { text = "Exit to Title",    value = "exit" },
        },
        keys = { space = "continue", ["return"] = "continue",
                 kpenter = "continue", escape = "exit" },
        -- Neutral copy — no runout/gauntlet structure, so first-timers aren't
        -- spoiled on what's still ahead.
        body = function(ui, fonts, _s)
            ui:para("That's the end of the prototype.", "md", Theme.fg.heading, "center")
            ui:gap(18)
            ui:para(
                "Thanks for playing!"
                .. "\n\nYou can keep grinding from here — the run resets and"
                .. " more is coming in future builds.",
                "sm", Theme.fg.muted, "center")
        end,
    }
end

return PrototypeEndModal
