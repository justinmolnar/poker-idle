-- views/AnalyticsConsentModal.lua
--
-- Shown when a player clicks "Deal me in" without opting into analytics.
-- Explains what's collected and why, then lets them Accept or decline.
-- Resolves to "accept" or "decline".

local ActionModal = require("views.widgets.ActionModal")

local AnalyticsConsentModal = {}

local BODY = {
    "Poker Idle is in early development and needs balancing data to improve.",
    "If you opt in, the game sends anonymous gameplay summaries: hand outcomes, upgrade choices, shove rates, and session length. The data contains no personal information — no name, account, or device ID. Your IP MAY appear in standard server request logs, as with any web request (unavoidable) but is not used or looked at in any way.",
    "This data is used only to spot balance problems and guide what gets built next. Knowing how different players approach the game helps tune odds, payouts, and pacing.",
    "You can change this any time in Settings.",
}

function AnalyticsConsentModal:new(game)
    return ActionModal:new{
        game        = game,
        title       = "Help Balance the Game",
        w           = 780,
        buttons     = {
            { text = "Send Analytics", value = "accept", primary = true },
            { text = "No Thanks",      value = "decline" },
        },
        keys        = { ["return"] = "accept", kpenter = "accept", escape = "decline" },
        body        = function(ui, fonts, s)
            local fl = math.floor
            for i, para in ipairs(BODY) do
                ui:para(para, "sm", require("views.Theme").fg.primary)
                if i < #BODY then ui:gap(10) end
            end
        end,
    }
end

return AnalyticsConsentModal
