-- sim/smoke_rate.lua
--
-- The rail's earn rate (GrindController:_tickRateTrace, GrindView's rate
-- tooltip):
--   trace    the run's hand winnings land in time buckets that add up to the
--            run's net; past data/rate_ticker `buckets` they merge in pairs
--            and the width doubles; a new run clears it; it is a run key
--   tooltip  a full board of one stake and game type is ONE line, with a
--            count, not one line per table
--
-- Standalone: `lua sim/smoke_rate.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local H          = require("sim.harness")
local RateTicker = require("data.rate_ticker")
local GameState  = require("models.GameState")

local F = Stub.font(16)
local w = H.world({ bankroll = 1e9 })
local g = w.game
g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
for _ = 1, 8 do w:open("s001", "zoom") end
local st = w.state

local function play(secs)
    for _ = 1, math.floor(secs * 60) do
        for i, t in ipairs(w:tables()) do if t.state == "idle" then w.ctrl:dealHand(i) end end
        w:tick(1 / 60)
    end
end

-- ── trace ───────────────────────────────────────────────────────────────
play(60)
local rt = st.run_rate_trace
c.ok(rt and rt.b and #rt.b > 1, "a minute in, the run has a trace")
c.eq(rt.w, RateTicker.bucket_s, "buckets start " .. RateTicker.bucket_s .. " s wide")
local function sum() local s = 0; for _, v in ipairs(st.run_rate_trace.b) do s = s + v end; return s end
c.ok(math.abs(sum() - st.run_hand_net) < 1e-6, "the buckets add up to the run's net")
play(RateTicker.bucket_s * RateTicker.buckets + 30)
rt = st.run_rate_trace
c.ok(rt.w >= RateTicker.bucket_s * 2, "past the cap the buckets merged (now " .. rt.w .. " s)")
c.ok(#rt.b <= RateTicker.buckets + 1, "and the count stays under the cap (" .. #rt.b .. ")")
c.ok(math.abs(sum() - st.run_hand_net) < 1e-6, "still adding up to the run's net after merging")
local listed = false
for _, k in ipairs(GameState.RUN_KEYS) do if k == "run_rate_trace" then listed = true end end
c.ok(listed, "the trace is saved with the run")
st:resetRun()
c.ok(not st.run_rate_trace, "a new run clears it")

-- ── tooltip ─────────────────────────────────────────────────────────────
do
    local w2 = H.world({ bankroll = 1e9 })
    local g2 = w2.game
    g2.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
    g2.state_machine = { states = {}, switch = function() end, current = function() return "grind" end }
    w2:upgrade("focus", 5); w2:deck("swarm", 5)
    for _ = 1, 20 do w2:open("s001", "zoom") end
    for _ = 1, 600 do
        for i, t in ipairs(w2:tables()) do if t.state == "idle" then w2.ctrl:dealHand(i) end end
        w2:tick(1 / 60)
    end
    Stub.recorder()
    love.graphics.newFont = function() return F end
    love.graphics.getFont = function() return F end
    local view = require("views.GrindView"):new(g2, w2.ctrl)
    local rows = view:_buildRateTooltipUncached(w2.ctrl:boardRate())
    local table_rows = 0
    for _, r in ipairs(rows) do
        if type(r) == "table" and r.text and r.text:find("·", 1, true) then table_rows = table_rows + 1 end
    end
    c.eq(table_rows, 1, "twenty tables of one stake and type are one line")
    local grouped = false
    for _, r in ipairs(rows) do
        if type(r) == "table" and r.text and r.text:find("×20", 1, true) then grouped = true end
    end
    c.ok(grouped, "with the count on it")
    c.ok(#rows < 12, "the tooltip stays short on a full board (" .. #rows .. " rows)")
end

if c.report("smoke_rate") > 0 then os.exit(1) end
