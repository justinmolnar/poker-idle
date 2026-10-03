-- controllers/GrindController.lua
--
-- Sits between GrindState and the model layer. Owns the TablePool, applies
-- per-tick resolutions to bankroll, and routes
-- floating-text emission. Validates and applies purchase intents from the
-- view (run-upgrade and catalog buys).
--
-- The view doesn't mutate state directly — it dispatches intents to this
-- controller. Effects context is cached and only recomputed when an item is
-- bought or run state changes (cheap, since we're not doing it per-frame).

local TablePool      = require("models.TablePool")
local ShoveRate = require("models.shove_rate")
local TableModel     = require("models.Table")            -- only for anchorKey()
local TableGrid      = require("models.table_grid")       -- board cells, for bump direction
local Pop            = require("services.Pop")            -- shared-clock bump envelopes
local StatusData     = require("data.statuses")       -- shared slam/shove timing
local Decks          = require("models.Decks")
local Catalog        = require("data.catalog")
local RunUpgrades    = require("data.run_upgrades")
local ProcData       = require("data.procs")
local RouterData     = require("data.routers")
local OutcomeMath    = require("models.outcome_math")
local Stakes         = require("data.stakes")
local GameTypes      = require("data.game_types")
local Constants      = require("data.constants")
local RateTicker     = require("data.rate_ticker")
local ChipData       = require("data.chips")
local FeedbackIntensity = require("data.feedback_intensity")
local Denoms         = require("services.DenominationBreakdown")
local AnchorRegistry = require("services.AnchorRegistry")
local RollingValue = require("services.RollingValue")
local AwardGlow      = require("views.AwardGlow")
local StakeThemes    = require("data.stake_themes")
local Lookups        = require("utils.lookups")
local HandAnalytics  = require("services.HandAnalytics")
local Format         = require("utils.format")
local UpgradePricing = require("models.UpgradePricing")
local CursorPool     = require("services.CursorPool")
local Balance        = require("data.balance")


-- Chip-bounty key: a (stake, game_type) combo locks one bounty per run.
-- 4 game types × 6 stakes = 24 distinct bounty slots — total ~84 chips for
-- a perfect climb across all combos.
local function bountyKey(stake_id, game_type_id)
    return stake_id .. ":" .. game_type_id
end

-- A tournament being underway is a STATE, not an event, and the bus only
-- carries events. So a running tournament says so on a slow heartbeat, and
-- anything that wants to be true "while a tournament runs" hangs a short
-- status off it and lets the status refresh. The aura then ends by itself
-- within its own duration of the tournament finishing, and the whole status
-- pipeline -- magnitude, the ctx overlay, the readouts, the visuals,
-- persistence -- works unchanged. Same throttle the hint and story pollers
-- use; a beat this slow is free and imperceptible.
local TOURNEY_TICK = 0.5

-- The four orthogonal neighbours of a board cell. Hoisted: this used to
-- be a table literal INSIDE the per-table loops, so a 36-table board
-- built 360 throwaway tables every frame just to look sideways.
local NEIGHBOUR_DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Returned for a combo with no tables open. Read-only.
local EMPTY_SUMMARY = { open = 0, deal = 0, rebuy = 0, pending = 0 }

local GrindController = {}
GrindController.__index = GrindController

function GrindController:new(game)
    local self = setmetatable({
        game = game,
        -- Pending chip-flight bursts. Controller pushes burst descriptors
        -- (source, dest, chip indices, options); GrindView drains the queue
        -- each frame, builds render closures via views/Chips, and dispatches
        -- to services/FlightSystem. Decouples the controller from the view
        -- layer — no views/* require lives in this file.
        pending_bursts = {},
        -- Timed global buffs granted by procs (Cleaning Robot's cursor
        -- overdrive): { kind, value, t } entries, refresh-not-stack per
        -- kind. Ticked in :update, folded into every effects rollup in
        -- :invalidateEffects. Deliberately NOT persisted — a ten-second
        -- buff doesn't survive a reload, and that's fine.
        timed_buffs = {},
        -- Cutting Board: wins in a row on hands the player dealt. Not
        -- persisted; a streak is a session thing.
        manual_combo = 0,
    }, GrindController)
    -- Compute effects first so the initial pool rebuild gets ctx (matters
    -- for Cold Read and other start-of-table catalog perks).
    self:invalidateEffects()
    self.pool = TablePool:new(game.state, self.ctx, game.poker_events, game.effects,
                              game.event_bus)

    -- A table announces its own transitions; we just make the noise. This
    -- replaces a per-frame snapshot of every table's state plus a diff pass
    -- to work out what had moved, and it catches the transitions that
    -- snapshot structurally could not see: a deal, which happens between
    -- frames, and a hand force-resolved by a proc, which used to need its
    -- own patched-in call at the payload.
    if game.event_bus then
        game.event_bus:subscribe("table_state_changed", function(e)
            self:_playStateTransitionSound(e.from, e.to, e.table)
        end)
        -- Lifetime tilt / heater counts. Tilts feed catalog unlock gates
        -- (the shop stocks the cure once you've caught the disease);
        -- heaters feed the story (first_heat fires on the first one, from
        -- any source). Fresh applications only — a refresh is the same
        -- status still going.
        game.event_bus:subscribe("on_status_applied", function(e)
            if e.was_refresh then return end
            local st = self.game.state
            if e.status == "tilt" then
                st.total_tilts = (st.total_tilts or 0) + 1
                -- Plays when it APPEARS, like the heater (_tickHeaterSounds).
                if e.table then e.table._tilt_snd = true end
            elseif e.status == "heater" then
                st.total_heaters = (st.total_heaters or 0) + 1
                -- The strike plays when the heater APPEARS (_tickHeaterSounds):
                -- a punch-delivered one waits for the fist, which is set
                -- after this event, so it cannot be decided here.
                if e.table then e.table._heater_snd = true end
                -- Hot Hand levels on heaters caught.
                if Decks.systemUnlocked(st) then
                    self:_grantDeckXp({ type = "heater", n = 1 })
                end
            end
        end)
    end
    return self
end

-- (The resolution floater's "xN" mult suffix is gone: the number shown
-- is simply what the hand paid or cost, and the felt pot is now sized
-- from the post-multiplier payout — see effective_bb in Table:deal — so
-- the pot on the table and the money in the floater tell one story.)

-- Push a chip-flight intent onto the queue. GrindView drains this each
-- frame. Source/dest are { x, y } pairs (or nil — burst is dropped). chips
-- is the denomination-index list from DenominationBreakdown.
function GrindController:_queueBurst(source, dest, chips, options)
    if not source or not dest or not chips or #chips == 0 then return end
    self.pending_bursts[#self.pending_bursts + 1] = {
        -- "fly" = loose burst toward a point, "stack" = slot-to-slot
        -- between two real piles. GrindView dispatches on this.
        kind    = (options and options.kind) or "fly",
        source  = source,
        dest    = dest,
        chips   = chips,
        options = options,
    }
end

-- Push a chip-SCATTER intent (an explosion out of one point, no
-- destination) onto the same queue. GrindView dispatches on `kind`.
-- Same contract as _queueBurst otherwise: chips is a denomination-index
-- list, the view owns every rendering decision.
function GrindController:_queueScatter(origin, chips, options)
    if not origin or not chips or #chips == 0 then return end
    self.pending_bursts[#self.pending_bursts + 1] = {
        kind    = "scatter",
        source  = origin,
        chips   = chips,
        options = options,
    }
end

-- Drain and return the queued bursts, clearing the buffer. GrindView calls
-- this each frame.
function GrindController:drainBursts()
    local bursts = self.pending_bursts
    self.pending_bursts = {}
    return bursts
end

-- Recompute the effects context from the player's owned items + run upgrades.
-- Called on construction and after any purchase / prestige reset.
-- Bucket the owned procs by trigger, once per rollup. _fireProcs then
-- does a table lookup instead of scanning every proc on every hand.
--
-- It also (re)subscribes, which is the point: the trigger names come out of
-- data/procs.lua and nothing here enumerates them. Gameplay announces what
-- happened; whether any proc cares is decided by the data. Adding a trigger
-- is an edit to that file plus somewhere in the game that publishes the
-- name, and no code in this controller changes at all.
-- Whether the owned proc/router id lists differ from the ones the current
-- subscriptions were built from. The rollup runs on every bounty, deck
-- level and tournament payout, but the SET of owned procs changes only when
-- the player buys or corrupts something — and resubscribing means dropping
-- and rebuilding a closure per trigger and re-sorting each subscriber list
-- on the bus. So the index is rebuilt every time (it is cheap and reflects
-- the live ctx) and the bus is touched only when the ids actually moved.
local function sameIdList(prev, list)
    if not prev then return false end
    local n = #list
    if #prev ~= n then return false end
    for i = 1, n do
        if prev[i] ~= list[i] then return false end
    end
    return true
end

local function copyIdList(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

function GrindController:_rebuildProcIndex()
    local index = {}
    -- Each id once: a deck grants its proc per level (applyN), and an
    -- indexed duplicate would fire once per level.
    local seen = {}
    for _, id in ipairs((self.ctx and self.ctx.procs) or {}) do
        local proc = ProcData[id]
        if proc and proc.trigger and not seen[id] then
            seen[id] = true
            local list = index[proc.trigger]
            if not list then list = {}; index[proc.trigger] = list end
            -- Carry the id so feedback can name the item that fired.
            list[#list + 1] = { id = id, def = proc }
        end
    end
    self.proc_index = index

    -- Routers, same shape: owning the item is what puts one in the delivery
    -- path, selling it takes it out. One subscription total no matter how
    -- many are owned, so a board with none pays nothing (ProcRegistry skips
    -- the whole negotiation when nobody is listening on "deliver").
    local routers = {}
    local seen_r = {}
    for _, id in ipairs((self.ctx and self.ctx.routers) or {}) do
        local def = RouterData[id]
        if def and not seen_r[id] then
            seen_r[id] = true
            routers[#routers + 1] = { id = id, def = def }
        end
    end
    self.router_list = routers

    local bus = self.game and self.game.event_bus
    if not bus then return end

    -- Nothing owned changed: the standing subscriptions already point at
    -- this controller and read self.proc_index / self.router_list live, so
    -- they keep working against the index just rebuilt above.
    local proc_ids   = (self.ctx and self.ctx.procs)   or {}
    local router_ids = (self.ctx and self.ctx.routers) or {}
    if self._proc_tokens
       and sameIdList(self._proc_ids_seen, proc_ids)
       and sameIdList(self._router_ids_seen, router_ids) then
        return
    end
    self._proc_ids_seen   = copyIdList(proc_ids)
    self._router_ids_seen = copyIdList(router_ids)

    -- Drop the old subscriptions before taking new ones, or every rollup
    -- would stack another copy and a proc would fire once per rollup.
    for _, tok in ipairs(self._proc_tokens or {}) do bus:unsubscribe(tok) end
    local tokens = {}
    if #routers > 0 then
        tokens[#tokens + 1] = bus:subscribe("deliver", function(d)
            return self:_route(d)
        end)
    end
    for trigger in pairs(index) do
        tokens[#tokens + 1] = bus:subscribe(trigger, function(e)
            self:_fireProcs(trigger, e.table, e)
        end)
    end
    self._proc_tokens = tokens
end

-- Fire every proc watching `trigger`. `extra` carries whatever the trigger
-- knows that a selector, payload, or filter might want: `out` (the
-- resolution list being iterated, for resolve-style payloads), `n`,
-- `busted_total`, plus the fields ProcRegistry filters on — `count` for
-- `every`-procs, `status`/`was_refresh`/`magnitude` for `when`-procs.
-- Every field a publisher sends that a proc can read MUST survive the
-- rebuild below; dropping one silently kills every item filtering on it.
-- Say what happened. Whether anything listens is not this function's
-- business, and the name is a fact about the game rather than the name of a
-- mechanism: "a stack was lost here", not "run the cooler proc".
--
-- Delivered immediately rather than at the frame's drain, because some of
-- these are announced from inside the resolution loop and a listener may
-- add to the very list that loop is walking (the zoom cascade settles other
-- tables and their resolutions have to be paid this frame, not dropped).
-- Immediate delivery is safe here: we are not inside a dispatch, so the bus
-- queue still flattens any events the listeners themselves raise.
function GrindController:_announce(name, event)
    local bus = self.game and self.game.event_bus
    if not bus then return end
    bus:publish(name, event)
    bus:drain()
end

-- Walk the owned routers over one delivery. Each may move it or change
-- what it is; the first that answers wins, so ownership order decides and
-- two routers cannot fight over the same delivery every frame.
function GrindController:_route(d)
    local reg = self.game and self.game.procs
    if not (reg and d) then return end
    for _, entry in ipairs(self.router_list or {}) do
        local fn = reg.routers and reg.routers[entry.def.kind]
        if fn then
            local chance = entry.def.chance
            -- The registry's injected rng, same as proc chance rolls — a
            -- seeded sim or test harness must stay deterministic here too.
            if not chance or reg.rng() < chance then
                local before_to, before_status = d.to, d.status
                fn(entry.def, d)
                if d.to ~= before_to or d.status ~= before_status then
                    if entry.def.ghost then
                        self:procFired(entry.def.ghost, d.to)
                    end
                    return d.to
                end
            end
        end
    end
end

function GrindController:_fireProcs(trigger, source_tbl, extra)
    local list = self.proc_index and self.proc_index[trigger]
    if not list then return end
    local reg = self.game.procs
    if not reg then return end
    for _, entry in ipairs(list) do
        -- WHO it can happen to. A proc that belongs to one mode's identity
        -- says so here; without this the 6-max cooler tilt fires when a
        -- Heads Up table loses a stack, and HU has no multiway cooler to
        -- lose (docs/gametype-identity-redesign.md: the cooler is "a real
        -- cost for the tank slot").
        local src = entry.def.source
        local ok = not (src and src.gtype)
                   or (source_tbl and source_tbl.game_type_id == src.gtype)
        if ok then
        local event = {
            kind   = trigger,
            source = source_tbl,
            pool   = self.pool,
            ctrl   = self,
            state  = self.game.state,
            ctx    = self.ctx,
            ghost  = entry.def.ghost,
            n      = (extra and extra.n) or 1,
            out    = extra and extra.out,
            busted_total = (extra and extra.busted_total) or 0,
            -- The filter fields. `every` reads count; `when` reads the rest.
            count       = extra and extra.count,
            status      = extra and extra.status,
            was_refresh = extra and extra.was_refresh,
            magnitude   = extra and extra.magnitude,
            first_at_stake = extra and extra.first_at_stake,
            all_games      = extra and extra.all_games,   -- the Laminated Blueprint's `when`
            spread         = (extra and extra.spread) or false,   -- a deal a spread made (the Energy Drink's `when`)
        }
        local touched, hit = reg:fire(entry.def, event)
        if touched > 0 then
            -- Only procs that declare themselves a BLOW (impact = true)
            -- get the fist or the shove. Most procs are not violence: the
            -- printer chatters, a counter ticks, a heater lands; animating
            -- those as an assault says something the mechanic does not
            -- mean, so the default is quiet and a blow opts in.
            if entry.def.impact == true then
                self:_bumpTargets(source_tbl, hit)
            end
            if entry.def.ghost then self:procFired(entry.def.ghost, source_tbl) end
            -- A proc may have put a status on a table that had none, and
            -- the save arrays hold per-table references. Re-sync so the
            -- new list is reachable from state (existing lists tick in
            -- place and need no help).
        end
        end
    end
end

-- Make the hit visible: the source table physically shoves the tables it
-- affected, and they rock away from it.
--
-- Direction comes from the board itself — tables own a cell, so the model
-- knows which way a neighbour lies without asking the view anything. One
-- target means a directed lunge; several means the source swells and
-- shoves them all at once, because a table cannot lunge four ways.
function GrindController:_bumpTargets(source_tbl, targets)
    if not targets or #targets == 0 then return end

    local sr, sc
    if source_tbl and source_tbl.slot then
        sr, sc = TableGrid.unpack(source_tbl.slot)
    end

    -- TWO MOTIONS, chosen by how many tables are being hit:
    --   one   -> BUMP. The source reaches over and shoves that table.
    --   many  -> SLAM. It can't shove four directions, so it drives a
    --            fist into the felt and everything around it jumps.
    -- A proc picks which one it gets by how it targets (see data/procs).
    local single = (#targets == 1 and targets[1] ~= source_tbl)

    -- Nothing reacts while the blow is still travelling. A slam connects
    -- when the fist lands; a bump connects at the top of its arc. Until
    -- then the struck tables sit still and show nothing of the status
    -- they have already taken (see Table.impact_wait).
    -- Contact is the END of the downswing (rise + strike), not the start
    -- of it — that is the frame the blow actually arrives.
    local cfg = single and (StatusData.shove or {}) or (StatusData.slam or {})
    local delay = (cfg.duration or 1) * ((cfg.rise or 0.4) + (cfg.strike or 0.06))

    for _, t in ipairs(targets) do
        if t ~= source_tbl and t.slot and sr then
            local tr, tc = TableGrid.unpack(t.slot)
            local dx, dy = tc - sc, tr - sr
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0 then
                self._pending_impacts = self._pending_impacts or {}
                self._pending_impacts[#self._pending_impacts + 1] = {
                    tbl = t, dx = dx / len, dy = dy / len, t_left = delay,
                    slam = not single,
                }
                t.impact_wait = delay
            end
        end
    end

    if not source_tbl then return end

    if single and targets[1].slot and sr then
        -- BUMP: reach over and shove that one table.
        local tr, tc = TableGrid.unpack(targets[1].slot)
        local dx, dy = tc - sc, tr - sr
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then
            source_tbl.bump_dx, source_tbl.bump_dy = dx / len, dy / len
            source_tbl.bump_out, source_tbl.bump_slam = true, false
            source_tbl.shake_trauma = math.max(source_tbl.shake_trauma or 0, 0.7)
            Pop.trigger("tbl_bump:" .. (source_tbl._id or 0))
        end
    else
        -- SLAM: a fist into the felt, and everything around it jumps.
        source_tbl.bump_dx, source_tbl.bump_dy = 0, 1
        source_tbl.bump_out, source_tbl.bump_slam = false, true
        Pop.trigger("tbl_bump:"  .. (source_tbl._id or 0))
        Pop.trigger("tbl_shove:" .. (source_tbl._id or 0))
        -- Trauma is squared before it becomes pixels, so this needs to be
        -- high to read as a shudder rather than a twitch.
        source_tbl.shake_trauma = math.max(source_tbl.shake_trauma or 0, 1.0)
    end
end

-- Land any shockwaves whose travel time is up. Ticked once per frame
-- from :update, on raw dt — a blow crosses the board at the same speed
-- whatever pace the tables are running at.
-- A heater's strike, once the heater is visible: the frame after it was
-- applied, or the frame its punch connects (impact_wait back to 0).
function GrindController:_tickHeaterSounds()
    for _, t in ipairs(self.pool.tables) do
        if (t.impact_wait or 0) <= 0 then
            if t._heater_snd then t._heater_snd = nil; self:_playNamed("heater_lands") end
            if t._tilt_snd   then t._tilt_snd   = nil; self:_playNamed("tilt_lands")   end
        end
    end
end

local SHOVE_PUNCH = { volume_mult = 0.5 }
function GrindController:_tickImpacts(dt)
    local list = self._pending_impacts
    if not list or #list == 0 then return end
    for i = #list, 1, -1 do
        local e = list[i]
        e.t_left = e.t_left - (dt or 0)
        local t = e.tbl
        if e.t_left <= 0 then
            -- Contact. Knocked away, rattled, and only NOW does whatever
            -- it was given become visible.
            t.bump_dx, t.bump_dy = e.dx, e.dy
            t.bump_out, t.bump_slam = false, false
            t.impact_wait  = 0
            t.shake_trauma = math.max(t.shake_trauma or 0, 0.9)
            Pop.trigger("tbl_bump:" .. (t._id or 0))
            -- The fist landing; a neighbour shove is the same blow, quieter.
            -- Per-name min_gap makes a slam's many targets one hit.
            self:_playNamed("punch", (not e.slam) and SHOVE_PUNCH or nil)
            table.remove(list, i)
        else
            t.impact_wait = e.t_left
        end
    end
end

-- Ghost + sound for a proc. itemFired keys off ctx.sources[kind], but
-- every proc shares the kind "proc", so that path would pop every proc
-- item's sprite at once. The proc names its own item instead.
function GrindController:procFired(item_id, tbl)
    local bus = self.game.event_bus
    if not bus or not item_id then return end
    local x, y, pw, ph
    local pos = tbl and AnchorRegistry.get(TableModel.anchorKey(tbl, "center"))
    if pos then x, y, pw, ph = pos[1], pos[2], pos[3], pos[4] end
    bus:publish("item_fired", { item_id = item_id, kind = "proc",
                                x = x, y = y, pw = pw, ph = ph })
end

-- The zoom-first opening's unlock clock. Two jobs, both cheap:
--   * Latch HU open the moment a second table is affordable (one live
--     table AND a spare buy-in). One-way, meta-side — a spend later
--     never re-locks the duel.
--   * Fanfare each game type exactly ONCE per save when it becomes
--     available: the tab flashes (AwardGlow on the strip's own anchor,
--     same call the bounty fanfare uses) and the flourish plays. The
--     story beats carry the words; this carries the sparkle.
function GrindController:_tickGtypeUnlocks()
    local state = self.game.state
    if not state.hu_unlocked
       and self.pool:count() >= 1
       and state.bankroll >= self:_cheapestBuyIn() then
        state.hu_unlocked = true
    end
    local announced = state.gtype_announced
    if announced then
        for gtype_id, gate in pairs(Constants.GTYPE_GATE) do
            if gate and not announced[gtype_id] and state[gate] == true then
                announced[gtype_id] = true
                AwardGlow.flash("gtype:" .. gtype_id)
                self:_playNamed("stake_up_flourish")
            end
        end
    end
end

-- Grant (or refresh) a timed global buff. Same kind refreshes — strongest
-- value, longest clock — matching the status layer's refresh-not-stack.
function GrindController:addTimedBuff(kind, value, t)
    for _, b in ipairs(self.timed_buffs) do
        if b.kind == kind then
            b.value = math.max(b.value, value or 1)
            b.t     = math.max(b.t, t or 0)
            self:invalidateEffects()
            return
        end
    end
    self.timed_buffs[#self.timed_buffs + 1] =
        { kind = kind, value = value or 1, t = t or 0 }
    self:invalidateEffects()
end

function GrindController:_tickTimedBuffs(dt)
    local expired = false
    for i = #self.timed_buffs, 1, -1 do
        local b = self.timed_buffs[i]
        b.t = b.t - dt
        if b.t <= 0 then
            table.remove(self.timed_buffs, i)
            expired = true
        end
    end
    if expired then self:invalidateEffects() end
end

-- Put an idle table back to work, on the house's clock rather than a
-- cursor's. The Copy Machine's cascade upgrade calls this for zoom tables
-- the sweep finds empty; the guards mirror what a cursor checks before
-- clicking DEAL.
-- A deal is a moment procs can fire on. Every deal announces, so anything
-- listening for a deal sees this one; `opts.spread` marks a deal that a
-- proc's payload made (the Energy Drink dealing a neighbour), and the
-- event carries it so the spread itself can decline to spread again: a
-- block of Zoom tables must not chain end to end off one click. It is a
-- deal in every other sense.
-- The deal's own feedback: the felt pops brighter for a moment
-- (TablePanelEffects.drawFeltLight reads border_pulse_t with kind
-- "deal"; the border itself is the bounty trim's and is left alone).
-- Never over a result's pulse still fading, so a quick re-deal does not
-- wipe the verdict.
-- Every deal path calls this (the click, a cursor, an item's fan-out,
-- dealAll), because the frame is how the player sees which table just
-- started, wherever the deal came from.
local DEAL_PULSE = 0.6
-- The press (TablePanelEffects.dealSpring): a quarter second, give or
-- take, and a little more or less travel, rolled per deal so a board
-- of cursors dealing does not move in lockstep.
local DEAL_SPRING_DUR = 0.22
local DEAL_SPRING_JITTER = 0.25
-- Cosmetic randomness has its own generator: the jitter must not draw
-- from love.math.random, which is the game's outcome stream (the
-- headless sims seed it and every check downstream of a deal would
-- shift by two draws). A plain LCG is plenty for a wobble.
local function fxRandom(self)
    local x = (self._fx_seed or 12345) * 1103515245 + 12345
    x = x % 2147483648
    self._fx_seed = x
    return x / 2147483648
end
function GrindController:_dealFx(t)
    local r1 = (fxRandom(self) * 2 - 1) * DEAL_SPRING_JITTER
    local r2 = (fxRandom(self) * 2 - 1) * DEAL_SPRING_JITTER
    t.deal_spring = { t = 1, dur = DEAL_SPRING_DUR * (1 + r1), amp = 1 + r2 }
    if (t.border_pulse_t or 0) > 0.05 and t.border_pulse_color ~= "deal" then return end
    t.border_pulse_t     = DEAL_PULSE
    t.border_pulse_color = "deal"
end

function GrindController:dealIdleTable(t, opts)
    if not t or t.state ~= "idle" or t.pending_close then return false end
    if (t.stack or 0) <= 0 then return false end
    if not t:deal(self.ctx) then return false end
    -- `opts.by_cursor`: the hand this deal chains off was a cursor's
    -- (the Zoom chain reads its own table's mark, a spread its source's,
    -- a clash is the cursors'). The mark rides the new hand so the chain
    -- carries it link to link, and the Swarm deck levels on it (models/
    -- deck_xp_rules): a player's click fanning out earns nothing, a
    -- cursor's earns every hand it causes. The cursor ITEMS still gate on
    -- the clicks alone (total_cursor_deals).
    local by_cursor = (opts and opts.by_cursor) == true
    t._swarm_deal = by_cursor
    self:_dealFx(t)
    self:_announce("on_deal", { table = t, spread = (opts and opts.spread) or false })
    if by_cursor then self:_grantDeckXp({ type = "swarm_deal" }) end
    return true
end

-- ─── The display revision ──────────────────────────────────────────────
-- One strictly-increasing number meaning "something a readout derives from
-- has changed". The EV cache below and every memoized tooltip key on it, so
-- the whole derived-UI layer refreshes exactly when it must and never
-- otherwise. Bumped by: the effect rollup (invalidateEffects), a ctx field
-- something reads (_setCtxField; the live counters only when an owned item
-- consumes them, and then at most twice a second), and — checked once per
-- frame in update — the table pool, the owned-catalog set, and the debug
-- payout shape.
function GrindController:_bumpDisplay()
    self.display_rev = (self.display_rev or 0) + 1
end

-- The per-frame half of the above: three counters this controller does not
-- own, folded in with one comparison each.
function GrindController:_pollDisplayInputs()
    local state = self.game.state
    local pool_rev  = (self.pool and self.pool.rev) or 0
    local owned_rev = state.owned_rev or 0
    local shape     = (self.game.debug and self.game.debug.payout_shape) or 0
    if pool_rev  ~= self._seen_pool_rev
    or owned_rev ~= self._seen_owned_rev
    or shape     ~= self._seen_payout_shape then
        self._seen_pool_rev      = pool_rev
        self._seen_owned_rev     = owned_rev
        self._seen_payout_shape  = shape
        self:_bumpDisplay()
    end
    -- A live counter an owned item reads (LIVE_CTX_FIELDS) moved: fold it
    -- at most every LIVE_BUMP_SECS. Hands per second changes ~20 times a
    -- second on a busy board, and each bump empties every EV cache and
    -- memo in the game; half a second of staleness on a Framed Diploma
    -- readout is invisible, twenty rebuilds a second was not.
    if self._live_dirty then
        local t = self.clock or 0
        if t - (self._live_bump_t or -1e9) >= GrindController.LIVE_BUMP_SECS then
            self._live_dirty  = false
            self._live_bump_t = t
            self:_bumpDisplay()
        end
    end
end

-- ─── The EV cache ──────────────────────────────────────────────────────
-- OutcomeMath.evStats is ~20 µs and was called from the draw path three
-- times per open table per frame (measure, draw, tooltip) plus twice per
-- visible stake in the sidebar — roughly 130 calls a frame at a full board,
-- all of them recomputing an answer that only moves when the rollup does.
--
-- Two levels of plain table so a hit allocates nothing. The whole cache is
-- dropped when the display revision moves; nothing here is ever mutated by
-- a caller (the readouts and the tooltip builders only read).
function GrindController:evStats(stake, gtype)
    if not (stake and gtype) then return nil end
    local rev   = self.display_rev or 0
    local cache = self._ev_cache
    if not cache or self._ev_cache_rev ~= rev then
        cache = {}
        self._ev_cache, self._ev_cache_rev = cache, rev
    end
    local by_gtype = cache[stake.id]
    if not by_gtype then by_gtype = {}; cache[stake.id] = by_gtype end
    local hit = by_gtype[gtype.id]
    if hit == nil then
        hit = OutcomeMath.evStats(self.ctx, gtype, stake) or false
        by_gtype[gtype.id] = hit
    end
    return hit or nil
end

-- The per-table variant. A table's numbers also move with its own statuses
-- (Table:effectiveCtx layers them over the ctx) and its seat count, so those
-- ride in the validity check alongside the display revision.
-- What a readout needs to price THIS table the way its next hand will
-- pay: the table itself (its cell, whether it is held, whether anything
-- is beside it), the Tally Book multiplier the streak would stamp on a
-- hand dealt now, the focus multiplier, the bankroll (the Bank capstone
-- reads it) and whether the board is over the FOCUS cap (the corrupted
-- Gaming Chair). Second return: a key for the caches, so a table moved,
-- picked up or dealt into a streak reprices without waiting for the
-- rollup to change.
--
-- Split in two so a cache HIT allocates nothing: the parts of the key that
-- are the same for every table this frame (the streak multiplier, the
-- over-cap flag, the bankroll and its multiplier bucket) are computed once
-- per controller tick, the per-table parts are compared field by field
-- against the cache slot, and the opts table is built only on a miss.
-- (Building the opts and concatenating a seven-part key string on every
-- call, twice per table per frame, was a few hundred bytes of garbage a
-- table a frame at a full board, for a lookup that hit.)
function GrindController:_evFrameConsts()
    local clock = self.clock or 0
    if self._ev_clock == clock and self._ev_consts then return end
    self._ev_clock  = clock
    self._ev_consts = true
    local ctx   = self.ctx or {}
    local state = self.game.state
    local mc    = ctx.manual_combo
    local hand_mult = nil
    if mc then
        hand_mult = math.min(mc.cap or 2, 1 + (mc.value or 0) * (self.manual_combo or 0))
    end
    -- Focus is not in here: it slows the table (Table:update's pace),
    -- it does not scale the hand, so the per-hand figure is the hand's.
    local bank = ctx.earnings_scale_by_bankroll and (state.bankroll or 0) or nil
    self._ev_hand_mult = hand_mult
    self._ev_overcap   = self.pool:count() > self:currentFocusCapacity()
    self._ev_bank      = bank
    self._ev_bank_key  = bank and math.floor(ShoveRate.bankrollMultiplier(bank) * 100 + 0.5) or 0
end

-- Does the cache slot still describe this table's position and hand?
local function evSlotMatches(self, slot, tbl)
    return slot.k_adj == (tbl._empty_adjacent or 0)
       and slot.k_lonely == (tbl._lonely and 1 or 0)
       and slot.k_held == (tbl._held and 1 or 0)
       and slot.k_slot == (tbl.slot or -1)
       and slot.k_hand_mult == (self._ev_hand_mult or 1)
       and slot.k_overcap == self._ev_overcap
       and slot.k_bank == self._ev_bank_key
end

local function evSlotStamp(self, slot, tbl)
    slot.k_adj       = tbl._empty_adjacent or 0
    slot.k_lonely    = tbl._lonely and 1 or 0
    slot.k_held      = tbl._held and 1 or 0
    slot.k_slot      = tbl.slot or -1
    slot.k_hand_mult = self._ev_hand_mult or 1
    slot.k_overcap   = self._ev_overcap
    slot.k_bank      = self._ev_bank_key
end

function GrindController:_tableEvOpts(tbl)
    self:_evFrameConsts()
    local ctx = self.ctx or {}
    return { table = tbl, hand_mult = self._ev_hand_mult,
             bankroll = self._ev_bank, overcap = self._ev_overcap,
             table_mult = OutcomeMath.tableEarningsMult(ctx, tbl, self._ev_hand_mult) }
end

function GrindController:tableStats(tbl)
    if not (tbl and tbl.estimateStats) then return nil end
    local rev   = self.display_rev or 0
    local cache = self._tbl_stats
    if not cache or self._tbl_stats_rev ~= rev then
        cache = {}
        self._tbl_stats, self._tbl_stats_rev = cache, rev
    end
    local slot = cache[tbl._id]
    local status_rev = tbl._status_rev or 0
    local n_opps     = #tbl.opponents
    self:_evFrameConsts()
    if slot and slot.status_rev == status_rev and slot.n_opps == n_opps
       and slot.stake_id == tbl.stake_id and slot.gtype_id == tbl.game_type_id
       and evSlotMatches(self, slot, tbl) then
        return slot.value or nil
    end
    local value = tbl:estimateStats(self.ctx, self:_tableEvOpts(tbl)) or false
    if not slot then
        slot = {}
        cache[tbl._id] = slot
    end
    slot.status_rev, slot.n_opps = status_rev, n_opps
    slot.stake_id, slot.gtype_id = tbl.stake_id, tbl.game_type_id
    slot.value = value
    evSlotStamp(self, slot, tbl)
    return value or nil
end

-- The full EV breakdown a table's debug readout wants, same validity rules.
function GrindController:tableDebugStats(tbl)
    if not (tbl and tbl.debugStats) then return nil end
    local rev   = self.display_rev or 0
    local cache = self._tbl_debug
    if not cache or self._tbl_debug_rev ~= rev then
        cache = {}
        self._tbl_debug, self._tbl_debug_rev = cache, rev
    end
    local key = tbl._id
    local slot = cache[key]
    local status_rev = tbl._status_rev or 0
    self:_evFrameConsts()
    if slot and slot.status_rev == status_rev
       and slot.stake_id == tbl.stake_id and slot.gtype_id == tbl.game_type_id
       and evSlotMatches(self, slot, tbl) then
        return slot.value or nil
    end
    local value = tbl:debugStats(self.ctx, self:_tableEvOpts(tbl)) or false
    if not slot then
        slot = {}
        cache[key] = slot
    end
    slot.status_rev, slot.stake_id, slot.gtype_id = status_rev, tbl.stake_id, tbl.game_type_id
    slot.value = value
    evSlotStamp(self, slot, tbl)
    return value or nil
end

-- ─── The ctx revision ──────────────────────────────────────────────────
-- Everything downstream that derives from the effect rollup — the EV
-- readouts, the sidebar's per-stake numbers, the tooltips — is expensive
-- and changes rarely. `ctx_rev` is the one number those caches key on: it
-- moves when the rollup is rebuilt, and when one of the handful of live
-- fields update() keeps on the ctx actually changes value. Writing the same
-- number back every frame must NOT count as a change, or the caches never
-- hit; hence this instead of a plain assignment.
--
-- `gate` names the ctx field that CONSUMES this one (an owned item's
-- effect). A gated field is live: the deal path reads it off the ctx
-- directly and must always see the fresh value, but no readout moves
-- unless the gate is present, so the display revision is left alone
-- when it is not, and folded at most every LIVE_BUMP_SECS when it is
-- (_pollDisplayInputs). Without the gate, a field that changed every
-- frame threw away every EV cache and memo every frame.
GrindController.LIVE_BUMP_SECS = 0.5
-- The live fields and their gates, so a new one cannot quietly become a
-- 20 Hz rebuild: hands_per_second (Framed Diploma), heater_count (Desk
-- Speakers), hu_table_count (the Mirror), lanes_seated (Wall Hook).
GrindController.LIVE_CTX_FIELDS = {
    hands_per_second = "odds_per_hand_per_second",
    heater_count     = "odds_per_heater",
    hu_table_count   = "stack_odds_per_hu_table",
    lanes_seated     = "odds_per_lane_seated",
}
function GrindController:_setCtxField(key, value, gate)
    local ctx = self.ctx
    if not ctx or ctx[key] == value then return end
    ctx[key]     = value
    self.ctx_rev = (self.ctx_rev or 0) + 1
    if gate then
        if ctx[gate] ~= nil then self._live_dirty = true end
        return
    end
    self:_bumpDisplay()
end

function GrindController:invalidateEffects()
    local n_tables = self.pool and self.pool:count() or 0
    -- Board transients the deck kinds read: a pure board (every open
    -- table one game type, else nil) and the lanes whose {chip} bounty
    -- is still unbanked this run.
    local pure
    for _, t in ipairs((self.pool and self.pool.tables) or {}) do
        if pure == nil then pure = t.game_type_id
        elseif pure ~= t.game_type_id then pure = false end
    end
    local unbanked = {}
    local won = self.game.state.stakes_won_this_run or {}
    for _, stake in ipairs(Stakes) do
        for _, gt in ipairs(GameTypes) do
            local key = bountyKey(stake.id, gt.id)
            if not won[key] then unbanked[key] = true end
        end
    end
    self.ctx = self.game.state:computeEffects(self.game.effects, Catalog, RunUpgrades, {
        active_tables_count = n_tables,
        board_pure_gtype    = pure or nil,
        unbanked            = unbanked,
    })
    -- Timed buffs multiply onto the fresh rollup (Cleaning Robot's cursor
    -- overdrive). Multiplicative-only for now; the entry's kind names the
    -- ctx field it scales.
    for _, b in ipairs(self.timed_buffs or {}) do
        self.ctx[b.kind] = (self.ctx[b.kind] or 1) * b.value
    end
    -- Latch the transient ultra-unlock effect into persistent state so the
    -- Ultra band stays available (stakeAvailable reads state.ultra_unlocked).
    -- One-way — any effect granting it makes the unlock permanent.
    if self.ctx.ultra_unlocked then
        self.game.state.ultra_unlocked = true
    end
    -- Same one-way latch for the Desk Plant's 6-Max key.
    if self.ctx.six_max_unlocked then
        self.game.state.six_max_unlocked = true
    end
    -- High Roller Pass: cash games at a stake get +win chance for every
    -- tournament an OPEN tournament table there has finished. Derived
    -- here, from the live pool, so the whole lifecycle is free: close the
    -- tournament and its share is gone on the next rollup, open a cash
    -- table later and it gets the bonus at once. Rollups fire on
    -- buy/close/finish, so the counts are never stale when a hand deals.
    local per = self.ctx.tourney_backing
    if per and per > 0 and self.pool then
        local by_stake
        for _, t in ipairs(self.pool.tables) do
            local n = (t.ko and t.ko.finish_count) or 0
            if n > 0 then
                by_stake = by_stake or {}
                by_stake[t.stake_id] = (by_stake[t.stake_id] or 0) + n
            end
        end
        if by_stake then
            local shifts = self.ctx.win_chance_shifts
            if not shifts then shifts = {}; self.ctx.win_chance_shifts = shifts end
            for stake_id, n in pairs(by_stake) do
                shifts[#shifts + 1] = { amount = per * n, stake = stake_id,
                                        cash_only = true }
            end
        end
    end
    -- A fresh rollup invalidates every cache keyed on the ctx. The banked
    -- set is re-read too: a run reset clears it without passing through the
    -- award sites.
    self.ctx_rev    = (self.ctx_rev or 0) + 1
    self.banked_rev = (self.banked_rev or 0) + 1
    self:_bumpDisplay()
    self:_rebuildProcIndex()
end

-- Maximum concurrent tables. The catalog no longer gates *how many* tables
-- you can open — it gates how many you can open *efficiently*. The hard cap
-- is the visual / sanity bound; the focus mechanic shapes the actual
-- viability curve via currentFocusMult().
function GrindController:tableSlotsCap()
    return Constants.GAMEPLAY.MAX_TABLES
end

-- Focus: the pace every table plays at. Under capacity 1.0; each table
-- beyond it shaves base_penalty * penalty_reduce_mult off, floored at
-- FOCUS_FLOOR. Applied to the hand's PACE (Table:update, via _focus_pace
-- stamped in update), never to the money: an over-cap board plays every
-- hand slower and each hand pays in full, which is the same income as
-- shaving the delta but shows on the felt. Everything the player hears
-- follows it too (focusStrain).
function GrindController:currentFocusMult()
    if self.ctx and self.ctx.focus_penalty_immune then
        return 1.0
    end
    local n        = self.pool:count()
    local cap      = self:currentFocusCapacity()
    local reduce   = (self.ctx and self.ctx.focus_penalty_reduce_mult) or 1
    local penalty  = Constants.GAMEPLAY.FOCUS_BASE_PENALTY * reduce
    local floor_v  = Constants.GAMEPLAY.FOCUS_FLOOR

    local extra = n - cap
    if extra <= 0 then return 1.0 end
    local mult = 1 - penalty * extra
    if mult < floor_v then mult = floor_v end
    return mult
end

-- How far over focus the board is, 0..1: 0 at or under capacity, 1 at
-- the floor. The audio reads this (SoundService.setStrain, fed from
-- main.lua each frame): the music and every sound effect slow and
-- distort by it.
function GrindController:focusStrain()
    local floor_v = Constants.GAMEPLAY.FOCUS_FLOOR
    local s = (1 - self:currentFocusMult()) / (1 - floor_v)
    if s < 0 then s = 0 elseif s > 1 then s = 1 end
    return s
end

-- Effective capacity — base + ctx bonus (no penalty math). THE single source:
-- the penalty math, the overwhelmed counter and the UI all read this, so they
-- cannot disagree about how many tables you can watch.
--
-- Floored, because capacity is a count of tables. Anything that scales run
-- upgrades (the Calculator perk, the Investor deck) multiplies the +1/level
-- that Focus grants, so 3 levels at +15% strength is 3.45 and the top bar
-- cheerfully offered "4 / 7.45 tables". You cannot watch 0.45 of a table. The
-- fractional part still accumulates and pays out when it crosses a whole
-- table, exactly like CursorPool already floors its swarm size.
-- The Swarm deck makes each level of the Focus UPGRADE worth more tables
-- (ctx.focus_level_worth, +1 per deck level): the upgrade's own +1 is in
-- ctx.focus_capacity already, so the deck adds level x worth on top. Max
-- Focus is five levels: nine tables solo, the full 6x6 at deck L5 with
-- the Second Monitor.
function GrindController:currentFocusCapacity()
    local base_cap = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY
    local cap = base_cap + math.floor((self.ctx and self.ctx.focus_capacity) or 0)
    local worth = self.ctx and self.ctx.focus_level_worth or 0
    if worth > 0 then
        local levels = self.game.state.run_upgrade_levels
        cap = cap + (levels and levels.focus or 0) * math.floor(worth)
    end
    return cap
end

-- Is every game type seated somewhere on the board? (The Laminated
-- Blueprint's condition, carried on the on_hand_won event as `all_games`.)
function GrindController:_allGamesOpen()
    local seen = self._seen_gtypes
    if seen then
        for k in pairs(seen) do seen[k] = nil end
    else
        seen = {}
        self._seen_gtypes = seen
    end
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if t.game_type_id and not seen[t.game_type_id] then
            seen[t.game_type_id] = true
            n = n + 1
        end
    end
    return n >= #GameTypes
end

-- ─── The cursor swarm's weather ──────────────────────────────────────
-- services/CursorPool decides WHAT happened on the felt (a clash, a lit
-- cursor's deal) and reports it; the numbers and the punches live here,
-- through the same Table:applyStatus every proc uses, so Dish Soap's
-- resist, refresh-not-stack and the on_status_applied procs (Microwave,
-- Fire Extinguisher) all see a clash like any other tilt.

-- The live table a hit box or panel points at, by id (indices go stale
-- between the draw that built the box and the frame that consumes it).
local function tableFor(self, box)
    if not box then return nil end
    if box.table_id then
        for _, t in ipairs(self.pool.tables) do
            if t._id == box.table_id then return t end
        end
        return nil
    end
    return box.idx and self.pool:get(box.idx) or nil
end

-- A cursor clicked DEAL: the lifetime count the cursor items gate on
-- (Gaming Keyboard, Desk Lamp, Telephone) and the Swarm deck's XP.
function GrindController:onCursorDeal(hb)
    local state = self.game.state
    state.total_cursor_deals = (state.total_cursor_deals or 0) + 1
    self:_grantDeckXp({ type = "cursor_deal" })
end

-- Two cursors clashed over this panel: roll the punch. A tilt by default
-- (Balance.CURSOR_CLASH), a heater with the Cleaning Robot
-- (ctx.cursor_clash_status), every time with its corrupt line
-- (ctx.cursor_clash_chance = 1).
function GrindController:onCursorClash(panel)
    local t = tableFor(self, panel)
    if not t or (t.stack or 0) <= 0 then return end
    local ctx    = self.ctx or {}
    -- The Old Keyboard: the clash is a keystroke, the table deals if it is
    -- idle. Before the punch, so a heater from the robot lands ON the hand
    -- the clash just dealt.
    if ctx.cursor_clash_deals then self:dealIdleTable(t, { by_cursor = true }) end
    local chance = ctx.cursor_clash_chance or Balance.CURSOR_CLASH.chance
    if love.math.random() >= chance then return end
    local status = ctx.cursor_clash_status or "tilt"
    local punch  = Balance.CURSOR_CLASH[status]
    if not punch then return end
    t:applyStatus(status, {
        magnitude = punch.magnitude,
        t         = punch.t,
        source    = (status ~= "tilt") and "cleaning_robot" or nil,
    })
end

-- A lit cursor dealt this table: the fire it carried lands (the Desk Lamp).
function GrindController:onLitCursorDeal(hb)
    local t = tableFor(self, hb)
    if not t or (t.stack or 0) <= 0 then return end
    local fire = Balance.CURSOR_FIRE
    t:applyStatus("heater", { magnitude = fire.magnitude, t = fire.t, source = "desk_lamp" })
end

-- Heartbeat for anything that is true only while a tournament is running.
-- Announces once per live tournament, so a proc's source is the tournament
-- itself and it can target relative to it (its stake, its row, its column).
function GrindController:_tickTournamentAuras(dt)
    self._tourney_t = (self._tourney_t or 0) + (dt or 0)
    if self._tourney_t < TOURNEY_TICK then return end
    self._tourney_t = 0
    for _, t in ipairs(self.pool.tables) do
        if t.ko and t.ko:isPlaying() then
            self:_announce("on_tournament_tick", { table = t })
        end
    end
end

function GrindController:update(dt)
    -- The board's own clock: seconds the felt has actually played. Only
    -- GrindState ticks this, after its sim_frozen return, so a story pause,
    -- the shove, the room and the title all stop it. Every rate below
    -- (boardRate) reads this, never the wall clock, so a pause does not
    -- decay a table's pace or dilute the run's $/min.
    self.clock = (self.clock or 0) + (dt or 0)
    do
        local st  = self.game.state
        local win = RateTicker.window_s or 60
        st.run_elapsed = (st.run_elapsed or 0) + (dt or 0)
        -- A table's recent hands: drop what has fallen out of the window.
        -- Its opened stamp is set here, the first frame it is seen, so the
        -- window it is measured over is "since it was here" wherever it
        -- came from (a buy, a rebuild, a perk).
        for _, t in ipairs(self.pool.tables) do
            t._opened_clock = t._opened_clock or self.clock
            local hc = t._hand_clock
            if hc then
                while hc[1] and self.clock - hc[1] > win do table.remove(hc, 1) end
            end
        end
        -- The earn-rate graph: what the hands won goes into the current
        -- time bucket of state.run_rate_trace (saved with the run). Past
        -- `buckets` of them, neighbours merge and the width doubles, so
        -- the graph always holds the whole run.
        self:_tickRateTrace(st, dt or 0)
    end
    -- Proc budget is per frame too (services/ProcRegistry).
    if self.game.procs then self.game.procs:beginFrame() end
    self:_pollDisplayInputs()
    self:_rebuildPoolSummary()
    -- The Mirror reads how many Heads-Up tables are open when a hand is
    -- dealt (OutcomeMath.buildOutcome); kept live on the ctx rather than
    -- baked into the rollup, so opening a table needs no rebuild.
    -- Desk Speakers read how many heaters are burning the same way.
    if self.ctx then
        local n, burning = 0, 0
        for _, t in ipairs(self.pool.tables) do
            if t.game_type_id == "hu" then n = n + 1 end
            if t.hasStatus and t:hasStatus("heater") then burning = burning + 1 end
            -- Handheld: a Zoom loss latched a fast fold; deal it the
            -- moment the felt is clear (a punch's own auto-deal wins:
            -- the latch is dropped when the table dealt itself).
            if t._fast_fold_pending and t.state == "idle" then
                t._fast_fold_pending = nil
                if self.ctx.zoom_fast_fold and self:dealIdleTable(t, { by_cursor = t._swarm_deal }) then
                    self:itemFired("zoom_fast_fold", t)
                end
            elseif t._fast_fold_pending and t.state ~= "settling" then
                t._fast_fold_pending = nil
            end
        end
        self:_setCtxField("hu_table_count", n, "stack_odds_per_hu_table")
        self:_setCtxField("heater_count", burning, "odds_per_heater")
        -- Focus: every table plays at the board's focus factor (Table:update
        -- folds it into the pace). Stamped per frame like the Receipt
        -- Printer's count below, so a table opening or closing moves every
        -- table's pace the same frame.
        local focus_pace = self:currentFocusMult()
        for _, t in ipairs(self.pool.tables) do t._focus_pace = focus_pace end
        -- Every table over the cap is a moment: the overload sound on
        -- each step further over, pitched lower each time (the rail's
        -- alarm and the frame kick on the same frame).
        local focus_extra = math.max(0, self.pool:count() - self:currentFocusCapacity())
        if focus_extra > (self._focus_extra or 0) then
            self:_playNamed("focus_overload", { pitch = math.max(0.5, 1 - 0.08 * (focus_extra - 1)) })
        end
        self._focus_extra = focus_extra
        -- The Receipt Printer: each Zoom's count of adjacent Zooms.
        if self.ctx.zoom_block_pace then
            local cells = self._zoom_cells
            if cells then
                for k in pairs(cells) do cells[k] = nil end
            else
                cells = {}
                self._zoom_cells = cells
            end
            for _, t in ipairs(self.pool.tables) do
                if t.game_type_id == "zoom" then cells[t.slot or -1] = true end
            end
            for _, t in ipairs(self.pool.tables) do
                if t.game_type_id == "zoom" then
                    local r, c = TableGrid.unpack(t.slot or 0)
                    local k = 0
                    for _, d in ipairs(NEIGHBOUR_DIRS) do
                        if cells[TableGrid.pack(r + d[1], c + d[2])] then k = k + 1 end
                    end
                    t._zoom_neighbours = k
                end
            end
        end
        -- The stats shelf's board reads: stakes seated (Wall Hanger), and
        -- per table the empty cells beside it (Yellow Sticky Note) and
        -- whether nothing sits on any side (Throw Pillow). A 6-Max reads
        -- as empty with the Comfort Bed. Empty means an unoccupied cell
        -- INSIDE the board's bounds; past the edge is nothing, which counts
        -- for "nothing adjacent" but never as elbow room.
        do
            -- Scratch tables, wiped and reused: this block ran every frame
            -- and allocated three tables plus a lane string per table.
            local sc = self._shelf_scratch
            if not sc then
                sc = { lanes = {}, occupied = {}, slots = {} }
                self._shelf_scratch = sc
            end
            local lanes, occupied, slots, tables = sc.lanes, sc.occupied, sc.slots, self.pool.tables
            for k in pairs(occupied) do occupied[k] = nil end
            for i = #slots, 1, -1 do slots[i] = nil end
            local six_empty = self.ctx.six_max_counts_empty
            local n_lanes = 0
            for _, t in ipairs(tables) do
                -- The Wall Hook counts table TYPES: a stake at a game type.
                -- Two NL2 Heads-Up tables are one lane; NL2 Heads-Up and
                -- NL2 Zoom are two. A two-level map, no key string.
                local by_stake = lanes[t.stake_id or ""]
                if not by_stake then by_stake = {}; lanes[t.stake_id or ""] = by_stake end
                local g = t.game_type_id or ""
                if not by_stake[g] then n_lanes = n_lanes + 1 end
                by_stake[g] = true
                occupied[t.slot or -1] = t
                slots[#slots + 1] = t.slot or 0
            end
            for _, by_stake in pairs(lanes) do
                for g in pairs(by_stake) do by_stake[g] = nil end
            end
            self:_setCtxField("lanes_seated", n_lanes, "odds_per_lane_seated")
            local cols, rows = TableGrid.bounds(slots)
            for _, t in ipairs(tables) do
                local r, c = TableGrid.unpack(t.slot or 0)
                local empties, neighbours = 0, 0
                for _, d in ipairs(NEIGHBOUR_DIRS) do
                    local rr, cc = r + d[1], c + d[2]
                    local o = occupied[TableGrid.pack(rr, cc)]
                    local counts_empty = (o == nil) or (six_empty and o.game_type_id == "six_max")
                    if not counts_empty then neighbours = neighbours + 1 end
                    local inside = rr >= 0 and rr < rows and cc >= 0 and cc < cols
                    if inside and counts_empty then empties = empties + 1 end
                end
                t._empty_adjacent = empties
                t._lonely = (neighbours == 0)
            end
        end
        -- The Framed Diploma: hands the board finished in the last second.
        local times = self._hand_times
        if times then
            local now = love.timer.getTime()
            while times[1] and now - times[1] > 1 do table.remove(times, 1) end
            self:_setCtxField("hands_per_second", #times, "odds_per_hand_per_second")
        end
    end
    self:_tickGtypeUnlocks()
    self:_tickTimedBuffs(dt)
    self:_tickTournamentAuras(dt)
    -- Shockwaves in flight from a slam or a shove.
    self:_tickImpacts(dt)
    self:_tickHeaterSounds()

    local resolutions = self.pool:update(dt, self.ctx)

    -- Pending buy-in bursts: addTable / first-frame-after-add can't emit
    -- because the new table has no panel position yet. Resolve once the
    -- view has registered the table's "you" anchor.
    for _, t in ipairs(self.pool.tables) do
        if t._pending_buyin
           and AnchorRegistry.get(TableModel.anchorKey(t, "you"))
           and AnchorRegistry.get("bankroll") then
            self:_emitBuyInChips(t, t._pending_buyin)
            t._pending_buyin = nil
        end
    end

    -- Pending cash-outs: tables flagged for close while mid-hand. Finalise
    -- the moment they return to idle. Iterate in reverse so removal-driven
    -- index shifts don't skip entries.
    -- A tournament that has just settled still holds its payout until the
    -- drain below reads it; closing it first threw the payout (and the
    -- {chip} on a win) away. Such a table waits one tick.
    for i = #self.pool.tables, 1, -1 do
        local t = self.pool.tables[i]
        if t and t.pending_close and t.state == "idle"
           and not (t.ko and t.ko.pending_payout ~= nil) then
            self:_finalizeRemove(i)
        end
    end

    -- Tournament payout drain. KoSession.settle stashes a $ amount on the
    -- table; we apply it to bankroll, emit a chip burst, and reset the
    -- per-tournament counter so the player can rebuy for another run.
    for _, t in ipairs(self.pool.tables) do
        local payout = t.ko and t.ko:drainPayout()
        if payout ~= nil then
            -- A finished tournament just raised this table's finish count;
            -- re-derive the High Roller Pass backing (invalidateEffects
            -- reads the counts from the pool).
            self:invalidateEffects()
            local hands_cleared = t.ko.hands_won
            -- Win detection: chip-stack KO, finish 1st.
            local gtype = Lookups.findById(GameTypes, t.game_type_id)
            local is_win = t.ko and t.ko.last_finish == 1
                           and gtype and gtype.chip_stack_table or false
            local center = AnchorRegistry.get(TableModel.anchorKey(t, "center"))
                           or { 0, 0 }

            if payout > 0 then
                self.game.state.bankroll = self.game.state.bankroll + payout
                self:_emitKoPayoutChips(t, payout)
            end
            -- The rail's earn rate: a tournament's cash lands here, not
            -- per hand (those deltas are informational), so its net over
            -- the seat price is what the run's winnings see.
            do
                local st_ = Lookups.findById(Stakes, t.stake_id)
                self.game.state.run_hand_net = (self.game.state.run_hand_net or 0)
                    + payout - ((st_ and st_.buy_in) or 0)
            end
            if Constants.DEBUG.HAND_ANALYTICS then
                local ko_stake = Lookups.findById(Stakes, t.stake_id)
                HandAnalytics.recordHand({
                    t_start      = love.timer.getTime(),
                    duration     = 0,
                    won          = is_win,
                    delta        = payout,
                    tier         = "ko_payout",
                    stake_id     = t.stake_id,
                    stake_bb     = ko_stake and ko_stake.bb or nil,
                    game_type_id = t.game_type_id,
                    demo         = Constants.DEMO,
                    hands_played = hands_cleared,
                })
            end

            if is_win then
                -- Chip bounty: first stack-equivalent per (stake, gtype) per
                -- run. Tournaments only "stack" once — on the win — so it's
                -- banked here, not on the per-hand cash path. Rides into the
                -- celebration block below.
                local state = self.game.state
                state.total_ko_wins = (state.total_ko_wins or 0) + 1
                local cap = 1
                local key = bountyKey(t.stake_id, t.game_type_id)
                local cur = state.stakes_won_this_run[key]
                local count = 0
                if cur == true then
                    count = 1
                elseif type(cur) == "number" then
                    count = cur
                end
                local award = 0
                if count < cap then
                    state.stakes_won_this_run[key] = count + 1
                    self.banked_rev = (self.banked_rev or 0) + 1
                    -- Same award math as the cash stack path (incl.
                    -- chip_award_mult AND Pen's flat bonus — this used to
                    -- hand-roll the formula and dropped the Pen add).
                    award = self:bountyAward(t.stake_id, t.game_type_id, { roll = true })
                    if award > 0 then
                        -- Dogs Playing Poker: the run's first bounty pays +bonus.
                        if not state.first_bounty_this_run then
                            state.first_bounty_this_run = true
                            award = award + ((self.ctx and self.ctx.first_bounty_bonus) or 0)
                            if (self.ctx and self.ctx.first_bounty_bonus or 0) > 0 then self:itemFired("first_bounty_bonus", t) end
                        end
                        self:itemFired("stack_chip_add", t)
                        self:itemFired("chip_award_mult", t)
                        state.chips_this_run = state.chips_this_run + award
                        -- Bounty Hunter levels on chips banked; its Stack
                        -- shift keys on which lanes are still unbanked,
                        -- so the rollup has to see this bank now.
                        if Decks.systemUnlocked(state) then
                            self:_grantDeckXp({ type = "bounty", n = award })
                        end
                        self:invalidateEffects()
                        state.total_chips_banked = (state.total_chips_banked or 0) + award
                        self:_recordBountyPaid(key, award)
                    end
                else
                    -- Copy Machine: the run's first denied bounty banks anyway.
                    if self.ctx and self.ctx.copy_first_denied and not state.denied_copied_this_run then
                        state.denied_copied_this_run = true
                        self:itemFired("copy_first_denied", t)
                        local cp = self:bountyAward(t.stake_id, t.game_type_id, { roll = true })
                        if cp > 0 then
                            state.chips_this_run = state.chips_this_run + cp
                            state.total_chips_banked = (state.total_chips_banked or 0) + cp
                            self:_recordBountyPaid(key, cp)
                        end
                    else
                        -- Repeat tournament win on an already-banked combo:
                        -- the same "denied" event the cash path counts (feeds
                        -- the chip_denied tutorial hint).
                        state.total_denied_stacks = (state.total_denied_stacks or 0) + 1
                    end
                end

                -- Stack-grade table FX + the payout detonating — the KO is
                -- the top of the ladder, so the win gets the full spectacle.
                -- 1.5× the standard chip count for the same reason.
                local fx = FeedbackIntensity.stack
                t.shake_trauma       = math.max(t.shake_trauma or 0, fx.shake)
                t.vignette_kind      = "good"
                t.vignette_alpha     = math.max(t.vignette_alpha or 0, fx.vignette)
                t.border_pulse_t     = 1.0
                t.border_pulse_color = "good"
                t.glow_t             = math.max(t.glow_t or 0, fx.glow or 1.0)
                self:_emitAmountExplosion(center, payout, t.stake_id)

                -- ONE multi-line celebration float anchored at the table center.
                -- The renderer stacks the lines itself, so there are no manual
                -- per-float offsets to collide or drift off the top of view.
                local lg_h = self.game.fonts.lg:getHeight()
                local msg  = "TOURNAMENT WON"
                if payout > 0 then msg = msg .. "\n" .. Format.moneySigned(payout) end
                if award  > 0 then msg = msg .. string.format("\n+%d {chip}", award) end
                self.game.floating_text.emit(msg, center[1], center[2],
                    { scale = 1.4, font = "lg", color_token = "won",
                      lifetime = 2.6, arc_y = -math.floor(lg_h * 0.5),
                      fit_table = t })
                self:_playNamed("tournament_won")
            elseif payout > 0 then
                -- Partial payout (busted before the win) — a plain cash float.
                self.game.floating_text.emit(Format.moneySigned(payout),
                    center[1], center[2], { fit_table = t })
            else
                -- Out of the money. The most common way a tournament ends
                -- and, until now, the only outcome in the game that said
                -- nothing at all. It is the tilt beat.
                self.game.floating_text.emit("BUSTED",
                    center[1], center[2],
                    { color_token = "error", lifetime = 1.6, fit_table = t })
                self:_playNamed("table_busted")
                self:_announce("on_tournament_miss", { table = t, n = 1 })
            end

            if is_win then
                self:_announce("on_tournament_win", { table = t, n = 1 })
            end

            t.ko.hands_won = 0
        end
    end

    if #resolutions == 0 then return end

    local state      = self.game.state
    for _, r in ipairs(resolutions) do
        -- Focus does not touch the delta: an over-cap board plays every
        -- hand slower (Table:update's pace), and the hand pays in full.
        -- Corrupted Gaming Chair: no focus penalty, but every table past
        -- the cap loses bigger.
        if r.delta < 0 and self.ctx and self.ctx.overcap_loss_mult
           and self.pool:count() > self:currentFocusCapacity() then
            r.delta = r.delta * self.ctx.overcap_loss_mult
        end

        -- Bank capstone: every hand's magnitude times the player's actual
        -- bankroll multiplier (the BANK number), read live here so the
        -- effects cache never has to carry live bankroll. The card says
        -- "multiplied by your bankroll multiplier" and means it.
        local sc = self.ctx and self.ctx.earnings_scale_by_bankroll
        if sc then
            local m = ShoveRate.bankrollMultiplier(self.game.state.bankroll)
            if type(sc) == "table" then
                if sc.cap then m = math.min(m, sc.cap) end
                if sc.wins_only and r.delta < 0 then m = 1 end
            end
            r.delta = r.delta * m
        end

        -- Once-per-run loss voids: The Fridge (first stack-tier stack loss)
        -- then Rubber Duck (first loss of any size). Zero the delta before it
        -- lands on stack/bankroll, so the beat simply didn't happen. Cash
        -- tables only — an KO r.delta is informational (the bust is already
        -- in tbl.stack), so voiding it there just wastes the once-per-run use.
        if r.delta < 0 and not r.chip_stack_table and self.ctx then
            if self.ctx.void_first_stack_loss and r.tier == "stack"
               and not state.first_stack_loss_voided_this_run then
                state.first_stack_loss_voided_this_run = true
                r.delta = 0
                self:itemFired("void_first_stack_loss", r.table)
            elseif self.ctx.void_first_loss and not state.first_loss_voided_this_run then
                state.first_loss_voided_this_run = true
                r.delta = 0
                self:itemFired("void_first_loss", r.table)
            end
        end

        -- Wins/losses land on the table's stack first. Above the 100bb
        -- cap (= stake.buy_in) the surplus spills to bankroll; below
        -- zero the loss clamps to whatever's actually on the table so
        -- the player can't go negative just from a brutal hand.
        --
        -- Chip-stack tables (8-max KO): tbl.stack has already been
        -- updated by Table:_reconcileChipFlow when the script's
        -- pot_push fired, and r.delta carries the resulting net flow.
        -- Skip the stack write so we don't double-count, and skip the
        -- buy-in cap entirely (a winning seat can hold up to the full
        -- 800bb chip pool, far above the 100bb buy-in).
        local tbl   = r.table
        local stake = tbl and Lookups.findById(Stakes,tbl.stake_id)
        local cap   = (stake and stake.buy_in) or 0
        local overflow_amount = 0
        if tbl and r.chip_stack_table then
            -- No-op: stack already reconciled. r.delta is informational.
        elseif tbl and state.shove_r2_won and stake and stake.band == "ultra"
               and r.delta < 0 and r.tier == "stack" then
            -- A STACK loss at Ultra is the underflow. It is not a number you
            -- creep under; losing that much at once breaks the count. The
            -- seat empties and the bankroll lands below the threshold
            -- whatever it was before, whether or not the loss exceeded the
            -- stack (80-100 bb of a 100 bb seat would not have).
            local threshold = Constants.GAMEPLAY.UNDERFLOW_THRESHOLD or -100000000000
            tbl.stack = 0
            local was_under = ShoveRate.underflowed(state.bankroll)
            if state.bankroll > threshold - 1 then
                state.bankroll = threshold - 1
            end
            -- The break, once: not again on a later Ultra stack loss.
            if not was_under then
                self:_playNamed("underflow")
                self:_playNamed("house_stinger")
            end
        elseif tbl then
            local new_stack = tbl.stack + r.delta
            if new_stack > cap then
                overflow_amount = new_stack - cap
                tbl.stack = cap
                state.bankroll = state.bankroll + overflow_amount
            elseif new_stack < 0 then
                if state.shove_r2_won and stake and stake.band == "ultra" then
                    -- A smaller Ultra loss than the seat holds: the excess
                    -- comes off the bankroll (it may go negative). The stack
                    -- loss itself is handled above.
                    local excess_loss = -new_stack
                    tbl.stack = 0
                    state.bankroll = state.bankroll - excess_loss
                else
                    r.delta = -tbl.stack
                    tbl.stack = 0
                    -- The table is busted: its stack is gone. Counted for
                    -- catalog gates, and The Sink drains part of the buy-in
                    -- back to bankroll (bust_refund_pct).
                    state.total_busts = (state.total_busts or 0) + 1
                    local refund_pct = (self.ctx and self.ctx.bust_refund_pct) or 0
                    if refund_pct > 0 and cap > 0 then
                        state.bankroll = state.bankroll + cap * refund_pct
                        self:itemFired("bust_refund_pct", tbl)
                    end
                end
            else
                tbl.stack = new_stack
            end
        else
            -- Defensive fallback: no table found, route to bankroll
            -- with the same negative clamp.
            local new_bankroll = state.bankroll + r.delta
            if new_bankroll < 0 then
                if not state.shove_r2_won then
                    r.delta = -state.bankroll
                    new_bankroll = 0
                end
            end
            state.bankroll = new_bankroll
        end

        -- Analytics: record hand timing and outcome. The start timestamp was
        -- stamped by dealHand() or by the auto-deal re-stamp below. After
        -- recording, we check whether the table already re-entered dealing
        -- (auto-deal KO path fires inside Table:update before we get here)
        -- and re-stamp so the next resolution has a valid duration.
        if Constants.DEBUG.HAND_ANALYTICS and tbl then
            if tbl._hand_start_t then
                HandAnalytics.recordHand({
                    t_start        = tbl._hand_start_t,
                    duration       = love.timer.getTime() - tbl._hand_start_t,
                    won            = r.won,
                    delta          = r.delta,
                    tier           = r.tier,
                    stake_id       = tbl.stake_id,
                    stake_bb       = stake and stake.bb or nil,
                    game_type_id   = tbl.game_type_id,
                    hand_pace_mult = (self.ctx and self.ctx.hand_pace_mult) or 1,
                    deck_id        = self.game.state.active_deck_id,
                    demo           = Constants.DEMO,
                })
                tbl._hand_start_t = nil
            end
            if tbl.state ~= "idle" then
                tbl._hand_start_t = love.timer.getTime()
            end
        end

        -- Floater label & color. Two flavors:
        --   • cash hand               → "+/-$X.XX"
        --   • chip-stack KO hand     → "+/-Nbb" (no cash until placement)
        -- Tournament cash payout fires its own "+$X.XX" floater from the
        -- drainPayout block above when the tournament ends.
        local label
        local floater_opts_override = nil
        -- Every result carries its tier GLYPH inline, beside the amount
        -- on the same line — {w:small} .. {w:stack} for a win, {l:small}
        -- .. {l:stack} for a loss, via IconText (the floater renderer
        -- routes any {…} line through it), NEVER the tier words. The tier
        -- key is the token.
        local tier_glyph = ""
        if r.tier then
            tier_glyph = " {" .. (((r.delta or 0) >= 0) and "w" or "l") .. ":" .. r.tier .. "}"
        end
        if r.chip_stack_table then
            local stake = tbl and Lookups.findById(Stakes, tbl.stake_id)
            local bb_val = (stake and stake.bb and stake.bb > 0) and stake.bb or 1
            local bb_delta = (r.delta or 0) / bb_val
            if bb_delta >= 0 then
                label = string.format("+%dbb", math.floor(bb_delta + 0.5)) .. tier_glyph
            else
                label = string.format("-%dbb", math.floor(-bb_delta + 0.5)) .. tier_glyph
                floater_opts_override = { color_token = "error" }
            end
        elseif r.delta >= 0 then
            label = Format.moneySigned(r.delta) .. tier_glyph
        else
            label = Format.moneySigned(r.delta) .. tier_glyph
            -- Loss: override the data-file's amber default with red so
            -- losses read correctly. Without this every tier picks up
            -- color_token="amber" and "-$X.XX" floaters render in gold
            -- like the wins.
            floater_opts_override = { color_token = "error" }
        end

        local ko_final = false

        -- Tier-scaled floater opts from data. Small = small + compact;
        -- stack = huge + arcing. The data layer paints wins amber
        -- (it pops on green felt); the per-emit overrides above route
        -- losses to red (cash and KO both).
        local intensity_for_floater = FeedbackIntensity[r.tier] or FeedbackIntensity.small
        local floater_opts = intensity_for_floater.floater
        -- Spawn at the panel center if the anchor exists; falls back to
        -- (r.x, r.y) which is the panel's top-left corner. The center
        -- read sells the float as "above this hand" instead of off in
        -- the corner.
        local cxy   = (tbl and AnchorRegistry.get(TableModel.anchorKey(tbl, "center")))
        local fx    = cxy and cxy[1] or (r.x or 0)
        local fy    = cxy and cxy[2] or (r.y or 0)
        -- Skip the winning hand's per-hand float — the TOURNAMENT WON banner
        -- from the payout-drain block stands in for it (avoids the pile-up).
        if not ko_final then
            -- One merge, into a table reused across resolutions: the
            -- intensity preset, then the tier override, then the per-table
            -- settle. This was two full copies of the preset per hand.
            local opts_copy = self._floater_opts
            if not opts_copy then opts_copy = {}; self._floater_opts = opts_copy end
            for k in pairs(opts_copy) do opts_copy[k] = nil end
            for k, v in pairs(floater_opts) do opts_copy[k] = v end
            if floater_opts_override then
                for k, v in pairs(floater_opts_override) do opts_copy[k] = v end
            end
            opts_copy.table = tbl
            -- Pop-then-settle: the number pops at the panel center at
            -- full celebration size (no slow drift — arc killed), holds
            -- a beat, then drops to its resting font and slides to the
            -- money corner. ONE rest spot for wins and losses, and it is
            -- panel-relative, not seat-relative: the left flank beside
            -- your hole cards, above the pile. Seat-relative rest spots
            -- were tried twice and both collided — the winner's seat
            -- holds revealed cards + the pill (and on HU the seat is
            -- CENTERED, which parked the number on the DEAL button).
            -- This flank is empty on every layout: hole cards center,
            -- pile in the corner below, EV on the right. The renderer
            -- also plates parked floats, so color never fights the felt.
            if tbl then
                opts_copy.arc_y         = 0
                opts_copy.settle_anchor = TableModel.anchorKey(tbl, "center")
                opts_copy.settle_fx     = -0.30   -- fraction of panel w from center
                opts_copy.settle_fy     =  0.26   -- fraction of panel h from center
            end
            -- Scale the vertical drift so the text lands at a consistent
            -- relative position regardless of panel size.  The data-layer
            -- arc_y values were authored for a ~390 px-tall panel; scale
            -- proportionally so a 200 px panel gets half the drift and a
            -- 600 px panel gets more.  Clamped to keep it sane.
            local panel_h = cxy and cxy[4] or 390
            local drift_scale = math.max(0.4, math.min(1.6, panel_h / 390))
            opts_copy.arc_y = (opts_copy.arc_y or -42) * drift_scale
            self.game.floating_text.emit(label, fx, fy, opts_copy)
        end

        -- Chip-flight burst on resolution. Three flavors:
        --   • win  → pot to YOU stack
        --   • loss → pot off-screen (chips fly off the bottom)
        --   • overflow (YOU stack hit cap) → YOU to bankroll pile
        self:_emitResolutionChips(r, tbl, overflow_amount)

        -- Tier-scaled resolution FX. Every settle now produces feedback;
        -- magnitude per tier comes from data/feedback_intensity.lua so
        -- there's no `if tier == "stack"` branch here. Small resolutions
        -- get a faint border pulse + small slam dip; stacks get full
        -- shake + vignette + bright border + biggest slam.
        if tbl then
            local intensity = FeedbackIntensity[r.tier] or FeedbackIntensity.small
            local is_win    = r.delta > 0
            tbl.shake_trauma       = math.max(tbl.shake_trauma or 0, intensity.shake)
            if intensity.vignette > 0 then
                tbl.vignette_kind  = is_win and "good" or "bad"
                tbl.vignette_alpha = math.max(tbl.vignette_alpha or 0, intensity.vignette)
            end
            tbl.border_pulse_t     = math.max(tbl.border_pulse_t or 0, intensity.border_pulse)
            tbl.border_pulse_color = is_win and "good" or "bad"
            -- Border-pulse SFX marker — short ding tied to the colored
            -- border flash. Volume scales with the same border_pulse
            -- intensity so Small resolutions barely register and Stacks
            -- ring out. Stacks with the existing pot_won_/pot_lost_ tier
            -- sound that fires from the state-transition handler.
            local pulse_sound = is_win and "border_pulse_win" or "border_pulse_loss"
            self:_playNamed(pulse_sound, { volume_mult = intensity.border_pulse })
            -- Spectacle layer: stack wins only. Radial-glow shader on
            -- the panel + the pot detonating out of its own pile. Both
            -- gated on intensity fields existing (only stack defines
            -- them in data/feedback_intensity.lua) so future tiers can
            -- opt in by adding the same fields.
            if is_win and intensity.glow and intensity.glow > 0 then
                tbl.glow_t = math.max(tbl.glow_t or 0, intensity.glow)
            end
            -- The pot detonates. Raised as a per-table FX flag exactly like
            -- shake_trauma / glow_t above, because only the view knows
            -- where the pile actually is — views/TablePanel:drawPotLabel
            -- consumes this, blows apart the pile it was about to draw,
            -- and stops drawing it.
            if is_win and intensity.chip_burst then
                tbl.pot_explode_pending = true
            end
        end

        -- Chip-bounty: first stack-tier win at this (stake, game_type)
        -- combo this run awards the stake's chip_award. Locked in until
        -- prestige clears it. Non-stack wins, losing hands, and
        -- subsequent stack wins at the same combo do nothing.
        --
        -- The Pen catalog item (stack_chip_add) adds a flat +N to the
        -- bounty award — i.e. each tier's payout becomes worth +1 chip
        -- more when Pen is owned. So a tier whose chip_award is 2 pays
        -- 3 with Pen; a tier whose award is 5 pays 6. The bonus rides
        -- the bounty so it fires exactly when the bounty fires (once
        -- per (stake, gtype) per run), never on subsequent stacks.
        --
        -- Chip-stack tournaments skip this path — their bounty fires
        -- once per run on a 1st-place tournament win, gated in the
        -- drainPayout block above. Without this skip, a stack pot
        -- mid-tournament would bank the (stake, ko) bounty before
        -- the player has actually won the tournament.
        -- Runs before the bounty check so a banking hand's reset (below)
        -- leaves this at 0, not 1. Drives the tutorial's shove-stall hint.

        -- Receipt Printer: a {stack} anywhere settles every Zoom table on
        -- the spot. Appending to `resolutions` mid-iteration is deliberate
        -- — ipairs walks until it hits nil, so the swept hands run through
        -- this exact loop body (bounties, counters, floaters, analytics)
        -- with no duplicated logic and no recursion. A swept hand that is
        -- itself a {stack} appends the next wave the same way, which is
        -- how cascades chain.
        --
        -- WINS only: a stack LOSS setting off your engine would read as
        -- being rewarded for getting stacked. Flip the `r.delta > 0` here
        -- if that ever seems worth trying.
        -- Knockouts. Fired ONCE per hand carrying the seat count, not once
        -- per seat: a scheduled multi-bust puts two seats out on the same
        -- hand, and firing twice would be a no-op for a refreshing status
        -- while double-paying a chance-based one. Payloads that should
        -- scale read event.n instead.
        if r.busted_seats then
            -- The view's KO moment: one intent per eliminated seat (the
            -- announce below stays once-per-hand for the procs). Not a
            -- chip burst — GrindView routes it to the seat flash, the KO
            -- floater and the knock.
            for _, seat in ipairs(r.busted_seats) do
                self.pending_bursts[#self.pending_bursts + 1] = {
                    kind = "seat_ko", table = r.table, seat = seat,
                }
            end
            self:_announce("on_ko", {
                table = r.table, n = #r.busted_seats, out = resolutions,
                busted_total = r.busted_total,
                seats = r.busted_seats,
            })
            -- Circuit Pro levels on knockouts.
            if Decks.systemUnlocked(state) then
                self:_grantDeckXp({ type = "ko", n = #r.busted_seats })
            end
        end
        -- `not r.flipped` throughout: a hand whose side a heater or tilt
        -- FLIPPED keeps its tier for the felt (the cards played out), but a
        -- manufactured stack is not the chip event — the dists never
        -- rolled it. Without this gate a heater converts every stack-tier
        -- cooler into a bounty + cascade, and a tilt-flipped "cooler" feeds
        -- the tilt procs that caused it.
        if r.delta > 0 and r.tier == "stack" and not r.chip_stack_table and not r.flipped then
            self:_announce("on_stack_win", { table = r.table, out = resolutions })
        end
        if r.delta < 0 and r.tier == "stack" and not r.chip_stack_table and not r.flipped then
            self:_announce("on_stack_loss", { table = r.table, out = resolutions })
        end

        if r.delta > 0 and r.tier == "stack" and not r.chip_stack_table and not r.flipped then
            local tbl = r.table
            if tbl then
                local cap = 1
                local key = bountyKey(tbl.stake_id, tbl.game_type_id)
                local cur = state.stakes_won_this_run[key]
                local count = 0
                if cur == true then
                    count = 1
                elseif type(cur) == "number" then
                    count = cur
                end
                if count < cap then
                    state.stakes_won_this_run[key] = count + 1
                    self.banked_rev = (self.banked_rev or 0) + 1
                    local award = self:bountyAward(tbl.stake_id, tbl.game_type_id, { roll = true })
                    if award > 0 then
                        -- Dogs Playing Poker: the run's first bounty pays +bonus.
                        if not state.first_bounty_this_run then
                            state.first_bounty_this_run = true
                            award = award + ((self.ctx and self.ctx.first_bounty_bonus) or 0)
                            if (self.ctx and self.ctx.first_bounty_bonus or 0) > 0 then self:itemFired("first_bounty_bonus", tbl) end
                        end
                        self:itemFired("stack_chip_add", tbl)
                        self:itemFired("chip_award_mult", tbl)
                        -- Pending chips — commit to state.chips at SHOVE
                        -- time. The float is the satisfying "you locked a
                        -- bounty" signal; the top bar's chip figure stays
                        -- static until shove pulls the trigger on banking.
                        state.chips_this_run = state.chips_this_run + award
                        -- Bounty Hunter levels on chips banked; its Stack
                        -- shift keys on which lanes are still unbanked,
                        -- so the rollup has to see this bank now.
                        if Decks.systemUnlocked(state) then
                            self:_grantDeckXp({ type = "bounty", n = award })
                        end
                        self:invalidateEffects()
                        state.total_chips_banked = (state.total_chips_banked or 0) + award
                        self:_recordBountyPaid(key, award)
                        self.game.floating_text.emit(
                            string.format("+%d {chip}", award),
                            r.x, (r.y or 0) - 28)
                    end
                else
                    -- Copy Machine: the run's first denied bounty banks anyway.
                    -- Corrupted: every denied bounty banks with a chance.
                    local copies = self.ctx and self.ctx.copy_first_denied and not state.denied_copied_this_run
                    local copy_chance = self.ctx and self.ctx.copy_denied_chance or 0
                    if not copies and copy_chance > 0 and love.math.random() < copy_chance then
                        copies = true
                    end
                    if copies then
                        state.denied_copied_this_run = true
                        self:itemFired("copy_first_denied", tbl)
                        self:itemFired("copy_denied_chance", tbl)
                        local cp = self:bountyAward(tbl.stake_id, tbl.game_type_id, { roll = true })
                        if cp > 0 then
                            state.chips_this_run = state.chips_this_run + cp
                            state.total_chips_banked = (state.total_chips_banked or 0) + cp
                            self:_recordBountyPaid(key, cp)
                            self.game.floating_text.emit(
                                string.format("+%d {chip}", cp),
                                r.x, (r.y or 0) - 28)
                        end
                    else
                        -- Denied: this (stake, gtype) already paid its bounty
                        -- this run. Counted (unconditionally, meta-side) so
                        -- the tutorial can explain the once-per-run rule the
                        -- first time it bites.
                        state.total_denied_stacks = (state.total_denied_stacks or 0) + 1
                    end
                end
            end
        end

        -- Anti-chip award: a stack loss (r.delta < 0 and r.tier == "stack")
        -- at ANY stake during Act 3, once per stake x game type per run,
        -- alongside the {chip} for winning one. The award ladder is inverse
        -- (antiBountyAward, from ladder position): T1 pays most because a maxed
        -- build almost never loses a stack there.
        if r.delta < 0 and r.tier == "stack" and not r.chip_stack_table then
            local tbl = r.table
            if tbl then
                local stake = Lookups.findById(Stakes, tbl.stake_id)
                if stake and state.shove_r2_won then
                    local cap = 1
                    local key = bountyKey(tbl.stake_id, tbl.game_type_id)
                    state.anti_stakes_won_this_run = state.anti_stakes_won_this_run or {}
                    local cur = state.anti_stakes_won_this_run[key]
                    local count = (cur == true and 1) or 0
                    if count < cap then
                        state.anti_stakes_won_this_run[key] = true
                        local award = self:antiBountyAward(tbl.stake_id)
                        -- Corrupted Worry Stone: every anti pays more.
                        -- Corrupted Fridge: the run's first pays more still.
                        if self.ctx then
                            award = math.floor(award * (self.ctx.anti_award_mult or 1) + 0.5)
                            if not state.first_anti_this_run then
                                state.first_anti_this_run = true
                                award = math.floor(award * (self.ctx.first_anti_mult or 1) + 0.5)
                            end
                        end
                        -- An anti-chip banking: the chip bank sound, corrupted.
                        self:_playNamed("chip_land_bankroll", { damaged = true })
                        if award > 0 then
                            state.anti_chips_this_run = (state.anti_chips_this_run or 0) + award
                            self.game.floating_text.emit(
                                string.format("+%d {achip}", award),
                                r.x, (r.y or 0) - 28)
                        end
                    end
                end
            end
        end

        -- ── Ungated counters ────────────────────────────────────────────
        -- Unconditional, unlike the deck lifetime counters below (those
        -- start at zero when decks unlock). These drive tutorial-hint
        -- pacing (models/hint_rules.lua "hands_played") AND every catalog
        -- unlock gate — a catalog gate must be reachable in Act 1, which
        -- the deck-gated counters are not.
        local n_tables = self.pool:count()
        local gtype_id = tbl and tbl.game_type_id
        local focus_cap = self:currentFocusCapacity()
        -- Copy Machine: a Zoom hand counts as two, everywhere a hand is
        -- counted (and in the hand-based deck XP rules, via hand_units).
        local hand_units = (gtype_id == "zoom" and self.ctx and self.ctx.zoom_hands_count_twice) and 2 or 1
        -- Framed Diploma: the board's hands per second.
        self._hand_times = self._hand_times or {}
        self._hand_times[#self._hand_times + 1] = love.timer.getTime()
        -- The rail's earn rate: this table's recent hands, on the board's
        -- clock (pruned in update, read by boardRate).
        if tbl then
            tbl._hand_clock = tbl._hand_clock or {}
            tbl._hand_clock[#tbl._hand_clock + 1] = self.clock or 0
        end

        state.total_hands_played = (state.total_hands_played or 0) + hand_units
        if state.total_hands_played == 1 and state.first_hand_delta == nil then
            state.first_hand_delta = r.delta or 0
            state.first_hand_tier  = r.tier or "small"
        end
        -- Every hand, won or lost, for the volume counters (Energy Drink's
        -- "every 250 hands"). Same running-total shape as on_hand_won.
        self:_announce("on_hand_played", {
            table = tbl, count = state.total_hands_played, out = resolutions,
        })
        -- Cutting Board: only a hand the player dealt moves the streak.
        if tbl and tbl._dealt_by_player then
            tbl._dealt_by_player = nil
            tbl._hand_mult = nil
            if self.ctx and self.ctx.manual_combo then
                if r.won then
                    self.manual_combo = (self.manual_combo or 0) + 1
                    if self.manual_combo >= 2 and self.game.floating_text then
                        local pos = AnchorRegistry.get(TableModel.anchorKey(tbl, "center"))
                        if pos then
                            self.game.floating_text.emit(("COMBO x%d"):format(self.manual_combo),
                                pos[1] + (pos[3] or 0) * 0.5, pos[2], { color_token = "won" })
                        end
                    end
                else
                    self.manual_combo = 0
                end
            end
        end
        -- Handheld (ctx.zoom_fast_fold): a loss at Zoom deals the next
        -- hand now. Real Zoom: fold, and you are at the next table.
        -- The resolution arrives while the table is still settling (it
        -- goes idle 0.4 s later), so the fold is latched here and dealt
        -- by update() on the first idle frame.
        if not r.won and gtype_id == "zoom" and self.ctx and self.ctx.zoom_fast_fold and tbl then
            tbl._fast_fold_pending = true
        end
        if r.won then
            state.total_hands_won = (state.total_hands_won or 0) + 1
            -- Carries the running total, because a counter proc decides
            -- whether it is the hundredth by looking at the number rather
            -- than by keeping a tally of its own. Nothing to persist, and
            -- a reload cannot desync it.
            self:_announce("on_hand_won", {
                table = tbl, count = state.total_hands_won, out = resolutions,
                all_games = self:_allGamesOpen(),
            })
        end
        if r.tier == "large" or r.tier == "stack" then
            -- Big outcomes, win or loss — the tutorial's tier hint fires
            -- on the first one.
        end
        if r.won and r.tier == "stack" then
            state.total_stacks = (state.total_stacks or 0) + 1
        elseif (not r.won) and r.tier == "stack" then
            state.total_stack_losses = (state.total_stack_losses or 0) + 1
        end
        -- The rail's earn rate: what the run's hands have netted. A
        -- chip-stack tournament's per-hand delta is informational (its
        -- cash lands in the payout drain above), so it is left out here.
        if not r.chip_stack_table then
            state.run_hand_net = (state.run_hand_net or 0) + r.delta
        end
        if r.delta < 0 then
            -- Fuels the Dishwasher's next-run seed (GameState:resetRun
            -- freezes this into last_run_money_lost).
            state.run_money_lost = (state.run_money_lost or 0) + (-r.delta)
        elseif r.delta > 0 then
            -- The Cereal Shelf's seed: the run's biggest pot, at the first
            -- stake and at any stake (frozen into last_run_* at reset).
            if r.delta > (state.run_biggest_pot or 0) then state.run_biggest_pot = r.delta end
            if stake and stake.id == Stakes[1].id and r.delta > (state.run_biggest_pot_t1 or 0) then
                state.run_biggest_pot_t1 = r.delta
            end
        end
        if n_tables >= 4 then
            state.total_hands_at_4plus = (state.total_hands_at_4plus or 0) + hand_units
        end
        if n_tables > focus_cap then
            state.total_hands_overwhelmed = (state.total_hands_overwhelmed or 0) + hand_units
        end
        if gtype_id then
            state.total_hands_by_gtype = state.total_hands_by_gtype or {}
            state.total_hands_by_gtype[gtype_id] =
                (state.total_hands_by_gtype[gtype_id] or 0) + hand_units
        end
        if stake then
            local idx = Lookups.indexById(Stakes, stake.id) or 0
        end

        -- Deck-system meta bookkeeping. Lifetime counters drive unlock
        -- thresholds; the resolved-hand event drives active-deck XP. All
        -- of it gates on the system unlock (first gauntlet clear), so no
        -- silent state accrues before decks exist — deck progression
        -- starts from zero the moment the shove is first beaten.
        if Decks.systemUnlocked(state) then
            -- n_tables / gtype_id / focus_cap are hoisted above with the
            -- ungated counters.

            -- Lifetime counters: every resolution bumps hands_played; the
            -- rest fire on their conditional events. Bumped BEFORE
            -- checkPendingUnlocks so any threshold crossed by this hand
            -- unlocks immediately.
            if r.delta > 0 then
                state.total_money_won = (state.total_money_won or 0) + r.delta
            elseif r.delta < 0 then
            end
            if r.won and r.tier == "stack" and not r.flipped then
            end
            if r.won and gtype_id == "ko" then
            end
            if n_tables >= 4 then
            end

            -- XP grant for the active deck. Event carries everything the
            -- registered XP rules (parameterized by gtype / tier / etc.)
            -- can filter on.
            local bb           = (stake and stake.bb and stake.bb > 0) and stake.bb or nil
            local stake_tier_idx = stake and Lookups.indexById(Stakes, stake.id) or nil
            -- Hands played while OVER the focus cap — matches the Multitasker
            -- deck's overwhelmed identity (its unlock, mirroring its XP rule).
            if n_tables > focus_cap then
            end
            self:_grantDeckXp({
                won            = r.won and true or false,
                delta          = r.delta,
                tier           = r.tier,
                bb_delta       = bb and (r.delta / bb) or 0,
                stake_buy_in   = stake and stake.buy_in or 0,
                gtype          = gtype_id,
                stake_tier_idx = stake_tier_idx,
                bankroll       = state.bankroll,
                board_pure     = (self.ctx and self.ctx.board_pure_gtype) ~= nil,
                n_tables       = n_tables,
                hand_units     = hand_units,
                focus_capacity = focus_cap,
            })

            -- Newly-met unlock thresholds flip locked decks into the
            -- player's roster. Returns the list of newly-unlocked ids;
            -- effects cache only needs invalidating if anything actually
            -- unlocked.
            local newly = Decks.checkPendingUnlocks(state, self.game.unlock_rules)
            if #newly > 0 then
                self:invalidateEffects()
                state.decks_unseen = state.decks_unseen or {}
                for _, id in ipairs(newly) do
                    local spec = Decks.specById(id)
                    -- The cell keeps pulsing until the roster is opened.
                    state.decks_unseen[#state.decks_unseen + 1] = id
                    self:_announceOnDeckCell(
                        "NEW DECK: " .. ((spec and spec.name) or id))
                end
            end
        end
    end

    -- Resolutions just mutated per-table state (incl. KoSession fields
    -- on tournament tables). Resync so a save mid-KO-run
    -- captures the latest hand counter. Cheap (4 array writes per
    -- table; bounded by MAX_TABLES).
end

-- Announce something landing on the DECK cell: a gold pulse on the cell plus
-- a floater rising off it. The same pair a {chip} bounty uses, for the same
-- reason -- this is acknowledgement, not teaching, so it wants the vocabulary
-- the player already reads rather than a new one.
--
-- Both of the events this serves were already detected and thrown away:
-- Decks.checkPendingUnlocks RETURNS the newly-unlocked ids and Decks.gainXp
-- returns a level-up flag, and each was used only to invalidate the effects
-- cache. Deck progression has been completely silent since it shipped.
--
-- Anchored, so it no-ops when the cell is not on screen (the boot-time and
-- deck-select unlock sweeps have no grind view to draw into).
function GrindController:_announceOnDeckCell(text)
    local a = AnchorRegistry.get("cell:deck")
    if not a then return end
    AwardGlow.flash("deck")   -- the rail's deck button, by its id
    self:_playNamed("deck_up")
    if self.game.floating_text then
        self.game.floating_text.emit(text,
            a[1] + (a[3] or 0) * 0.5, a[2] + (a[4] or 0),
            -- "won" resolves through Theme.semColor in GrindView's floater
            -- draw. Without a token this text would default to status.error,
            -- because the auto-color rule only reads a leading "+" as good
            -- news and an unlock does not start with one.
            { color_token = "won" })
    end
end

-- Grant XP to the active deck for one resolved hand. Returns true on a
-- level-up so the controller can invalidate the effects cache; the model
-- side handles the math + state writes.
function GrindController:_grantDeckXp(event)
    -- Tori Gate multiplies whatever the deck's XP rule returns.
    local xp_mult = (self.ctx and self.ctx.deck_xp_mult) or 1
    local _, leveled = Decks.gainXp(self.game.state, self.game.xp_rules, event, xp_mult)
    if leveled then
        self:invalidateEffects()
        local state = self.game.state
        local id    = state.active_deck_id
        local spec  = id and Decks.specById(id)
        local lvl   = state.deck_levels and id and state.deck_levels[id]
        local name  = (spec and spec.name) or "DECK"
        self:_announceOnDeckCell(lvl and (name .. " L" .. lvl) or (name .. " LEVEL UP"))
        -- The deck is the thing dealing: every face-down back on the felt
        -- flashes for a beat (views/TablePanel reads this timestamp).
        state._deck_levelup_t = love.timer.getTime()
    end
end

-- ─── Purchase intents (called from view button handlers) ─────────────────────

-- Stacking run upgrade purchase. Each click bumps the upgrade's level by one
-- (up to its max_level). Cost for the next level is item.costs[N+1], multiplied
-- by ctx.run_upgrade_cost_mult so the Ring Binder catalog perk discounts
-- every run-upgrade buy. Returns true on a successful level-up.
-- True if the optional `requires` field on a catalog/run-upgrade item is
-- met by the player's owned_items list. nil/missing → unconditional.
function GrindController:_requirementMet(requires_id)
    if not requires_id then return true end
    for _, owned_id in ipairs(self.game.state.owned_items) do
        if owned_id == requires_id then return true end
    end
    return false
end

-- True if the player has already banked the (stake, gtype) chip bounty
-- this run. Mirrors the bountyKey format used by the resolution loop —
-- keep both writers using the same key format.
function GrindController:bountyBanked(stake_id, game_type_id)
    local key = bountyKey(stake_id, game_type_id)
    local cur = self.game.state.stakes_won_this_run and self.game.state.stakes_won_this_run[key]
    local count = 0
    if cur == true then
        count = 1
    elseif type(cur) == "number" then
        count = cur
    end
    return count >= 1
end

-- What a lane's bounty actually PAID this run, or nil while unbanked: the
-- rolled figure (the Trophy Shelf's double, the first-bounty bonus, a Copy
-- Machine second helping), where bountyAward without `roll` is only the
-- advertised one. The sidebar badge reads this once the lane is banked, so
-- a doubled bounty shows +8 and not the +4 it was advertised at.
function GrindController:bountyPaid(stake_id, game_type_id)
    local paid = self.game.state.bounty_paid_this_run
    return paid and paid[bountyKey(stake_id, game_type_id)] or nil
end

function GrindController:_recordBountyPaid(key, amount)
    local state = self.game.state
    state.bounty_paid_this_run = state.bounty_paid_this_run or {}
    state.bounty_paid_this_run[key] = (state.bounty_paid_this_run[key] or 0) + amount
end

function GrindController:antiBountyBanked(stake_id, game_type_id)
    local key = bountyKey(stake_id, game_type_id)
    local cur = self.game.state.anti_stakes_won_this_run and self.game.state.anti_stakes_won_this_run[key]
    return cur == true
end

-- THE bounty math — base stake.chip_award scaled by ctx.chip_award_mult,
-- then any flat ctx.stack_chip_add (Pen) added on top. Every award
-- site (cash stack, tournament win) and every display (sidebar "+N"
-- badge) calls this, so payouts can never drift from what's advertised.
-- An effect kind just did something: tell whoever listens which items
-- put it there (ctx.sources, from computeEffects). Sound and any future
-- visual feedback hang off the "item_fired" event; this file stays mute.
function GrindController:itemFired(kind, tbl)
    local ctx = self.ctx
    local bus = self.game.event_bus
    local ids = ctx and ctx.sources and ctx.sources[kind]
    if not bus or not ids then return end
    -- Where the "what fired" ghost shows: the triggering table's centre
    -- anchor, resolved now (the registry is view-written and stales).
    local x, y, pw, ph
    local pos = tbl and AnchorRegistry.get(TableModel.anchorKey(tbl, "center"))
    if pos then x, y, pw, ph = pos[1], pos[2], pos[3], pos[4] end
    for _, id in ipairs(ids) do
        bus:publish("item_fired", { item_id = id, kind = kind,
                                    x = x, y = y, pw = pw, ph = ph })
    end
end

-- `opts.roll`: this call PAYS the bounty, so the Trophy Shelf's 1-in-4
-- double is rolled (and reported). Without it the number is the plain,
-- deterministic award: the sidebar's "+N" badge reads it every frame, and
-- a display must never roll dice or fire an item.
function GrindController:bountyAward(stake_id, gtype_id, opts)
    local stake = Lookups.findById(Stakes,stake_id)
    if not stake then return 0 end
    local mult  = (self.ctx and self.ctx.chip_award_mult) or 1
    -- Per-game-type multiplier (Fight Night: HU bounties pay double).
    local gmults = self.ctx and self.ctx.bounty_gtype_mult
    if gtype_id and gmults and gmults[gtype_id] then
        mult = mult * gmults[gtype_id]
    end
    local bonus = (self.ctx and self.ctx.stack_chip_add) or 0
    -- The Trophy Shelf: a bounty sometimes pays double, the whole thing.
    local dbl = opts and opts.roll and self.ctx and self.ctx.bounty_double_chance
    if dbl and dbl > 0 and love.math.random() < dbl then
        self:itemFired("bounty_double_chance", nil)
        return (math.floor((stake.chip_award or 0) * mult + 0.5) + bonus) * 2
    end
    return math.floor((stake.chip_award or 0) * mult + 0.5) + bonus
end

-- The {achip} for losing a whole stack at this stake: the ladder's length
-- minus the stake's position, plus one, so the first stake pays the most
-- and the top pays 1. Computed, not authored: it follows the ladder if a
-- stake is added or removed, the way chip_award follows position.
function GrindController:antiBountyAward(stake_id)
    local stake = Lookups.findById(Stakes, stake_id)
    local idx   = Lookups.indexById(Stakes, stake_id)
    if not stake or not idx then return 0 end
    -- Ultra is not a rung. It is played once, to underflow, and pays no
    -- bounty either way. The ladder is every stake below it.
    if stake.band == "ultra" then return 0 end
    local rungs = 0
    for _, s in ipairs(Stakes) do if s.band ~= "ultra" then rungs = rungs + 1 end end
    return rungs - idx + 1
end

function GrindController:buyRunUpgrade(upgrade_id)
    local state = self.game.state
    -- Find item by id.
    local upgrade
    for _, u in ipairs(RunUpgrades) do
        if u.id == upgrade_id then upgrade = u; break end
    end
    if not upgrade then return false end
    if not self:_requirementMet(upgrade.requires) then return false end

    local current = state.run_upgrade_levels[upgrade_id] or 0
    local max_lvl = self:getRunUpgradeMaxLevel(upgrade)
    if current >= max_lvl then return false end

    local cost = self:getRunUpgradeNextCost(upgrade) or 0
    if state.bankroll < cost then return false end

    state.bankroll = state.bankroll - cost
    state.run_upgrade_levels[upgrade_id] = current + 1
    HandAnalytics.recordEvent({
        t            = love.timer.getTime(),
        type         = "run_upgrade",
        item_id      = upgrade_id,
        level        = current + 1,
        cost_dollars = cost,
        bankroll     = state.bankroll,
    })

    -- Grant deck XP for purchasing upgrade
    self:_grantDeckXp({
        type         = "run_upgrade",
        item_id      = upgrade_id,
        level        = current + 1,
        cost_dollars = cost,
    })

    -- Ungated mirror — catalog gates (Ring Binder, Filing Cabinet, Supply
    -- Closet) read this one, so it has to tick in Act 1 too.
    state.total_upgrade_levels = (state.total_upgrade_levels or 0) + 1
    -- Lifetime counter drives the Investor deck's unlock. Gated like the
    -- other lifetime_* counters (accrue only once the deck system exists).
    if Decks.systemUnlocked(state) then
        Decks.checkPendingUnlocks(state, self.game.unlock_rules)
    end

    self:invalidateEffects()
    self:_playNamed("upgrade_purchased")
    return true
end

-- View helper: returns the current owned level (0 = unowned) and the next
-- level's discounted cost (for the BUY button label). Pass-through to data;
-- views shouldn't reach into state.run_upgrade_levels directly.
function GrindController:getRunUpgradeLevel(upgrade_id)
    return self.game.state.run_upgrade_levels[upgrade_id] or 0
end

-- Highest run-upgrade level worth buying right now. For fill upgrades
-- (fill_scaled) this is FULLY DYNAMIC: the largest fill_window.complete
-- among the stakes currently BUYABLE (stakeAvailable — ultra excluded, it's
-- unfillable), clamped to the cost array. Nothing is hardcoded per tier or
-- act: add/remove/re-gate stakes and the cap follows on its own. Non-fill
-- upgrades keep their static max_level. Investor's bonus levels stack on top.
function GrindController:getRunUpgradeMaxLevel(upgrade)
    if not upgrade then return 0 end
    local max_lvl
    if upgrade.fill_scaled then
        -- The EFFECTIVE window (OutcomeMath.effectiveWindow): a widened
        -- window needs more levels to fill, and those must be buyable.
        local best = 0
        for _, s in ipairs(Stakes) do
            if s.band ~= "ultra" and self:stakeAvailable(s) and s.fill_window then
                local _, complete = OutcomeMath.effectiveWindow(s.fill_window, self.ctx)
                if complete > best then best = complete end
            end
        end
        local cap = (upgrade.costs and #upgrade.costs) or best
        max_lvl = math.min(best, cap)
    else
        max_lvl = upgrade.max_level or 1
    end
    -- Bonus levels (the Bookshelf) raise each stake's ceiling in
    -- OutcomeMath.fillRatio; they never add a level to buy.
    return max_lvl
end

-- The price of the next level: the derived ladder price, times the catalog
-- discount (ctx.run_upgrade_cost_mult), then rounded to the game's price
-- precision (UpgradePricing.roundPrice) — the rounding is LAST so a 15%
-- discount can't turn $1.40 back into $1.19. The buy path charges exactly
-- this number. nil at max level.
function GrindController:getRunUpgradeNextCost(upgrade)
    if not upgrade then return nil end
    local current = self.game.state.run_upgrade_levels[upgrade.id] or 0
    local max_lvl = self:getRunUpgradeMaxLevel(upgrade)
    if current >= max_lvl then return nil end
    local cost = 0
    if upgrade.costs then
        if current + 1 <= #upgrade.costs then
            cost = upgrade.costs[current + 1]
        else
            local last_cost = upgrade.costs[#upgrade.costs] or 0
            cost = last_cost * 3.0
        end
    end
    cost = cost * ((self.ctx and self.ctx.run_upgrade_cost_mult) or 1)
    return UpgradePricing.roundPrice(cost)
end

-- Strand check: would spending `cost` leave the player unable to play any
-- table — no felt to grind back from? True only when there are no
-- playable tables (stack > 0) AND the post-purchase bankroll is below the
-- cheapest stake's adjusted buy-in. Used by the upgrades tab to disable
-- buttons that would silently end the run.
-- Effective buy-in multiplier for a given stake: the unbounded scalar
-- (Discount Sits) times any tier-scoped multipliers (High Roller halves
-- T4+ buy-ins) whose bounds include this stake's tier index. The one
-- place buy-in discounting resolves, so every buy site agrees.
function GrindController:buyInMultFor(stake)
    local ctx  = self.ctx
    local mult = (ctx and ctx.buy_in_mult) or 1
    if ctx and ctx.buy_in_mult_tiered and stake then
        local idx = Lookups.indexById(Stakes, stake.id)
        for _, e in ipairs(ctx.buy_in_mult_tiered) do
            local tier_ok = (not e.tier_min or (idx and idx >= e.tier_min))
                        and (not e.tier_max or (idx and idx <= e.tier_max))
            if tier_ok then mult = mult * (e.value or 1) end
        end
    end
    return mult
end

-- Cheapest table the player could open right now (min buy-in x buy_in_mult).
function GrindController:_cheapestBuyIn()
    local cheapest
    for _, s in ipairs(Stakes) do
        local bi = (s.buy_in or 0) * self:buyInMultFor(s)
        if not cheapest or bi < cheapest then cheapest = bi end
    end
    return cheapest
end

-- True when no open table still holds chips (nothing left in play).
function GrindController:_noLiveTables()
    for _, t in ipairs(self.pool.tables) do
        if (t.stack or 0) > 0 then return false end
    end
    return true
end

function GrindController:wouldStrandRun(cost)
    if not cost or cost <= 0 then return false end
    if not self:_noLiveTables() then return false end
    local cheapest = self:_cheapestBuyIn()
    if not cheapest then return false end
    return (self.game.state.bankroll - cost) < cheapest
end

-- TUTORIAL builds hide SHOVE entirely until the first-ever run banks
-- SHOVE_UNLOCK_CHIPS — the prestige reveals itself when there's something
-- worth banking (the shove_ready hint fires at the same moment). Anyone
-- who has shoved before keeps the button from hand one. No softlock:
-- quick-reset doesn't gate on chips, so a stranded sub-threshold player
-- still has the rescue.
function GrindController:shoveUnlocked()
    local state = self.game.state
    -- has_shoved, NOT shove_count: shove_count is bumped by GameState.resetRun,
    -- which the quick-reset rescue button also calls, so bailing out of a
    -- bricked first run used to reveal SHOVE permanently without the player
    -- ever banking the 3 {chip} the gate is supposed to require.
    return state.has_shoved
        or (state.chips_this_run or 0) >= Constants.GAMEPLAY.SHOVE_UNLOCK_CHIPS
end

-- Bricked: nothing in play and can't afford even the cheapest buy-in — the
-- soft-stuck state the quick-reset rescues.
function GrindController:isStranded()
    -- Before the loan has been handed over there is nothing to be stranded
    -- from: a fresh game holds $0 until the arrival beat pays, and the
    -- rescue must not offer a "reset to two dollars" over that.
    if (self.game.state.total_hands_played or 0) == 0
       and (self.game.state.bankroll or 0) <= 0 then return false end
    if not self:_noLiveTables() then return false end
    local cheapest = self:_cheapestBuyIn()
    if not cheapest then return false end
    return self.game.state.bankroll < cheapest
end

-- Whether the no-cost quick-reset should be offered: bricked. Chips don't
-- gate it — :quickReset banks this run's chips first, so a bricked player
-- who can't yet afford anything in the shop can still bail to a fresh
-- stake without losing them.
function GrindController:canQuickReset()
    return self:isStranded()
end

-- Spot the player a fresh starting stake without a Shove. Banks this run's
-- chips first (so a bricked player who can't afford the shop yet doesn't lose
-- them), then mirrors the post-bust run reset: wipe the run, re-seed starting
-- perks, rebuild the pool. Caller persists.
function GrindController:quickReset()
    local state = self.game.state
    state.chips = state.chips + (state.chips_this_run or 0)
    state.anti_chips = (state.anti_chips or 0) + (state.anti_chips_this_run or 0)
    state:resetRun()
    self:invalidateEffects()
    -- Run-start perks are silent: they land while the player is between
    -- screens (the deck modal, the reset), which is nowhere to hear them.
    state:applyStartingPerks(self.ctx)
    state.perks_pending = nil
    self:reloadPool()
end

-- Throw away every live Table and rebuild from the records on the state.
--
-- Only for the paths that REPLACE those records wholesale: a run reset, a
-- reload from disk, a wipe. Entering the grind screen used to do this every
-- time, which is why a hand in flight never survived a trip to the room.
--
-- The floaters and queued bursts go first. Both hold references to the
-- Table objects about to be discarded, and a result floater parked on one
-- waits for it to leave "idle" or play another hand — which a discarded
-- table never does (the "stuck payout" bug).
function GrindController:reloadPool()
    if self.game.floating_text then self.game.floating_text.clear() end
    self.pending_bursts = {}
    -- The ticker plots the run's winnings; a reloaded pool is a new run
    -- (or a wiped one), so the trace starts over rather than drawing the
    -- reset as a cliff.
    self._rt_last_net = nil
    -- The Tally Book's streak is the run's, not the save's: a new run
    -- starts it at nothing, the way its tables start fresh.
    self.manual_combo = 0
    self:invalidateEffects()
    self.pool:restoreFromState(self.ctx)
end

-- Seed the next run's starting perks, once. The shove settles the run the
-- moment the showdown has played, but the perks have to wait for the
-- catalog browse that follows it (Pocket Cash bought post-bust seeds the
-- run it was bought for). Whoever gets there first — the catalog dismissal,
-- the credits, or the next grind entry after a quit — clears the flag.
function GrindController:applyPendingPerks()
    local state = self.game.state
    if not state.perks_pending then return false end
    state.perks_pending = nil
    self:invalidateEffects()
    state:applyStartingPerks(self.ctx)
    self:reloadPool()
    return true
end

-- The player physically pulled the COMING SOON sticker off `item_id`. Records
-- it so the reveal sticks across sessions; the view owns the drag, the model
-- owns the fact. No-op if already peeled.
function GrindController:peelCatalogSticker(item_id)
    local state = self.game.state
    state.peeled_items = state.peeled_items or {}
    for _, id in ipairs(state.peeled_items) do
        if id == item_id then return false end
    end
    state.peeled_items[#state.peeled_items + 1] = item_id
    state:markCatalogDirty()
    self:_playNamed("hole_card_flip")
    return true
end

function GrindController:buyCatalogItem(item_id)
    local item
    for _, it in ipairs(Catalog) do
        if it.id == item_id then item = it; break end
    end
    -- Defensive unlock gate: a locked item can't be bought even if the UI is
    -- bypassed. Reuses the same registry the catalog silhouettes check.
    if item and item.unlock and self.game.unlock_rules
       and not self.game.unlock_rules:check(item.unlock, self.game.state) then
        return false
    end
    local chips_before = self.game.state.chips
    if not self.game.state:tryBuyCatalogItem(item) then return false end
    HandAnalytics.recordEvent({
        t          = love.timer.getTime(),
        type       = "catalog",
        item_id    = item_id,
        cost_chips = chips_before - self.game.state.chips,
        chips      = self.game.state.chips,
    })
    self:invalidateEffects()
    self:_playNamed("upgrade_purchased")
    return true
end

function GrindController:corruptCatalogItem(item_id)
    local item
    for _, it in ipairs(Catalog) do
        if it.id == item_id then item = it; break end
    end
    if not self.game.state:tryCorruptItem(item) then return false end
    self:invalidateEffects()
    self:_playNamed("upgrade_purchased")
    return true
end

-- Bankroll-cost-to-open. Adding a table deducts the stake's buy-in (100bb)
-- Whether a stake is offered to the player right now. Low band is always
-- available; mid/high/ultra gate behind their milestone flag (see
-- data/constants STAKE_BAND_GATE), and the whole non-low ladder is off in
-- Single source of truth
-- for stake availability — the add-table buttons and the win-chance / stack-
-- rate range tooltips all route through it so they never disagree.
function GrindController:stakeAvailable(stake)
    local band = (stake and stake.band) or "low"
    local gate = Constants.STAKE_BAND_GATE[band]
    if not gate then return true end
    return self.game.state[gate] == true
end

-- Which game types the add-table UI offers. Twin of stakeAvailable, off
-- Constants.GTYPE_GATE: the zoom-first opening unlocks modes as taught
-- moments instead of offering all twelve combos at minute one.
function GrindController:gtypeAvailable(gtype_id)
    local gate = Constants.GTYPE_GATE[gtype_id]
    if not gate then return true end
    return self.game.state[gate] == true
end

-- from bankroll, optionally discounted by ctx.buy_in_mult (Discount Sits
-- catalog perk). Game type doesn't change the buy-in. Returns false if
-- not affordable / pool full / unknown stake-or-gametype.
function GrindController:addTable(stake_id, game_type_id)
    if self.pool:count() >= self:tableSlotsCap() then return false end
    -- Defensive gate re-check, like buyCatalogItem re-checks its unlock:
    -- the strip hides locked tabs from clicks, but nothing else should
    -- trust the view.
    if not self:gtypeAvailable(game_type_id or "six_max") then return false end
    local stake = Lookups.findById(Stakes,stake_id)
    if not stake then return false end
    local mult = self:buyInMultFor(stake)
    local cost = (stake.buy_in or 0) * mult
    if self.game.state.bankroll < cost then return false end
    self.game.state.bankroll = self.game.state.bankroll - cost
    -- Take the newcomer from addTable's return: the pool sorts by cell, so
    -- a table filling an interior hole is NOT last in the array, and
    -- tables[#tables] would hand back somebody else.
    -- Is this the first open table at its stake? (Rolled Vouchers.)
    local first_at_stake = true
    for _, t in ipairs(self.pool.tables) do
        if t.stake_id == stake_id then first_at_stake = false; break end
    end
    local new_tbl = self.pool:addTable(stake_id, game_type_id or "six_max", self.ctx)
    self:invalidateEffects()
    if new_tbl then
        self:_announce("on_table_open", { table = new_tbl, first_at_stake = first_at_stake })
    end
    -- Adding into a hole renumbers pool order the same way a drag does;
    -- cursor claims are index-keyed, so release them (see moveTableToSlot).
    CursorPool.releaseAllTargets()
    -- Any cash left on the table after the discount counts as the table's
    -- starting stack — Table:new already seeds stack to stake.buy_in (the
    -- 100bb cap), so the discount effectively lets the player keep the
    -- difference in bankroll. Net: same stack value, less paid up front.

    if new_tbl then
        -- Stash a pending bankroll → YOU chip burst on the just-added table;
        -- :update emits it once the view has populated panel positions.
        new_tbl._pending_buyin = cost
    end
    self:_playNamed("table_open")
    return true
end

-- Sum of live stacks at active tables. The "TIED UP" reading on the
-- top bar — money that's not gone, just locked on the felt. Cash
-- tables: tracks the current stack value (which fluctuates with
-- wins/losses), since cash-out refunds that exact amount. Chip-stack
-- tournaments: tracks the buy-in (what was actually paid to sit
-- down), since chip-pile growth during a tournament doesn't convert
-- to cash until the finish-position payout settles at the end. A
-- busted or freshly-settled tournament has tbl.stack = 0 → no
-- contribution either way.
-- ─── The board's earn rate ──────────────────────────────────────────
-- What the board should earn a minute at the player's CURRENT pace: for
-- every open table, its expected $/hand (tableStats: stake, game type,
-- upgrades, items, statuses, its cell, the focus multiplier) times the
-- hands it actually finished in the last RateTicker.window_s seconds of
-- board time, summed.
-- The formula sim/act1.lua prices upgrades with, measured live instead of
-- calibrated: it moves the moment an upgrade lands or a table opens, and
-- falls to nothing as the player stops dealing. A raw $/minute of actual
-- winnings could not do this job -- stack wins carry the money, so any
-- short window reads $0 most of the time and spikes; that figure is the
-- tooltip's "this run", where it has minutes to settle.
--
-- Returns { total, focus_mult, tables = { { tbl, ev_hand, hpm, rate } },
--           run_net, run_elapsed, run_rate, last_run_rate }. Cheap: one
-- cached tableStats per table.
function GrindController:boardRate()
    local state = self.game.state
    local clock = self.clock or 0
    local win   = RateTicker.window_s or 60
    local floor_s = RateTicker.min_window_s or 5
    -- Focus is in the hpm, not the ev: an over-cap board plays slower, so
    -- each table's measured hand count already carries it. focus_mult
    -- rides along for the tooltip's explanation only.
    local out = { tables = {}, total = 0, focus_mult = self:currentFocusMult() }
    local sum = 0
    for _, tbl in ipairs(self.pool.tables) do
        -- Stamped by update the first frame the table is seen; the `or`
        -- covers a read before that frame.
        tbl._opened_clock = tbl._opened_clock or clock
        local span  = math.max(floor_s, math.min(win, clock - tbl._opened_clock))
        local n     = tbl._hand_clock and #tbl._hand_clock or 0
        local hpm   = n / (span / 60)
        local stats = self:tableStats(tbl)
        local ev    = (stats and stats.ev_per_hand) or 0
        local rate  = (n > 0) and (ev * hpm) or 0
        out.tables[#out.tables + 1] = { tbl = tbl, ev_hand = ev, hpm = hpm, rate = rate }
        sum = sum + rate
    end
    out.total       = sum
    out.run_net     = state.run_hand_net or 0
    out.run_elapsed = state.run_elapsed or 0
    out.run_rate    = (out.run_elapsed > 0) and (out.run_net / (out.run_elapsed / 60)) or 0
    out.last_run_rate = state.last_run_rate or 0
    return out
end

function GrindController:tiedUp()
    local total = 0
    for _, t in ipairs(self.pool.tables) do
        local stack = t.stack or 0
        if stack <= 0 then
            -- Busted or post-settle — nothing locked here.
        else
            local gtype = Lookups.findById(GameTypes, t.game_type_id)
            if gtype and gtype.chip_stack_table then
                local stake = Lookups.findById(Stakes, t.stake_id)
                total = total + ((stake and stake.buy_in) or 0)
            else
                total = total + stack
            end
        end
    end
    return total
end

-- Removing a table refunds the *current stack* (cash-out semantics).
-- Lost it all? You get $0 back. Sitting on a freshly bought-in table
-- with no hands played? Full buy-in returns.
--
-- Chip-stack tournaments: closing mid-tournament forfeits the buy-in.
-- Chips on the table are tournament chips — they don't convert to cash
-- until the finish-position payout settles. A brand-new tournament
-- table (no hand dealt yet → ko not yet playing) still refunds the
-- buy-in so accidental adds aren't punitive; a busted or post-settle
-- table has stack = 0 already.
function GrindController:_finalizeRemove(idx, quiet)
    local t = self.pool.tables[idx]
    if not t then return false end
    local gtype = Lookups.findById(GameTypes, t.game_type_id)
    local refund
    if gtype and gtype.chip_stack_table and t.ko and t.ko:isPlaying() then
        refund = 0
    else
        refund = t.stack or 0
    end
    if not quiet then
        self:_emitCashOutChips(t, refund)
        self:_playNamed("table_close")
    end
    -- A resting result floater on this table would outlive it (a removed
    -- table stays "idle" forever, so the leaves-idle removal never fires).
    self.game.floating_text.dropForTable(t)
    self.pool:removeTable(idx)
    -- Everything keyed on this table's id goes with it: its rolled numbers
    -- and pops (Table.rollingKey memoizes the keys on the table), its
    -- anchors (Table.anchorKey likewise), its cached stats, and its pot
    -- and stack piles (queued for the view, which owns ChipPile; drained
    -- beside pending_bursts). Without this a session's maps held every
    -- table ever opened.
    RollingValue.forgetAll(t._rolling_keys)
    Pop.forgetAll(t._rolling_keys)
    AnchorRegistry.forgetAll(t._anchor_keys)
    if self._tbl_stats then self._tbl_stats[t._id] = nil end
    if self._tbl_debug then self._tbl_debug[t._id] = nil end
    local fp = self.forget_piles
    if not fp then fp = {}; self.forget_piles = fp end
    fp[#fp + 1] = TableModel.anchorKey(t, "pot")
    fp[#fp + 1] = TableModel.anchorKey(t, "you")
    -- Closing renumbers pool order (table.remove, possibly a repack), and
    -- cursor claims are index-keyed — release them so no cursor silently
    -- re-aims at whatever table now sits at its index (see moveTableToSlot).
    CursorPool.releaseAllTargets()
    self.game.state.bankroll = self.game.state.bankroll + refund
    self:invalidateEffects()
    return true
end

-- Leave the table NOW, poker style — the second click on a pending [x].
-- Whatever is in the current hand is forfeited:
--   * Cash: your stack leaves with you MINUS what you've already pushed
--     into this pot. Exactly what standing up mid-hand costs in a room.
--   * Tournament mid-run: you're out where you stand — settled at the
--     finish a bust this instant would earn (alive players = your place),
--     which pays its ladder multiple if that's the money and nothing if
--     it isn't. Deliberately NO on_tournament_win/miss announces: those
--     are outcomes; walking away is a choice, and it shouldn't tilt the
--     neighbours or feed the ratchet.
--   * Tournament settled with an undrained payout (the one-frame window
--     before the drain sweep): credited here, quietly, so the forced
--     close can't eat a cash.
function GrindController:_forceRemove(idx)
    local t = self.pool.tables[idx]
    if not t then return false end
    local gtype = Lookups.findById(GameTypes, t.game_type_id)
    if gtype and gtype.chip_stack_table then
        if t.ko and t.ko:isPlaying() then
            local n_seats = (gtype.seats or 0) + 1
            local alive_opps = 0
            for s = 1, n_seats do
                if s ~= t.player_seat_fixed
                   and not (t.seat_busted and t.seat_busted[s]) then
                    alive_opps = alive_opps + 1
                end
            end
            t:_endTournament(alive_opps + 1, n_seats)
        end
        local payout = t.ko and t.ko:drainPayout()
        if payout and payout > 0 then
            self.game.state.bankroll = self.game.state.bankroll + payout
            self:_emitKoPayoutChips(t, payout)
            local center = AnchorRegistry.get(TableModel.anchorKey(t, "center"))
                           or { 0, 0 }
            self.game.floating_text.emit(Format.moneySigned(payout),
                center[1], center[2], { fit_table = t })
        end
        -- t.stack is 0 after _endTournament (and after a prior settle),
        -- so _finalizeRemove refunds nothing further.
    elseif t.state ~= "idle" then
        -- Fold and stand up: the pot keeps what you've committed.
        local ps = t.playback_state
        local committed = (ps and ps.player_seat and ps.per_seat_total
                           and ps.per_seat_total[ps.player_seat]) or 0
        t.stack = math.max(0, (t.stack or 0) - committed)
    end
    return self:_finalizeRemove(idx)
end

function GrindController:removeTable(idx)
    local t = self.pool.tables[idx]
    if not t then return false end
    -- Mid-hand → defer close until the hand resolves and we're idle again.
    -- The update loop scans for pending_close + idle each frame. A settled
    -- tournament whose payout has not been drained yet defers the same
    -- way, so the X never eats a cash.
    if t.state ~= "idle" or (t.ko and t.ko.pending_payout ~= nil) then
        -- Already queued → the player is insisting. Leave NOW and forfeit
        -- the hand (see _forceRemove).
        if t.pending_close then
            return self:_forceRemove(idx)
        end
        t.pending_close = true
        return true
    end
    return self:_finalizeRemove(idx)
end

-- Cash out every active table. Idle tables close now; busy tables get
-- their pending_close flag set and finalise once they return to idle.
-- `force` closes every table NOW (mid-hand included) instead of deferring
-- busy ones to pending_close — the SHOVE entry needs an empty pool this
-- frame. A settled tournament's undrained payout is credited first so the
-- forced close can't eat a cash; forced closes are also quiet (no chip
-- bursts into a screen we're leaving).
function GrindController:cashOutAll(force)
    if self.pool:count() == 0 then return false end
    -- Reverse iteration: synchronous closes shift indices.
    for i = #self.pool.tables, 1, -1 do
        if force then
            local t = self.pool.tables[i]
            if t and t.ko and t.ko.pending_payout ~= nil then
                local payout = t.ko:drainPayout()
                if payout and payout > 0 then
                    self.game.state.bankroll = self.game.state.bankroll + payout
                end
            end
            self:_finalizeRemove(i, true)
        else
            self:removeTable(i)
        end
    end
    return true
end

-- Stake-up: cash out the current stack and pay the new buy-in (optionally
-- discounted by ctx.buy_in_mult). Net cost = new_buy_in - current_stack.
-- Bankroll must cover that delta. Table:setStake then resets the table's
-- stack to the new buy-in.
function GrindController:changeTableStake(idx, new_stake_id)
    local t = self.pool.tables[idx]
    if not t then return false end
    local new_stake = Lookups.findById(Stakes,new_stake_id)
    if not new_stake then return false end
    -- Never let a table cross into a band the player hasn't unlocked (the
    -- STAKE↑ path must honor the same gate as the add-table buttons).
    if not self:stakeAvailable(new_stake) then return false end
    local mult   = self:buyInMultFor(new_stake)
    local refund = t.stack or 0
    local cost   = (new_stake.buy_in or 0) * mult
    local diff   = cost - refund
    if diff > 0 and self.game.state.bankroll < diff then return false end
    self.game.state.bankroll = self.game.state.bankroll - diff
    self.pool:changeStake(idx, new_stake_id, self.ctx)
    self:_playNamed("stake_up_flourish")
    return true
end

-- Toggle a table's autonomous-cursor opt-out flag. Persists via
-- Persisted with the table's own record (models/Table:serialize).
function GrindController:toggleCursorMute(idx)
    local t = self.pool:get(idx)
    if not t then return false end
    t.cursor_muted = not (t.cursor_muted == true)
    return true
end

-- Toggle the per-table cursor-rebuy opt-out. Only meaningful when the
-- catalog perk `cursor_rebuy_unlocked` is owned (the [R] header toggle
-- is hidden otherwise). Persisted with the table's own record.
function GrindController:toggleCursorRebuyMute(idx)
    local t = self.pool:get(idx)
    if not t then return false end
    t.cursor_rebuy_muted = not (t.cursor_rebuy_muted == true)
    return true
end

-- Seat a table (identified by its runtime _id — indices go stale between
-- the drag's frames) in a specific board cell. An empty cell moves it; an
-- occupied one swaps the two. Called from GrindView's drag drop, outside
-- the update tick, so the prev_states[i] snapshot never spans a move.
-- The cell persists with the table's own record.
function GrindController:moveTableToSlot(table_id, slot)
    local from_idx
    for i, t in ipairs(self.pool.tables) do
        if t._id == table_id then from_idx = i; break end
    end
    if not from_idx then return false end   -- table closed mid-drag
    if not self.pool:moveToSlot(from_idx, slot) then return false end
    -- Cursor claims are keyed by pool index, and pool order is reading
    -- order of the board — so a move can renumber. Release them so no
    -- cursor silently re-aims at whatever table now sits at its index.
    CursorPool.releaseAllTargets()
    return true
end

-- ── Bulk table actions, scoped to one (stake, game type) ────────────────
-- The sidebar's +ADD row for a combo owns the tables it opened, so its
-- trailing buttons operate on exactly that set. `stake_id` / `gtype_id` nil
-- means "every table", which is what the global cursor controls pass.

local function tableMatches(t, stake_id, gtype_id)
    return (stake_id == nil or t.stake_id == stake_id)
       and (gtype_id == nil or t.game_type_id == gtype_id)
end

-- Close every table of this combo, banking each one's stack. Reverse
-- iteration: removeTable is synchronous for idle tables and shifts indices.
function GrindController:cashOutType(stake_id, gtype_id)
    local n = 0
    for i = #self.pool.tables, 1, -1 do
        local t = self.pool.tables[i]
        if t and tableMatches(t, stake_id, gtype_id) then
            self:removeTable(i)
            n = n + 1
        end
    end
    return n
end

-- How many of this combo's tables have a close queued (pending_close).
-- The sidebar's [x] warn-tints while this is nonzero — the same signal the
-- per-table [x] shows — and clears itself as the closes finalise. A second
-- click on that [x] reaches removeTable on the still-pending tables, which
-- is the force-leave path.
-- ─── The pool summary ──────────────────────────────────────────────────
-- The sidebar asks "how many of this combo are open, and how many of those
-- have their cursors muted?" once per visible stake, every frame, and each
-- question was a full pass over the table list — roughly 800 iterations a
-- frame at a full board. One pass per frame in update() answers all of
-- them. Rebuilt in place, so a steady state allocates nothing.
--
-- The pass counts into a bucket's `n_*` fields first and commits them to
-- its `open` / `deal` / `rebuy` / `pending` afterwards, so it can tell
-- whether any bucket actually moved: `summary_rev` steps only then. The
-- sidebars key their retained trees on it (views/Panel inputs), which is
-- what lets a board that is merely playing leave them alone.
local function commitBucket(e)
    local moved = e.open ~= e.n_open or e.deal ~= e.n_deal
               or e.rebuy ~= e.n_rebuy or e.pending ~= e.n_pending
    e.open, e.deal, e.rebuy, e.pending = e.n_open, e.n_deal, e.n_rebuy, e.n_pending
    return moved
end

local function newBucket()
    return { open = 0, deal = 0, rebuy = 0, pending = 0,
             n_open = 0, n_deal = 0, n_rebuy = 0, n_pending = 0 }
end

function GrindController:_rebuildPoolSummary()
    local sum = self._pool_summary
    if not sum then
        sum = { by_stake = {}, total = newBucket() }
        self._pool_summary = sum
        self.summary_rev = self.summary_rev or 0
    end
    for _, by_gtype in pairs(sum.by_stake) do
        for _, e in pairs(by_gtype) do
            e.n_open, e.n_deal, e.n_rebuy, e.n_pending = 0, 0, 0, 0
        end
    end
    local tot = sum.total
    tot.n_open, tot.n_deal, tot.n_rebuy, tot.n_pending = 0, 0, 0, 0

    for _, t in ipairs(self.pool.tables) do
        local by_gtype = sum.by_stake[t.stake_id]
        if not by_gtype then by_gtype = {}; sum.by_stake[t.stake_id] = by_gtype end
        local e = by_gtype[t.game_type_id]
        if not e then
            e = newBucket()
            by_gtype[t.game_type_id] = e
        end
        e.n_open, tot.n_open = e.n_open + 1, tot.n_open + 1
        if t.cursor_muted == true then
            e.n_deal, tot.n_deal = e.n_deal + 1, tot.n_deal + 1
        end
        if t.cursor_rebuy_muted == true then
            e.n_rebuy, tot.n_rebuy = e.n_rebuy + 1, tot.n_rebuy + 1
        end
        if t.pending_close then
            e.n_pending, tot.n_pending = e.n_pending + 1, tot.n_pending + 1
        end
    end

    local moved = commitBucket(tot)
    for _, by_gtype in pairs(sum.by_stake) do
        for _, e in pairs(by_gtype) do
            if commitBucket(e) then moved = true end
        end
    end
    if moved then self.summary_rev = (self.summary_rev or 0) + 1 end
end

-- The summary bucket for a combo, or nil when the caller passes a shape the
-- summary does not index (one id but not the other) — those fall back to the
-- scan below, so tableMatches stays the single definition of "matches".
function GrindController:_summaryFor(stake_id, gtype_id)
    local sum = self._pool_summary
    if not sum then return nil end
    if stake_id == nil and gtype_id == nil then return sum.total end
    if stake_id == nil or gtype_id == nil then return nil end
    local by_gtype = sum.by_stake[stake_id]
    local e = by_gtype and by_gtype[gtype_id]
    return e or EMPTY_SUMMARY
end

function GrindController:typePendingCloses(stake_id, gtype_id)
    local e = self:_summaryFor(stake_id, gtype_id)
    if e then return e.pending end
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if t.pending_close and tableMatches(t, stake_id, gtype_id) then
            n = n + 1
        end
    end
    return n
end

-- How many tables of this combo are open, and how many of them the cursors
-- are currently muted on. The view needs both: the first to disable a button
-- with nothing to act on, the second to decide whether the toggle reads as
-- ON or OFF for the group.
function GrindController:typeCursorState(stake_id, gtype_id)
    local e = self:_summaryFor(stake_id, gtype_id)
    if e then return e.open, e.deal, e.rebuy end
    local total, deal_muted, rebuy_muted = 0, 0, 0
    for _, t in ipairs(self.pool.tables) do
        if tableMatches(t, stake_id, gtype_id) then
            total = total + 1
            if t.cursor_muted == true       then deal_muted  = deal_muted + 1 end
            if t.cursor_rebuy_muted == true then rebuy_muted = rebuy_muted + 1 end
        end
    end
    return total, deal_muted, rebuy_muted
end

-- Set (not toggle) the cursor-deal mute across a combo. Setting rather than
-- toggling is what makes a group control predictable: a mixed group snaps to
-- one state instead of inverting each table into a different mixed state.
function GrindController:setTypeCursorMute(stake_id, gtype_id, muted)
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if tableMatches(t, stake_id, gtype_id) then
            t.cursor_muted = muted and true or false
            n = n + 1
        end
    end
    return n
end

function GrindController:setTypeCursorRebuyMute(stake_id, gtype_id, muted)
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if tableMatches(t, stake_id, gtype_id) then
            t.cursor_rebuy_muted = muted and true or false
            n = n + 1
        end
    end
    return n
end

-- Click-to-deal entry point. Triggers the per-hand state machine on a
-- specific table. Returns false if the table is already animating a hand
-- or doesn't exist.
function GrindController:dealHand(idx)
    local t = self.pool:get(idx)
    if not t or t:isBusy() then return false end
    -- Stack must be positive to play. Hitting 0 means the table is busted
    -- and the player must :rebuyTable before dealing again.
    if (t.stack or 0) <= 0 then return false end
    if Constants.DEBUG.HAND_ANALYTICS then
        t._hand_start_t = love.timer.getTime()
    end
    -- Cutting Board: a hand the player dealt (not a cursor's click)
    -- carries the streak's multiplier, fixed now, and reports back when
    -- it resolves. Stamped BEFORE :deal, which prices the hand (the
    -- payout is computed at the deal, Table:deal reads _hand_mult there).
    t._dealt_by_player = not self._deal_by_cursor
    -- The swarm's mark: this hand was a cursor's click. Every hand dealt
    -- off it on the house's clock inherits the mark (dealIdleTable), so
    -- the Swarm deck levels on a cursor's chain and not on the player's.
    t._swarm_deal = self._deal_by_cursor == true
    local mc = self.ctx and self.ctx.manual_combo
    if t._dealt_by_player and mc then
        t._hand_mult = math.min(mc.cap or 2, 1 + (mc.value or 0) * (self.manual_combo or 0))
    else
        t._hand_mult = nil
    end
    local ok = t:deal(self.ctx)
    if not ok then
        t._dealt_by_player, t._hand_mult = nil, nil
    else
        self:_dealFx(t)
        -- New hand, new pile: clear any spent detonation so the pot draws
        -- again. Set here rather than in Table:deal because these are view
        -- FX fields.
        t.pot_exploded, t.pot_explode_pending = nil, nil
        -- The player's (or a cursor's) deal is a moment procs fire on: the
        -- Energy Drink deals the same-stake Zoom tables beside this one.
        self:_announce("on_deal", { table = t, spread = false })
    end
    return ok
end

function GrindController:_tickRateTrace(st, dt)
    local net = st.run_hand_net or 0
    local last = self._rt_last_net
    self._rt_last_net = net
    local rt = st.run_rate_trace
    if not rt then
        rt = { w = RateTicker.bucket_s or 5, t = 0, b = { 0 } }
        st.run_rate_trace = rt
        last = net        -- a fresh graph starts at what the run has now
    end
    if last == nil then last = net end   -- first frame after a load
    local b = rt.b
    b[#b] = b[#b] + (net - last)
    rt.t = rt.t + dt
    while rt.t >= rt.w do
        rt.t = rt.t - rt.w
        b[#b + 1] = 0
        local cap = RateTicker.buckets or 90
        if #b - 1 >= cap then
            -- Merge the finished buckets in pairs; the open one carries on.
            local open = b[#b]
            local merged, n = {}, #b - 1
            for i = 1, n - 1, 2 do merged[#merged + 1] = b[i] + b[i + 1] end
            if n % 2 == 1 then merged[#merged + 1] = b[n] end
            merged[#merged + 1] = open
            rt.b, b = merged, merged
            rt.w = rt.w * 2
        end
    end
end

-- Defensive sound dispatch — single line so each call site stays terse.
-- opts is an optional table forwarded to SoundService.playNamed
-- (volume_mult etc.) for tier-scaled feedback.
function GrindController:_playNamed(name, opts)
    local sounds = self.game.sounds
    if sounds and sounds.playNamed then sounds.playNamed(name, opts) end
end

-- ── Chip-flight emission helpers ─────────────────────────────────────
-- Each helper composes a denomination breakdown and pushes a burst
-- descriptor onto self.pending_bursts. GrindView drains the queue each
-- frame, builds render closures, and dispatches to services/FlightSystem.
-- This file holds NO views/* require — the controller stays in the data
-- layer, the view owns rendering.
--
-- Anchors come from services/AnchorRegistry, written by views/TablePanel
-- per draw under TableModel.anchorKey(t, slot). The bankroll-pile anchor
-- is registered separately by GrindView under "bankroll".

-- Palette for an amount that may be a PAYOUT rather than table money —
-- see services/DenominationBreakdown.paletteForAmount for the why.
local function _paletteForAmount(stake_id, amount)
    return Denoms.paletteForAmount(ChipData, stake_id, amount)
end

-- Bottom-edge fallback for "this thing has no anchor yet" cases (first
-- frame after table add — the view hasn't drawn yet so positions aren't
-- known). Reads viewport from DI rather than poking love.graphics.
function GrindController:_offscreenAnchor(x_hint)
    local v = self.game.viewport or { w = 0, h = 0 }
    return { x_hint or (v.w * 0.5), v.h + 80 }
end

local function _anchor(t, slot)
    return AnchorRegistry.get(TableModel.anchorKey(t, slot))
end

function GrindController:_emitBuyInChips(t, amount)
    if not t or amount <= 0 then return end
    local you     = _anchor(t, "you")
    local bank_xy = AnchorRegistry.get("bankroll")
    if not you or not bank_xy then return end
    local stake   = Lookups.findById(Stakes,t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForAmount(t.stake_id, amount)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(bank_xy, you, chips, {
        kind          = "stack",
        amount        = amount,
        arrival_sound = "chip_land_you",
        source_key    = "bankroll",
        dest_key      = TableModel.anchorKey(t, "you"),
    })
end

function GrindController:_emitCashOutChips(t, amount)
    if not t or amount <= 0 then return end
    local you     = _anchor(t, "you")
    local bank_xy = AnchorRegistry.get("bankroll")
    if not you or not bank_xy then return end
    local stake   = Lookups.findById(Stakes,t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForAmount(t.stake_id, amount)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(you, bank_xy, chips, {
        kind          = "stack",
        amount        = amount,
        arrival_sound = "chip_land_bankroll",
        source_key    = TableModel.anchorKey(t, "you"),
        dest_key      = "bankroll",
    })
end

-- Tournament cash-out: pot/center → bankroll pile. Same shape as cash-out
-- but anchored to the table's pot center (the chip pile from the final
-- hand) so the burst visually originates from where the action ended.
function GrindController:_emitKoPayoutChips(t, amount)
    if not t or amount <= 0 then return end
    local bank_xy = AnchorRegistry.get("bankroll")
    if not bank_xy then return end
    local v       = self.game.viewport or { w = 0, h = 0 }
    local pot     = _anchor(t, "pot")
    local center  = _anchor(t, "center")
    local source  = pot
                    or center
                    or { v.w * 0.5, v.h * 0.5 }
    local stake   = Lookups.findById(Stakes,t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForAmount(t.stake_id, amount)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(source, bank_xy, chips, {
        kind          = "stack",
        amount        = amount,
        arrival_sound = "chip_land_bankroll",
        source_key    = pot and TableModel.anchorKey(t, "pot") or nil,
        dest_key      = "bankroll",
    })
end

function GrindController:_emitResolutionChips(r, tbl, overflow_amount)
    if not tbl then return end
    local you_xy = _anchor(tbl, "you")
    local pot_xy = _anchor(tbl, "pot")
    if not you_xy or not pot_xy then return end
    -- r.delta is a payout, not table money — at high multipliers it runs
    -- straight past what the stake's four chips can express.
    local palette = _paletteForAmount(tbl.stake_id, math.abs(r.delta or 0))
    local tier    = r.tier or "medium"
    -- No per-tier burst cap here any more. These are pile-to-pile
    -- transfers: capping the count would leave the destination short by
    -- every chip the cap declined to carry. The pile's own tier already
    -- decides how many chips there are to move (data/chips.lua
    -- tier_chip_target), which is the honest version of the same knob.
    -- Per-stake chip tint (data/stake_themes.lua) — T6 = warm gold cast,
    -- T1 = desaturated dim, etc. Multiplied into the chip body color
    -- inside Chips.drawChip.
    local stake_theme = StakeThemes[tbl.stake_id]
    local chip_tint   = stake_theme and stake_theme.chip_tint

    -- The script's pot_push handler owns the entire payout — it
    -- fabricates whatever the multipliers added on top of the visible
    -- pot and splits it across the stack and the bankroll per the
    -- buy-in cap, whether or not the pot detonated. So the overflow
    -- spill below skips when the push pays out (it would be the same
    -- chips a second time).
    local push_pays_out = r.delta > 0

    if overflow_amount and overflow_amount > 0 and not push_pays_out then
        local v = self.game.viewport or { w = 0, h = 0 }
        local bank_xy = AnchorRegistry.get("bankroll")
                        or { v.w * 0.5, v.h - 30 }
        local chips = Denoms.breakdown(overflow_amount, ChipData.denominations,
                                       ChipData.full_palette,
                                       ChipData.tier_chip_target,
                                       Denoms.tierFromAmount(overflow_amount))
        self:_queueBurst(you_xy, bank_xy, chips, {
            kind          = "stack",
            amount        = overflow_amount,
            arrival_sound = "chip_land_bankroll",
            source_key    = TableModel.anchorKey(tbl, "you"),
            dest_key      = "bankroll",
        })
    end
end

-- Detonation for celebrations with NO pot pile on screen to come apart —
-- the tournament win, whose felt-center pot slot holds the HAND x/x counter
-- instead of chips. Forms a pile out of the amount at `origin` and blows it
-- apart in the same motion.
--
-- The cash-table stack does NOT come through here: that pile is real and
-- already drawn, so it detonates in place via the pot_explode_pending flag
-- (see the resolution FX block above).
--
-- Chip count is whatever the breakdown produces — never padded out to a
-- target, so this stays the real chips rather than a multiplied copy.
-- `origin` is the table's center anchor, which carries the panel size —
-- the burst scales to the table it came off rather than throwing a fixed
-- 300px cloud over a panel that may be a quarter that wide.
function GrindController:_emitAmountExplosion(origin, amount, stake_id)
    if not origin or not amount or amount <= 0 then return end
    local chips = Denoms.breakdown(amount, ChipData.denominations,
                                   _paletteForAmount(stake_id, amount),
                                   ChipData.tier_chip_target,
                                   Denoms.tierFromAmount(amount))
    if not chips or #chips == 0 then return end
    local stake_theme = StakeThemes[stake_id]
    self:_queueScatter(origin, chips, {
        chip_tint = stake_theme and stake_theme.chip_tint,
        within    = (origin[3] and origin[4]) and { origin[3], origin[4] } or nil,
    })
end

-- What a rebuy at table `idx` costs right now: the stake's buy-in less
-- ctx.rebuy_discount. DETERMINISTIC — free_rebuy_chance is deliberately not
-- rolled here, because the view calls this every frame to label the REBUY
-- button and to test affordability; rolling would reroll on every draw. The
-- free roll happens once, inside rebuyTable, and only ever lowers the price.
-- Mirrors buyInMultFor: the controller owns cost math, the view reads it.
function GrindController:rebuyCostFor(idx)
    local t = self.pool:get(idx)
    if not t then return 0 end
    local stake  = Lookups.findById(Stakes, t.stake_id)
    local buy_in = (stake and stake.buy_in) or 0
    -- Discounts are additive across sources (Short Stack, Rebuy Sticky
    -- Note, Wacom Tablet) and can sum past 100%; a rebuy is free at that
    -- point, never a payout.
    local discount = (self.ctx and self.ctx.rebuy_discount) or 0
    return buy_in * math.max(0, 1.0 - discount)
end

-- Refill a busted table's stack to a fresh 100bb buy-in by spending from
-- bankroll. No-op if the table isn't actually busted, or if the player
-- can't afford the rebuy.
-- `opts.free` waives the price (the Medical Poster's knockout revive).
function GrindController:rebuyTable(idx, opts)
    local t = self.pool:get(idx)
    if not t then return false end
    if (t.stack or 0) > 0 then return false end
    local stake = Lookups.findById(Stakes,t.stake_id)
    local buy_in = (stake and stake.buy_in) or 0
    local cost   = self:rebuyCostFor(idx)
    if opts and opts.free then cost = 0 end
    if self.ctx and cost > 0 then
        local free_chance = self.ctx.free_rebuy_chance or 0
        if free_chance > 0 and love.math.random() < free_chance then
            cost = 0
            self:itemFired("free_rebuy_chance", t)
        end
    end
    local state = self.game.state
    if state.bankroll < cost then return false end
    state.bankroll = state.bankroll - cost
    t.stack = buy_in
    -- Tournament tables: rebuy is also "register again" — reset the
    -- per-tournament counter so the next DEAL starts a fresh 8-hand run.
    -- Sync the parallel save arrays so the next autosave tick captures
    -- the post-rebuy state cleanly.
    if t.ko then t.ko:reset() end
    -- Grant deck XP for rebuy (carries the table's buy-in for count rules).
    self:_grantDeckXp({
        type           = "table_rebuy",
        stake_tier_idx = Lookups.indexById(Stakes, t.stake_id),
        stake_buy_in   = buy_in,
    })
    -- Procs that ride a rebuy (Nightstand's heat).
    self:_announce("on_rebuy", { table = t })
    -- Ungated mirror — catalog gates (Night Table, Medical Kit) read this
    -- one, so it has to tick in Act 1 too.
    state.total_rebuys = (state.total_rebuys or 0) + 1
    -- Lifetime counter drives the Short Stack deck's unlock. Gated like the
    -- other lifetime_* counters (accrue only once the deck system exists).
    if Decks.systemUnlocked(state) then
        Decks.checkPendingUnlocks(state, self.game.unlock_rules)
    end
    -- Bankroll → YOU stack chip burst (table positions are already known
    -- because the table has been on screen long enough to bust).
    self:_emitBuyInChips(t, buy_in)
    self:_playNamed("rebuy_clack")
    -- Auto-deal the first hand so REBUY is a one-click flow (was two:
    -- click REBUY, then click DEAL). The cursor swarm picks up subsequent
    -- hands as usual.
    self:dealHand(idx)
    return true
end

-- Map per-hand state-machine transitions to sound names. Called from
-- update() with (prev_state, new_state, table). Tables share a single
-- audio queue (sounds clone-on-play), so multiple tables' transitions in
-- the same frame don't cut each other off.
function GrindController:_playStateTransitionSound(_prev, new_state, t)
    local sounds = self.game.sounds
    if not sounds or not sounds.playNamed then return end

    if new_state == "dealing" or new_state == "flop"
       or new_state == "turn" or new_state == "river" then
        sounds.playNamed("card_dealt")
    elseif new_state == "showdown" then
        sounds.playNamed("hole_card_flip")
    elseif new_state == "settling" then
        -- Tier-keyed pot sound: a small win clicks like one chip; a stack
        -- lands like a stack with coins layered. data/sounds.lua defines all
        -- 8 entries (4 tiers × win/loss).
        local tier = t.outcome_tier or "medium"
        local key  = (t.outcome_won and "pot_won_" or "pot_lost_") .. tier
        sounds.playNamed(key)
    end
end

-- SHOVE-button intent: the COMMIT. Banks the run's pending chips (locked-in
-- bounties only convert to spendable chips if the player actually pulls the
-- trigger), zeroes the pending counters IN THE SAME WRITE, records the
-- commit in state.shove_pending, saves, and flips the state machine to the
-- gauntlet. The zero + shove_pending + immediate save are load-bearing:
-- autosave and love.quit both fire from the shove screen, and before this a
-- save written there carried banked chips AND a still-pending
-- chips_this_run AND the un-reset run — close on the shove screen, reload,
-- and the same run re-banked the same chips forever. Now the bank and the
-- spend of the run are one atomic fact on disk; the shove screen reads the
-- banked amount from shove_pending.chips for its readout, and TitleState
-- routes a save with shove_pending straight back into the shove.
function GrindController:initiateShove()
    local state = self.game.state
    local banked      = state.chips_this_run or 0
    local anti_banked = state.anti_chips_this_run or 0
    state.chips      = state.chips + banked
    state.anti_chips = (state.anti_chips or 0) + anti_banked
    state.chips_this_run      = 0
    state.anti_chips_this_run = 0
    -- The only place this is set: the tutorial's SHOVE gate needs a signal
    -- that means "actually shoved", not "started another run".
    state.has_shoved = true
    state.shove_pending = { chips = banked, anti_chips = anti_banked }
    self.game.save(true)
    self.game.state_machine:switch("shove")
end

-- Convenience: deal every idle table in one call. Useful as a future
-- "auto-play" upgrade hook and as a debug shortcut.
function GrindController:dealAll()
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if not t:isBusy() and (t.stack or 0) > 0 then
            if t:deal(self.ctx) then
                self:_dealFx(t)
                t.pot_exploded, t.pot_explode_pending = nil, nil
                n = n + 1
            end
        end
    end
    return n
end

return GrindController
