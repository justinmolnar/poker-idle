-- data/routers.lua
--
-- Routers: "when something is about to land, send it somewhere else, or
-- make it arrive as something else". Pure data, the same shape bargain as
-- data/procs.lua — an item points at one of these by id
-- (`{ kind = "router", router = "console_television_intercept" }`) and the dispatch does
-- the rest, so adding a router is an edit to this file and the catalog.
--
-- ─── HOW THIS DIFFERS FROM A PROC ───────────────────────────────────────
-- A proc answers "X happened, so do Y". A router answers "Y is about to
-- happen to that table" and gets to change the answer. Neither the thing
-- that fired nor the table that ends up holding it knows a router exists;
-- services/ProcRegistry asks the bus where a delivery lands and takes the
-- answer. That is the whole reason the bus has a second verb.
--
--   kind     which registered router function runs (models/table_procs)
--   chance   0..1, rolled per delivery. Routers are interference, and
--            interference that always works stops being a table's luck and
--            starts being the player's arithmetic.
--   ghost    catalog item id whose sprite + sound plays when it takes
--            effect. nil for the ones that should feel like weather.
--
-- ─── WHY THESE ARE RARE ─────────────────────────────────────────────────
-- A router runs on EVERY delivery while its item is owned, which is the
-- most invasive thing an item can do in this game. Two exist, both cost
-- 30+ {chip}, and both belong to a mode's identity rather than being
-- general-purpose. Adding a third should need an argument.

return {

    -- Console Television. The tank reaches over and takes the hit meant for
    -- the table beside it. 6-max is the only mode that WANTS a full inbox
    -- (its own items convert what lands on it into tier odds), so stealing
    -- its neighbours' statuses is the mode reading its own strengths.
    --
    -- Deliberately takes the good and the bad alike: a table that eats
    -- everything aimed near it is a real decision about where to sit it,
    -- not a free filter.
    console_television_intercept = {
        kind   = "steal_nearby",
        chance = 0.50,
        gtype  = "six_max",
        radius = 1,
        ghost  = "console_television",
    },

    -- Window. A running tournament bends what arrives around it: along its
    -- row things land warmer, down its column they land colder. Two tables
    -- can be equally close in the pool's order and get opposite treatment,
    -- which is the first time in the game that WHERE a table sits on the
    -- board changes what happens to it rather than merely how far it is.
    --
    -- Only while a tournament is actually running, so it comes and goes
    -- with the tournament rather than being a permanent property of a
    -- column.
    -- Anchor deck (levels 1-4): tilts aimed beside a six-max land on it.
    anchor_taunt = {
        kind   = "taunt_tilt",
        gtype  = "six_max",
        radius = 1,
        ghost  = nil,
    },
    -- Window: while a tournament runs, tilts aimed at its stake have a
    -- 35% chance to arrive as heat.
    window_bend = {
        kind   = "tournament_stake",
        chance = 0.35,
        map    = { tilt = "heater" },
        ghost  = nil,   -- weather, not an event
    },
    -- Waste Basket: the corner slot is the basket. A tilt aimed anywhere
    -- (not at a six-max) lands on the corner table instead, 35% of the
    -- time; corrupt 70%. Anchor's taunt takes precedence when owned.
    basket_corner = {
        kind   = "basket_corner",
        chance = 0.35,
        ghost  = "waste_basket",
    },
    basket_corner_corrupt = {
        kind   = "basket_corner",
        chance = 0.70,
        ghost  = "waste_basket",
    },
    -- Dish Soap: a tilt lands on the table beside its target instead, 25%.
    dish_soap_deflect = {
        kind   = "tilt_deflect",
        chance = 0.25,
        radius = 1,
        ghost  = "dish_soap",
    },
}
