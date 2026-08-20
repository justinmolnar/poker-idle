-- controllers/InputController.lua
--
-- Wires global hotkeys onto the InputDispatcher with predicate-based routing.
-- The dispatcher fires the FIRST handler whose predicate passes — so global
-- hotkeys (F2 toggle state, F10 quit, etc.) are registered first, and the
-- catch-all forwards everything else to the StateMachine.
--
-- Adding a new global hotkey = one .on() call here. State-local input stays
-- in the state's own keypressed.

local InputController = {}
InputController.__index = InputController

function InputController:new(game)
    local self = setmetatable({ game = game }, InputController)
    return self
end

function InputController:wire()
    local game       = self.game
    local dispatcher = game.input_dispatcher
    local sm         = game.state_machine

    -- ── keypressed ────────────────────────────────────────────────────────

    -- F2: toggle grind ↔ shove. Useful while iterating on either screen.
    dispatcher:on("keypressed",
        function(key) return key == "f2" end,
        function()
            local next_name = (sm:current() == "grind") and "shove" or "grind"
            sm:switch(next_name)
        end)

    -- F4: perf HUD. Chip piles are the highest-count repeated element on
    -- screen and nothing else in the game measures draw volume, so this is
    -- the only way to see what a rendering change actually cost.
    dispatcher:on("keypressed",
        function(key) return key == "f4" end,
        function()
            game.debug.perf = not game.debug.perf
        end)

    -- ── Save debug hotkeys ────────────────────────────────────────────
    -- Auto-save runs unconditionally now (see main.lua), so no manual
    -- F5 commit is needed. F6 / F7 stick around as dev affordances:
    --   F6 — reload state from disk (snap back to last autosave checkpoint)
    --   F7 — delete both save slots and reset to a fresh game

    -- Walk the state-machine and tell each state to nuke its transient
    -- mid-flow state (running gauntlet, prestige modal, animation timer,
    -- etc.). Called from F6 / F7 so a reload-or-wipe doesn't leave stale
    -- views in suspended states.
    local function fullResetAllStates()
        for _, st in pairs(sm.states) do
            if type(st) == "table" and type(st.fullReset) == "function" then
                st:fullReset()
            end
        end
    end

    dispatcher:on("keypressed",
        function(key) return key == "f6" end,
        function()
            local state = game.state
            state:wipeAll()
            local saved = game.save_service:loadAll() or {}
            state:applySaved(saved)
            state.effects_cache = nil
            fullResetAllStates()
            -- Force grind re-enter so TablePool rebuilds + effects refresh.
            sm:switch("grind")
            print(string.format(
                "[save] F6 — reloaded.  bankroll=$%.2f  chips=%d  owned=%d",
                state.bankroll, state.chips, #state.owned_items))
        end)

    dispatcher:on("keypressed",
        function(key) return key == "f7" end,
        function()
            local state = game.state
            game.save_service:clearAll()
            state:wipeAll()
            fullResetAllStates()
            sm:switch("grind")
            print("[save] F7 — wiped.  fresh game.")
        end)

    -- ── Debug overlay toggle ────────────────────────────────────────────
    -- Backtick toggles a per-table tooltip showing exact win_chance /
    -- win_dist / loss_dist / EV-per-hand for the table the mouse is over,
    -- plus per-seated-opponent numbers. Off by default; see
    -- views/TablePanelStats.flushDebugOverlay (deferred so the tooltip draws on
    -- top of every panel in the grid, not just the panel that triggered it).
    dispatcher:on("keypressed",
        function(key) return key == "`" end,
        function()
            game.debug.overlay = not game.debug.overlay
            print(string.format("[debug] overlay = %s", tostring(game.debug.overlay)))
        end)

    -- F3 cycles the payout-source breakdown appended to every EV tooltip:
    -- off → grid → focused → totals → off. Three shapes of the same data
    -- (models/payout_breakdown) so they can be compared in place; two get
    -- deleted once one wins.
    dispatcher:on("keypressed",
        function(key) return key == "f3" end,
        function()
            local shapes = require("views.TablePanelStats").PAYOUT_SHAPES
            local n = (game.debug.payout_shape or 0) + 1
            if n > #shapes then n = 0 end
            game.debug.payout_shape = n
            print(string.format("[debug] payout breakdown = %s",
                n == 0 and "off" or shapes[n]))
        end)

    -- ── Debug bankroll grant (dev hotkeys) ──────────────────────────────
    --   `-` removes $1,000 from bankroll (clamped at 0)
    --   `=` adds    $1,000 to bankroll
    -- Useful for skipping the grind while iterating on upgrade / shove flows.
    -- Will be ripped before any release build.
    dispatcher:on("keypressed",
        function(key) return key == "-" end,
        function()
            local state = game.state
            state.bankroll = math.max(0, state.bankroll - 1000)
            print(string.format("[debug] bankroll -$1000 -> $%.2f", state.bankroll))
        end)
    dispatcher:on("keypressed",
        function(key) return key == "=" end,
        function()
            local state = game.state
            state.bankroll = state.bankroll + 1000
            print(string.format("[debug] bankroll +$1000 -> $%.2f", state.bankroll))
        end)

    -- ESC is now handled per-state: closes any open modal first; if no
    -- modal is open the state spawns the SettingsModal in quit-confirm
    -- mode. No global insta-quit binding.

    -- Catch-all: forward every other keypress to the active state.
    dispatcher:on("keypressed", nil, function(key) sm:keypressed(key) end)

    -- ── other events: always forward to state ────────────────────────────

    dispatcher:on("keyreleased",   nil, function(key)        sm:keyreleased(key)        end)
    dispatcher:on("mousepressed",  nil, function(x, y, b)    sm:mousepressed(x, y, b)   end)
    dispatcher:on("mousereleased", nil, function(x, y, b)    sm:mousereleased(x, y, b)  end)
    dispatcher:on("mousemoved",    nil, function(x, y, dx, dy) sm:mousemoved(x, y, dx, dy) end)
    dispatcher:on("textinput",     nil, function(text)       sm:textinput(text)         end)
    dispatcher:on("wheelmoved",    nil, function(x, y)       sm:wheelmoved(x, y)        end)
end

return InputController
