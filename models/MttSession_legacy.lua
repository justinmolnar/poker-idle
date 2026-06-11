-- models/MttSession.lua
--
-- Per-table tournament state. Composed onto Table for any game type with
-- `binary_outcome = true`; ignored by cash tables (instance still exists,
-- just stays at hands_won=0/state=nil so the cash table treats it as a
-- no-op). Splits the tournament-specific bookkeeping (hands won this run,
-- "currently registered" flag, pending payout cash) out of the cash-table
-- model so Table doesn't carry MTT-only fields at top level.
--
-- Lifecycle:
--   • :begin()       — flag the session as live (called on the first deal
--                      of a new MTT run from Table:deal).
--   • :winHand()     — bump hands_won.
--   • :settle(...)   — finalize: stash pending_payout, clear state.
--   • :drainPayout() — controller calls each frame; returns the payout
--                      cash if any, then clears pending_payout.
--   • :reset()       — REBUY / save-clear: zero hands_won and state.
--
-- save round-trip: hands_won and state are persisted via TablePool's parallel
-- arrays on GameState. pending_payout is transient (drained next frame).

local MttSession = {}
MttSession.__index = MttSession

function MttSession:new()
    return setmetatable({
        hands_won      = 0,
        state          = nil,    -- nil | "playing"
        pending_payout = nil,    -- $ amount, transient
    }, MttSession)
end

function MttSession:begin()
    if self.state == nil then
        self.state = "playing"
        -- A fresh run ALWAYS starts at 0. settle() leaves hands_won at the cap
        -- and only the controller's payout drain zeroes it -- but that payout is
        -- transient, so a save taken after a tournament finished (state back to
        -- nil) but before the drain restores hands_won at the cap. Without this
        -- reset the very first hand of the next run trips hands_won >= hand_count
        -- and instantly "wins". state == nil means not-in-a-run (a genuine
        -- mid-run save keeps state == "playing"), so this never wipes progress.
        self.hands_won = 0
    end
end

function MttSession:isPlaying()
    return self.state == "playing"
end

function MttSession:winHand()
    self.hands_won = self.hands_won + 1
end

-- Resolve the payout from the boost-aware payouts table for the current
-- hands_won total. Stashes it on pending_payout for the controller to
-- drain. Clears state so the next :begin starts a fresh run.
function MttSession:settle(buy_in, payouts_for_boost)
    local mult = (payouts_for_boost and payouts_for_boost[self.hands_won]) or 0
    self.pending_payout = mult * (buy_in or 0)
    self.state          = nil
end

-- Pop the pending payout (or nil if none). Caller is the controller; it
-- applies the payout to bankroll, fires the chip burst, and resets the
-- per-tournament hand counter via :reset.
function MttSession:drainPayout()
    local p = self.pending_payout
    self.pending_payout = nil
    return p
end

function MttSession:reset()
    self.hands_won      = 0
    self.state          = nil
    self.pending_payout = nil
end

return MttSession
