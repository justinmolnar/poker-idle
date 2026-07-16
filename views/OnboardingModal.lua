-- views/OnboardingModal.lua
--
-- One-page, forced-acknowledge intro shown on a player's first grind (and
-- replayable via the top-bar "?" button). Two columns: a "how to play" walk-
-- through on the left, a quick-reference glossary of the game's terms + poker
-- lingo on the right. Renders the live UI glyphs ({chip}, {stack}) so the
-- symbols match the HUD.
--
-- Thin wrapper over views/widgets/ActionModal. The whole two-column body is laid
-- out by hand inside one Layout:custom block (the modal's vertical flow can't do
-- side-by-side columns), so the frame auto-sizes to the taller column and scrolls
-- if it overflows the viewport. All copy auto-wraps (see wrapText).

local Theme       = require("views.Theme")
local Constants   = require("data.constants")
local ActionModal = require("views.widgets.ActionModal")
local IconText    = require("views.IconText")

local OnboardingModal = {}

-- Run-0 callout: only in the scripted-intro build. Under FEATURES.TUTORIAL
-- there is no rigged first run to warn about, so the callout is dropped.
local INTRO
if not Constants.FEATURES.TUTORIAL then
    INTRO = {
        "The first run is rigged against you. Go broke, hit SHOVE.",
        "This introduces you to shoving and the catalog. Grab the free poker poster to start for real.",
    }
end

local LOOP = {
    "Grind away. Open tables, earn money.",
    "Win a {stack} stack to bank {chip} gold chips, once per stake/type each run. A gold trim marks the tables and buttons you've already banked.",
    "SHOVE to spend your {chip} and reset the run stronger.",
}

local UPGRADES = {
    "Run upgrades (right side) can be purchased with earnings and reset every run.",
    "Catalog: Permanent upgrades bought with {chip}",
}

local TIPS = {
    "Hover anything for details (stats, buttons, upgrades, etc).",
    "$/h is a table's earnings per hand; big green number = winning. The gold {w:stack} % beside it is your odds of hitting a {w:stack}.",
    "Wins and losses are tiered as {w:small} {w:medium} {w:large} {w:stack} and {l:small} {l:medium} {l:large} {l:stack}. Upgrade for more {w:stack} and less {l:stack}",
    "Purchase 'Box of Mice' from the catalog to unlock the idle-mode",
    "Bricked with no tables and no buy-in? A Quick Reset appears over SHOVE, banking your {chip} and resetting you to $2.",
    "Access this menu again via the ? in the top right",
}

local WINNING = {
    Constants.FEATURES.TUTORIAL
        and "Win the SHOVE to beat the game."
        or  "Beat the SHOVE to beat the prototype (more gameplay will be coming shortly)",
    "Catalog upgrades give base SHOVE %, and your current total earnings multiply it",
}

-- Glossary. Each entry = { term, "definition" }. The definition is a plain
-- sentence — it auto-wraps to the column. {chip}/{w:stack}/etc markers render
-- as the live glyphs. Just write normal copy; line breaks are handled.
local GLOSSARY = {
    { "{chip} Gold Chip",    "Permanent currency. Earn via {w:stack} win; spend in the catalog." },
    { "{w:stack} {l:stack} Stack",     "The biggest win/loss tier." },
    { "$/h",                 "Earnings per hand. Big green number = winning." },
    { "bb/h",                "The same edge in big blinds; shown in tooltips." },
    { "Focus",               "Tables you can run at full strength (starts at 4). Over that, each extra table cuts your FOCUS % up top, lowering earnings on EVERY table. Green = full, red = overloaded." },
    { "Shove",               "Ends a run: banks your {chip} for the catalog, then starts a new run." },
    { "NL10",                "No-Limit table, $10 buy-in. Tables are named by buy-in." },
    { "Buy-in",              "Cost to open a table (100 big blinds)." },
    { "Rebuy / Cash out",    "Refill a busted table." },
    { "Tied up",             "Cash locked inside open tables. Not spendable until you cash out or close the table." },
    { "6-Max / HU / Zoom",   "Table modes: 6 seats (vanilla), a heads-up duel, or fast hands vs random opponents." },
    { "MTT",                 "Multi-Table Tournament. Win hands in a row to climb a payout ladder; a full sweep of 8 wins banks a {chip}." },
    { "Hole / Board",        "Your 2 private cards / the 5 shared community cards." },
    { "bb (big blind)",      "A table's bet unit; sets Buy-in cost and pot sizes. Shown in table tooltips." },
}

-- Returns a configured ActionModal (:resolved() is truthy once dismissed).
function OnboardingModal:new(game)
    local consent_default = (game.settings and game.settings.analytics_consent == true)
    return ActionModal:new{
        game    = game,
        title   = "HOW TO PLAY",
        title_align = "left",
        aside   = "This is a pre-alpha prototype.\nNothing is final, expect bugs",
        w       = 1240,
        buttons      = { { text = "Got it, deal me in", value = "ok", primary = true } },
        note         = "Got feedback or found a bug?\nLeave a comment — it really helps!",
        checkbox     = { text = "Send Anonymous Gameplay Analytics", default = consent_default },
        keys    = { space = "ok", ["return"] = "ok", kpenter = "ok" },
        body    = function(ui, fonts, s)
            local sm  = fonts.sm
            local fl  = math.floor
            local lh  = sm:getHeight()
            local lbl_gap   = fl(2 * s)   -- header -> body gap
            local line_gap  = fl(1 * s)   -- between wrapped lines
            local item_gap  = fl(6 * s)   -- between bullets
            local gloss_gap = fl(12 * s)  -- between glossary entries
            local sec_gap   = fl(10 * s)  -- between sections / blocks

            -- Word-wrap a string (with inline {icon} markers) to width w in the
            -- given color, drawing it line by line. IconText doesn't word-wrap,
            -- so we pack whole words (each measured WITH its icons) ourselves.
            -- first_indent (optional) shifts the FIRST line right by that many
            -- px and narrows it (so text can start beside a heading on the same
            -- line); wrapped lines run the full width. Returns the height used.
            local function wrapText(x, y, w, str, color, draw, first_indent)
                first_indent = first_indent or 0
                local space_w = sm:getWidth(" ")
                local cy, line, line_w = y, nil, 0
                local lx, avail = x + first_indent, w - first_indent
                local function flush()
                    if line then
                        if draw then IconText.draw(game, line, lx, cy, sm, color) end
                        cy = cy + lh + line_gap
                        line, line_w = nil, 0
                        lx, avail = x, w   -- wrapped lines run full width
                    end
                end
                for word in str:gmatch("%S+") do
                    local ww = IconText.measure(word, sm)
                    if not line then
                        -- Wide heading leaves no room beside it: drop the text
                        -- to a fresh full-width line instead of overflowing.
                        if avail < w and ww > avail then
                            cy = cy + lh + line_gap
                            lx, avail = x, w
                        end
                        line, line_w = word, ww
                    elseif line_w + space_w + ww <= avail then
                        line   = line .. " " .. word
                        line_w = line_w + space_w + ww
                    else
                        flush()
                        line, line_w = word, ww
                    end
                end
                flush()
                return cy - y
            end

            -- ── Block builders: each returns fn(x, y, w, draw) -> height.

            -- The recessed lede callout.
            local function calloutBlock(list)
                return function(x, y, w, draw)
                    local pad_x, pad_y, bar_w = fl(14*s), fl(11*s), fl(4*s)
                    local inner = w - pad_x * 2
                    -- Measure (wrap with draw=false), then box height.
                    local txt_h = 0
                    for i, line in ipairs(list) do
                        txt_h = txt_h + wrapText(0, 0, inner, line, Theme.fg.heading, false)
                        if i < #list then txt_h = txt_h + line_gap end
                    end
                    local box_h = txt_h + pad_y * 2
                    if draw then
                        local r = fl(3 * s)
                        Theme.setColor(Theme.bg.sunken)
                        love.graphics.rectangle("fill", x, y, w, box_h, r)
                        Theme.setColor(Theme.border.default)
                        love.graphics.rectangle("line", x, y, w, box_h, r)
                        Theme.setColor(Theme.border.strong)
                        love.graphics.rectangle("fill", x, y, bar_w, box_h)
                        local ty = y + pad_y
                        for i, line in ipairs(list) do
                            ty = ty + wrapText(x + pad_x, ty, inner, line, Theme.fg.heading, true)
                            if i < #list then ty = ty + line_gap end
                        end
                    end
                    return box_h
                end
            end

            -- A labeled section of glyph-aware bullets (THE LOOP, TIPS, ...).
            local function sectionBlock(label, lines)
                return function(x, y, w, draw)
                    if draw then
                        love.graphics.setFont(sm); Theme.setColor(Theme.fg.faint)
                        love.graphics.print(label, x, y)
                    end
                    local yy = y + lh + lbl_gap
                    for i, line in ipairs(lines) do
                        yy = yy + wrapText(x, yy, w, line, Theme.fg.primary, draw)
                        if i < #lines then yy = yy + item_gap end
                    end
                    return yy - y
                end
            end

            -- A plain faint header (e.g. "GLOSSARY").
            local function headerBlock(text)
                return function(x, y, w, draw)
                    if draw then
                        love.graphics.setFont(sm); Theme.setColor(Theme.fg.faint)
                        love.graphics.print(text, x, y)
                    end
                    return lh + lbl_gap
                end
            end

            -- A glossary entry: term (heading) then its definition on the SAME
            -- line, the definition wrapping to full width underneath.
            local function glossaryBlock(term, def)
                return function(x, y, w, draw)
                    local term_w = IconText.measure(term, sm)
                    local pad    = fl(10 * s)   -- gap between term and definition
                    if draw then IconText.draw(game, term, x, y, sm, Theme.fg.heading) end
                    return wrapText(x, y, w, def, Theme.fg.muted, draw, term_w + pad)
                end
            end

            -- ── Build the two columns.
            local left = {
                sectionBlock("THE LOOP", LOOP),
                sectionBlock("UPGRADES", UPGRADES),
                sectionBlock("TIPS",     TIPS),
                sectionBlock("WINNING",  WINNING),
            }
            if INTRO then table.insert(left, 1, calloutBlock(INTRO)) end
            local right = { headerBlock("GLOSSARY") }
            for _, e in ipairs(GLOSSARY) do right[#right + 1] = glossaryBlock(e[1], e[2]) end

            -- 60 / 40 column split.
            local col_gap = fl(24 * s)
            local lw = fl(ui.w * 0.60)
            local rw = ui.w - lw - col_gap

            -- Heights: sections separated by sec_gap; glossary header then entries
            -- by item_gap.
            local function colHeight(blocks, w, gap)
                local h = 0
                for i, b in ipairs(blocks) do
                    h = h + b(0, 0, w, false)
                    if i < #blocks then h = h + gap end
                end
                return h
            end
            local lH = colHeight(left, lw, sec_gap)
            local rH = right[1](0, 0, rw, false) + sec_gap
            for i = 2, #right do
                rH = rH + right[i](0, 0, rw, false)
                if i < #right then rH = rH + gloss_gap end
            end

            ui:custom(math.max(lH, rH), function(x, y)
                local yl = y
                for i, b in ipairs(left) do
                    yl = yl + b(x, yl, lw, true)
                    if i < #left then yl = yl + sec_gap end
                end
                local rx, yr = x + lw + col_gap, y
                yr = yr + right[1](rx, yr, rw, true) + sec_gap
                for i = 2, #right do
                    yr = yr + right[i](rx, yr, rw, true)
                    if i < #right then yr = yr + gloss_gap end
                end
            end)
        end,
    }
end

return OnboardingModal
