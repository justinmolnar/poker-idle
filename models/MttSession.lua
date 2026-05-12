-- models/MttSession.lua
--
-- Per-table tournament state. Composed onto Table for any game type with
-- `chip_stack_table = true` (the 8-max KO mode). Cash tables instantiate
-- but leave it at hands_won=0 / state=nil — no-op. Splits the
-- tournament-specific bookkeeping (hands won this run, "currently
-- registered" flag, pending payout cash, last finish position) out of
-- the table model.
--
-- Lifecycle:
--   • :begin()       — flag the session as live (called on the first deal
--                      of a new MTT run from Table:deal).
--   • :winHand()     — bump hands_won (deck-XP / lifetime stat tracking).
--   • :settle(...)   — finalize: look up payout by finish position,
--                      stash pending_payout, clear state.
--   • :drainPayout() — controller calls each frame; returns the payout
--                      cash if any, then clears pending_payout.
--   • :reset()       — REBUY / save-clear: zero hands_won and state.
--
-- save round-trip: hands_won and state are persisted via TablePool's parallel
-- arrays on GameState. pending_payout and last_finish are transient
-- (drained / read next frame).

local MttSession = {}
MttSession.__index = MttSession

function MttSession:new()
    return setmetatable({
        hands_won      = 0,
        state          = nil,    -- nil | "playing"
        pending_payout = nil,    -- $ amount, transient
        last_finish    = nil,    -- finish position from most recent settle,
                                 -- read by controller for bounty gating
    }, MttSession)
end

function MttSession:begin()
    if self.state == nil then self.state = "playing" end
end

function MttSession:isPlaying()
    return self.state == "playing"
end

function MttSession:winHand()
    self.hands_won = self.hands_won + 1
end

-- Resolve the payout for the given finish position (1 = won, 2 = 2nd
-- place, etc.). The mtt_payouts ladder is keyed descending — 1st = 8,
-- 2nd = 7, 3rd = 6 — so finish_positions outside the top-3 yield no
-- payout. Stashes pending_payout for the controller to drain and clears
-- state so the next :begin starts a fresh run.
function MttSession:settle(buy_in, payouts_for_boost, finish_position, n_seats)
    local key  = (n_seats or 0) - (finish_position or 0) + 1
    local mult = (payouts_for_boost and payouts_for_boost[key]) or 0
    self.pending_payout = mult * (buy_in or 0)
    self.last_finish    = finish_position
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
    self.last_finish    = nil
end

return MttSession
