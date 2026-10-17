-- controllers/beat_stages.lua
--
-- What each House beat needs on screen to be looked at (controllers/
-- BeatBrowser, the dev-only beat browser on F9): the tables, the items,
-- the chips, the flags, the shove at its hold, the book open. A recipe is
-- data; `apply` builds it onto the browser's throwaway state through the
-- real controller, so what the beat lights is what the game would light.
--
-- DEV ONLY. The build's cut leaves this module out (build-tools/
-- demo_cut.py CUT_MODULES); nothing shipped requires it.
--
-- A recipe:
--   screen       where the beat plays (default: the beat's own)
--   bankroll     after the tables are opened
--   tables       { {stake_id, gtype}, ... } opened in order (table:N)
--   tab          the add-table strip's selected key (its rows register
--                for the selected key only)
--   flags        state fields set as given (hu_unlocked, shove_r1_won…)
--   owned        catalog ids owned
--   upgrades     { id = level }
--   chips, chips_this_run, first_hand_delta, anti_chips
--   banked       { "s001:zoom", ... } bounties banked this run
--   statuses     { {table_index, kind}, ... } a heater or a tilt
--   busted       { table_index, ... } idle with no stack (REBUY)
--   over_focus   true: tables past the focus capacity
--   corrupted    catalog ids corrupted
--   shove        { outcomes = {r1, r2, r3}, to = "running"|"won"|"result",
--                  chips = n } — the shove driven to that phase or hold
--   at_line      { [line_index] = "open_catalog"|"open_flyer"|"open_table" }
--                a hook run when the browser reaches that line
--   desc         one line for the panel

local Stages = {}

-- The base of every screen: the grind after a shove, two tables, a little
-- money; the room the same with three things owned; the shove the same
-- taken to the felt and lost.
local BASE = {
    grind = { bankroll = 50, tables = { { "s001", "zoom" }, { "s001", "zoom" } },
              flags = { has_shoved = true, hu_unlocked = true, catalog_seen = true },
              upgrades = {}, tab = "zoom", desc = "grind: two NL2 Zoom tables, $50" },
    room  = { screen = "room", bankroll = 50, tables = {},
              flags = { has_shoved = true, hu_unlocked = true, catalog_seen = true },
              owned = { "yellow_sticky_note", "energy_drink", "starter_gift_box" },
              desc = "room: three things owned" },
    shove = { bankroll = 50, tables = {}, flags = { has_shoved = true, hu_unlocked = true, catalog_seen = true },
              chips = 3, shove = { outcomes = { false, false, false }, to = "result", chips = 3 },
              desc = "shove: lost at the result" },
}

Stages.BY_ID = {
    arrival = { bankroll = 2, tables = {}, flags = { has_shoved = false, hu_unlocked = false, catalog_seen = false },
                at_line = { [4] = "open_table" }, desc = "fresh: $2, no table; a table opens for lines 4-5" },
    first_hand_lost = { tables = { { "s001", "zoom" } }, first_hand_delta = -0.5, flags = { has_shoved = false },
                        desc = "one table, the first hand lost" },
    first_hand_won  = { tables = { { "s001", "zoom" } }, first_hand_delta = 0.5, flags = { has_shoved = false },
                        desc = "one table, the first hand won" },
    first_payout    = { tables = { { "s001", "zoom" } }, bankroll = 1.5, flags = { has_shoved = false },
                        desc = "one table, money in the bankroll" },
    sharper_reads   = { tables = { { "s001", "zoom" } }, bankroll = 60, flags = { has_shoved = false },
                        desc = "Sharper Reads affordable" },
    second_table    = { tables = { { "s001", "zoom" } }, bankroll = 20, tab = "hu", flags = { has_shoved = false, hu_unlocked = true },
                        desc = "HU unlocked, the HU key selected, NL2 affordable" },
    first_chip      = { tables = { { "s001", "zoom" }, { "s001", "zoom" }, { "s001", "hu" }, { "s002", "zoom" } },
                        bankroll = 40, chips = 1, chips_this_run = 1, banked = { "s001:zoom" }, flags = { has_shoved = false },
                        desc = "four tables, NL2 Zoom banked, one chip" },
    the_pitch       = { chips = 3, chips_this_run = 3, flags = { has_shoved = false }, desc = "three chips: SHOVE unlocked" },
    shove_walkthrough = { shove = { outcomes = { false, false, false }, to = "running" }, desc = "shove: the hand running" },
    shove_result    = { desc = "shove: the result hold" },
    house_cheats    = { shove = { outcomes = { true, false, false }, to = "result" }, desc = "shove: R1 won, the cheat card dealt" },
    first_catalog   = { at_line = { [2] = "open_catalog" }, desc = "shove: the book landed; open from line 2" },
    first_purchase  = { owned = { "energy_drink" }, at_line = { [1] = "open_catalog" }, desc = "shove: the book open, the first thing bought" },
    the_loop        = { upgrades = { sharper_reads = 1, pot_control = 1, focus = 1 }, desc = "after the first shove, the rack bought into" },
    payout_sizes    = { tables = { { "s001", "zoom" } }, first_hand_delta = 0.5, flags = { has_shoved = false },
                        desc = "one table, the first hand won" },
    the_room        = { screen = "room", desc = "room: three things owned" },
    catalog_browse  = { at_line = { [1] = "open_catalog" }, desc = "grind: the book open to read" },
    first_heat      = { statuses = { { 1, "heater" } }, desc = "table 1 on fire" },
    first_tilt      = { statuses = { { 1, "tilt" } }, desc = "table 1 on tilt" },
    six_max_open    = { flags = { six_max_unlocked = true }, tables = { { "s001", "zoom" }, { "s001", "six_max" } }, tab = "six_max",
                        desc = "a 6-Max table open" },
    first_tournament = { flags = { shove_r1_won = true }, tables = { { "s001", "zoom" }, { "s001", "ko" } }, tab = "ko",
                         desc = "a tournament open" },
    first_cursors   = { owned = { "box_of_mice" }, tables = { { "s001", "zoom" } }, desc = "the Box of Mice owned: cursor rows on the rack" },
    stake_ladder    = { bankroll = 30, tab = "zoom", desc = "NL10 affordable on the Zoom key" },
    first_bust      = { busted = { 1 }, desc = "table 1 busted (REBUY)" },
    chip_denied     = { banked = { "s001:zoom" }, chips = 1, desc = "NL2 Zoom banked: its badge" },
    focus_overload  = { over_focus = true, desc = "tables past the focus capacity" },
    first_corruption = { flags = { shove_r2_won = true }, owned = { "corkboard" }, corrupted = { "corkboard" },
                         at_line = { [1] = "open_catalog" }, desc = "shove: the book open, a corrupted card (if on the page)" },
    act2            = { flags = { shove_r1_won = true }, bankroll = 20000, desc = "Act 2 open: the mid stakes on the strip" },
    flyer_lands     = { flags = { shove_r1_won = true }, desc = "shove: the flyer landed" },
    act2_decks      = { flags = { shove_r1_won = true }, at_line = { [1] = "open_flyer" }, desc = "shove: the flyer open" },
    the_top_table   = { flags = { shove_r1_won = true, shove_r2_won = true, ultra_unlocked = true }, bankroll = 1e15,
                        desc = "the top table on the strip" },
    underflow       = { chips = 3, chips_this_run = 3, bankroll = -1, desc = "bankroll under the floor, SHOVE unlocked" },
}

-- The recipe for a beat: its screen's base under its own entry.
function Stages.forBeat(beat)
    local own = Stages.BY_ID[beat.id] or {}
    local screen = own.screen or beat.screen
    local base = BASE[screen] or BASE.grind
    local r = {}
    for k, v in pairs(base) do r[k] = v end
    for k, v in pairs(own) do
        if k == "flags" then
            local f = {}
            for fk, fv in pairs(base.flags or {}) do f[fk] = fv end
            for fk, fv in pairs(v) do f[fk] = fv end
            r.flags = f
        else
            r[k] = v
        end
    end
    r.screen = screen
    return r
end

local function copyList(t)
    local out = {}
    for i, v in ipairs(t or {}) do out[i] = v end
    return out
end

-- Build the recipe onto the game's (wiped) state through the controller.
-- Returns what was built, for the panel.
function Stages.apply(r, game)
    local st   = game.state
    local ctrl = game.grind
    for k, v in pairs(r.flags or {}) do st[k] = v end
    st.owned_items = copyList(r.owned)
    st.corrupted_items = copyList(r.corrupted)
    st.run_upgrade_levels = {}
    for id, lvl in pairs(r.upgrades or {}) do st.run_upgrade_levels[id] = lvl end
    st.chips           = r.chips or 0
    st.chips_this_run  = r.chips_this_run or 0
    st.anti_chips      = r.anti_chips or 0
    st.first_hand_delta = r.first_hand_delta
    st.bankroll = 1e9                               -- the tables open on credit, then the money is set
    if ctrl then ctrl:invalidateEffects() end
    local opened = 0
    for _, t in ipairs(r.tables or {}) do
        if ctrl and ctrl:addTable(t[1], t[2]) then opened = opened + 1 end
    end
    if r.over_focus and ctrl then
        local cap, slots = ctrl:currentFocusCapacity(), ctrl:tableSlotsCap()
        while ctrl.pool:count() <= cap and ctrl.pool:count() < slots do
            if not ctrl:addTable("s001", "zoom") then break end
            opened = opened + 1
        end
    end
    st.bankroll = r.bankroll or 0
    for _, key in ipairs(r.banked or {}) do
        st.stakes_won_this_run = st.stakes_won_this_run or {}
        st.stakes_won_this_run[key] = true
        st.bounty_paid_this_run = st.bounty_paid_this_run or {}
        st.bounty_paid_this_run[key] = 1
    end
    for _, s in ipairs(r.statuses or {}) do
        local tbl = ctrl and ctrl.pool:get(s[1])
        if tbl and tbl.applyStatus then tbl:applyStatus(s[2], { magnitude = 0.35, t = 600, source = "beat_browser" }) end
    end
    for _, i in ipairs(r.busted or {}) do
        local tbl = ctrl and ctrl.pool:get(i)
        if tbl then tbl.stack = 0; tbl.state = "idle" end
    end
    if r.tab then
        local gs = game.state_machine and game.state_machine.states and game.state_machine.states.grind
        if gs and gs.view then gs.view.selected_gtype = r.tab end
    end
    if r.shove then
        st.has_shoved = true
        st.shove_pending = { chips = r.shove.chips or r.chips or 3, anti_chips = 0,
                             outcomes = copyList(r.shove.outcomes) }
    end
    if ctrl then ctrl:invalidateEffects() end
    return { opened = opened }
end

-- A line hook, when the browser reaches the line.
function Stages.hook(name, game)
    local sm  = game.state_machine
    local cur = sm and sm.current_state
    if name == "open_catalog" then
        if cur and cur.catalog_modal and cur.catalog_modal.openFromFelt then
            cur.catalog_modal:openFromFelt()
        elseif game.openCatalog then
            game.openCatalog()
        end
    elseif name == "open_flyer" then
        if cur and cur.deck_flyer and cur.deck_flyer.openFromFelt then cur.deck_flyer:openFromFelt() end
    elseif name == "open_table" then
        local ctrl = game.grind
        if ctrl and ctrl.pool:count() == 0 then
            local keep = game.state.bankroll
            game.state.bankroll = 1e9
            ctrl:addTable("s001", "zoom")
            game.state.bankroll = keep
        end
    end
end

return Stages
