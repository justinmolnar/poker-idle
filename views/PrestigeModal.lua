-- views/PrestigeModal.lua
--
-- Post-bust run summary: acknowledges the all-in loss and reports the chips
-- banked this run. A single Continue button advances the post-bust flow
-- (ShoveState reads :resolved()). Thin wrapper over views/widgets/ActionModal
-- — only the bust copy + chip tally is poker-specific.

local Theme       = require("views.Theme")
local ActionModal = require("views.widgets.ActionModal")
local Icons       = require("views.Icons")

local PrestigeModal = {}

-- Returns a configured ActionModal (:resolved() is truthy once dismissed).
function PrestigeModal:new(game, chips_banked, _busted_at)
    chips_banked = chips_banked or 0
    return ActionModal:new{
        game    = game,
        title   = "BUSTED",
        w       = 480,
        buttons = { { text = "Continue", value = "ok", primary = true } },
        keys    = { space = "ok", ["return"] = "ok", kpenter = "ok" },
        body    = function(ui, fonts, s)
            ui:para("You busted on the all-in.", "md", Theme.fg.muted, "center")
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
