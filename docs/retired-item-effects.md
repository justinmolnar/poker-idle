# Retired item effects

Eleven catalog items were repurposed into procs during the gametype-identity
redesign. **The sprites, names, descriptions, room positions and unlock gates
stayed** — only what each item DID was replaced. This file is the record of
what it used to do, kept verbatim so any of it can be put back by pasting a
block into `data/catalog.lua`.

Retired 2026-08-27. See `docs/gametype-identity-redesign.md` for why, and
`data/procs.lua` for what each item does now.

## Why these eleven

They were picked as a set, not one at a time. Two things they have in common:

- **Flat and passive.** Almost all of them are a number that is always true:
  a chance, a multiplier, a floor, a ceiling. The redesign's whole premise is
  that stats are the boring baseline and conversions are the content.
- **Late and expensive.** Eight of the eleven cost 24+ {chip}, which is where
  the catalog most needed things worth saving for.

## What this costs, honestly

**Nine effect kinds are left with no catalog user**: `first_bounty_bonus`,
`auto_win_chance`, `focus_penalty_reduce_mult`, `free_rebuy_chance`,
`payout_double_chance`, `win_dist_shift`, `loss_tier_ceiling`,
`win_tier_floor`, `mtt_payout_boost`. Their applicators in
`models/poker_effects.lua` and their entries in `data/effects.lua` stay —
they are the vocabulary, and run upgrades or decks may still use some — but
nothing in the catalog reaches for them any more.

**Two systems lose most of their support:**

- **Focus.** `gaming_chair` (penalty halved) and `console_tv` (+2 capacity)
  both go, leaving `second_monitor` (+1 capacity) as the only catalog item
  that touches focus at all.
- **Tournament payouts.** `diploma` was the last `mtt_payout_boost` in the
  catalog after `prize_vase` was repurposed. With it gone, nothing scales
  tournament cash. That was a locked decision earlier in the redesign
  ("MTT keeps its cash payouts"), and retiring `diploma` reverses it.

Both are deliberate, and both are the first place to look if tournaments or
multi-tabling feel unsupported later.

---

## TESTING OVERRIDES — CLOSED OUT 2026-08-28

The overrides below were restored (with adjustments) in the catalog
progression pass: real costs are back on all fifteen items plus Receipt
Printer (balanced fresh at 30, mid phase, total_jackpots >= 100). Items
that entered a `requires` chain did NOT get their old stat gates back —
the chain is their gate (microwave, prize_vase and wall_clock are chain
BASES with no `requires`, so they kept theirs). The bounty ladder
(data/stakes.lua chip_award) was scaled ~3.5x in the same pass so chip
income can actually pay for the shelf; sim/run.lua's income model is now
bounty-based instead of circular. The table below stays as the historical
record of the override period.

## (historical) TESTING OVERRIDES — restore before shipping

The eleven were made cheap and ungated on 2026-08-27 so the engine could be
played at real table speeds without dev hotkeys: how long a build takes to
come together, and whether the loop reads, are questions you cannot answer
by granting yourself {chip}.

**This is not balance.** Prices are 2-5 {chip} and every gate is gone, so
the whole set is buyable inside a couple of runs. Put these back before any
build goes out.

| item | real cost | real unlock gate | prerequisite |
|---|---|---|---|
| `dogs_playing_poker` | 8 | total_chips_banked >= 25 | - |
| `gaming_chair` | 15 | total_hands_overwhelmed >= 500 | - |
| `wall_clock` | 20 | total_hands_played >= 5000 | - |
| `first_aid_kit` | 24 | total_rebuys >= 250 | - |
| `high_roller_pass` | 28 | highest_stake_idx >= 4 | - |
| `microwave` | 28 | total_jackpots >= 500 | - |
| `diploma` | 28 | - | `prize_vase` |
| `window` | 30 | lifetime_money_won >= 50000000 | - |
| `fire_extinguisher` | 35 | total_stack_losses >= 250 | - |
| `blackout_curtains` | 36 | decks_maxed >= 1 | - |
| `console_tv` | 40 | total_hands_overwhelmed >= 2500 | - |

Four more found missed and cheapened the same way on 2026-08-28 — the
instruction was ALL of the new identity/proc items, and these carry procs
too (the KO trio and the ratchet):

| item | real cost | real unlock gate | prerequisite |
|---|---|---|---|
| `prize_vase` | 18 | total_mtt_wins >= 1 | - |
| `pc_tower` | 12 | - | - |
| `curved_monitor` | 20 | - | - |
| `shredder` | 26 | - | - |

The `unlock` block shape, for restoring one:

```lua
        unlock = {
            kind      = "total_chips_banked",
            threshold = 25,
            text      = "{chip} banked",
        },
```

`window`'s carried one extra line, because it is the only dollar-denominated
gate in the catalog and needs the money formatter for its sticker counter:

```lua
            format    = "money",
```

Nothing else was touched: `act` is metadata rather than a gate (only
`requires_act3` is enforced, and none of these have it), so the items sit
where they always did.

---

## The blocks

### `dogs_playing_poker` — Dogs Playing Poker (8)

> First {chip} bounty each run pays +1.

```lua
        effects     = {
            { kind = "shove_rate_add",     value = 0.006 },
            { kind = "first_bounty_bonus", value = 1 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "first_bounty_bonus", value = 8 },
            },
            effect_text = "First {chip} bounty each run pays +8.",
        },
```

### `gaming_chair` — Gaming Chair (15)

> Focus penalty halved.

```lua
        effects     = {
            { kind = "shove_rate_add",            value = 0.012 },
            { kind = "focus_penalty_reduce_mult", value = 0.5 },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "focus_penalty_immune" },
                { kind = "overcap_loss_mult", value = 3.0 },
            },
            effect_text = "No focus penalty. Tables over the cap lose 3× bigger.",
        },
```

### `wall_clock` — Wall Clock (20)

> 3% of hands win outright.

```lua
        effects     = {
            { kind = "shove_rate_add",  value = 0.013 },
            { kind = "auto_win_chance", amount = 0.03 },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "auto_win_chance", amount = 0.25 },
            },
            effect_text = "25% of hands win outright.",
        },
```

### `first_aid_kit` — First Aid Kit (24)

> 20% of rebuys are free.

```lua
        effects     = {
            { kind = "shove_rate_add",    value = 0.012 },
            { kind = "free_rebuy_chance", value = 0.20 },
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "free_rebuy_chance", value = 0.6 },
            },
            effect_text = "60% of rebuys are free.",
        },
```

### `high_roller_pass` — High Roller Pass (28)

> Buy-ins 30% cheaper at NL1K and above.

```lua
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "buy_in_mult",    value = 0.70, tier_min = 4 },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "buy_in_mult", value = 0.1, tier_min = 4 },
            },
            effect_text = "Buy-ins 90% cheaper at NL1K and above.",
        },
```

Note: `vouchers` still carries an untiered `buy_in_mult`, so buy-in discounts
survive this one.

Note (2026-08-28): the tournament-aura repurpose this entry documented was
itself replaced — heat became interrupt-only, so a continuous heater aura
could no longer mean anything. The item is now `tourney_backing`: cash
games at a stake get +1% win chance per tournament finished by a
still-open tournament table there (see data/effects.lua). The restore row
above (price 28, gate) still applies as-is.

### `microwave` — Microwave Oven (28)

> 5% chance a pot pays double.

```lua
        effects     = {
            { kind = "shove_rate_add",       value = 0.014 },
            { kind = "payout_double_chance", value = 0.05 },
        },
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "payout_double_chance", value = 0.45 },
            },
            effect_text = "45% chance a pot pays double.",
        },
```

### `diploma` — Framed Diploma (28)

> Tournament cashes pay 5× / 10× / 20×.

Carries `requires = "prize_vase"`, which is a progression gate rather than a
mechanical one and is unaffected by the repurpose.

```lua
        effects     = {
            { kind = "shove_rate_add",   value = 0.014 },
            { kind = "mtt_payout_boost", value = 2 },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "mtt_payout_boost", value = 4 },
            },
            effect_text = "Tournament cashes pay 40× / 80× / 160×.",
        },
```

### `window` — Window (30)

> At NL1K and above, wins skew bigger.

```lua
        effects     = {
            { kind = "shove_rate_add", value = 0.016 },
            { kind = "win_dist_shift",
              shift = { small = -0.10, medium = -0.05, large = 0.08, jackpot = 0.07 },
              tier_min = 4 },
        },
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "win_dist_shift", shift = { small = -0.4, jackpot = 0.4 }, tier_min = 4 },
            },
            effect_text = "At NL1K and above, 40% more wins land as {w:stack}.",
        },
```

### `fire_extinguisher` — Fire Extinguisher (35)

> Losses never roll {l:stack}.

```lua
        effects     = {
            { kind = "shove_rate_add",     value = 0.018 },
            { kind = "loss_tier_ceiling",  tier = "large" },
        },
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "loss_dist_shift", shift = { small = -0.5, jackpot = 0.5 } },
            },
            effect_text = "Half of all losses roll {l:stack}.",
        },
```

### `blackout_curtains` — Blackout Curtains (36)

> Wins never roll {w:small}.

```lua
        effects     = {
            { kind = "shove_rate_add", value = 0.018 },
            { kind = "win_tier_floor", tier = "medium" },
        },
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "earnings_per_tier", value = 0.5 },
            },
            effect_text = "Wins pay +50% more per stake tier.",
        },
```

### `console_tv` — Console Television (40)

> +2 focus capacity. Wins pay 10% less.

The only item in the catalog with a naked downside and no identity paying
for it.

```lua
        effects     = {
            { kind = "shove_rate_add",     value = 0.014 },
            { kind = "focus_capacity_add", value = 2 },
            { kind = "earnings_mult",      value = 0.90 },
        },
        corrupt = {
            cost_achip = 13,
            effects = {
                { kind = "focus_capacity_add", value = 10 },
                { kind = "earnings_mult", value = 0.5 },
            },
            effect_text = "+10 focus. Wins pay 50% less.",
        },
```

---

## Previously retired

Five items were repurposed before these, in chunks 2 and 3. Their old effects
are recorded in the git history of `data/catalog.lua` rather than here.

| item | used to be | is now |
|---|---|---|
| `receipt_printer` | a shove-rate stat | the Zoom cascade |
| `prize_vase` | tournament payout boost | the run ratchet |
| `curved_monitor` | +1 focus capacity | KO heater |
| `pc_tower` | hands 15% faster | KO tier mark |
| `shredder` | losses 15% softer | KO buy-in refund |

---

## Retired 2026-09-07: the rack shelf's cuts

The rack shelf had twelve items and a shelf is eight. The designer cut
these four, keeping one of every family on the shelf (the Gift Box for
starting money, the Fridge for the loss void, the Rebuy Note for rebuy
money, the Bookshelf and Ring Binder for the rack). Each carries
`retired = true` in `data/catalog.lua`: hidden from the book and the shelf
lint, id and effects kept so a save that owns one still gets it and the
object stays in the room. To bring one back, delete the flag and list it
on a shelf. Recorded verbatim as they stood when cut.

```lua
    {
        id          = "stash_box",
        name        = "Stash Box",
        effect_text = "+$5 starting bankroll.",
        description = "Folded cash tucked away in a cardboard box.",
        sprite      = "stash_box",
        phase       = "mid",
        cost_chip     = 6,
        unlock = { kind = "total_chips_banked", threshold = 10, text = "{chip} {c:chip:banked}" },
        effects     = {
            { kind = "shove_rate_add",     value = 0.006 },
            { kind = "start_bankroll_add", value = 5 },
        },
        corrupt = {
            cost_achip = 3,
            effects = { { kind = "start_bankroll_add", value = 100000 } },
            effect_text = "+$100,000 starting bankroll.",
        },
    },
    {
        id          = "rubber_duck",
        name        = "Rubber Duck",
        effect_text = "Your run's first loss is voided.",
        description = "Squeak. It never happened.",
        sprite      = "rubber_duck",
        phase       = "demo",
        cost_chip     = 5,
        effects     = {
            { kind = "shove_rate_add", value = 0.005 },
            { kind = "void_first_loss" },
        },
        unlock = { kind = "total_busts", threshold = 100, text = "tables {c:lost:busted}" },
        corrupt = {
            cost_achip = 2,
            effects = { { kind = "loss_tier_shift", from = "small", to = "stack", chance = 1/3 } },
            effect_text = "1 in 3 chance: {l:small} {arrow} {l:stack}.",
        },
    },
    {
        id          = "electric_kettle",
        act         = 2,
        name        = "Electric Kettle",
        effect_text = "A table {c:lost:busts}: 30% of its buy-in comes back.",
        description = "Boils fast. Whistles louder.",
        sprite      = "electric_kettle",
        phase       = "late",
        cost_chip   = 11,
        effects     = {
            { kind = "shove_rate_add",   value = 0.012 },
            { kind = "bust_refund_pct",  value = 0.30 },
        },
        unlock = { kind = "total_busts", threshold = 300, text = "tables {c:lost:busted}" },
        corrupt = {
            cost_achip = 8,
            effects = { { kind = "bust_refund_pct", value = 1.2 } },
            effect_text = "A table {c:lost:busts}: 120% of its buy-in comes back.",
        },
    },
    {
        id          = "calculator",
        name        = "Calculator",
        effect_text = "{c:upgrade:Sharper_Reads}, {c:upgrade:Pot_Control} and {c:upgrade:Cursor_Speed} +15%.",
        description = "Solar. Works under the desk lamp.",
        sprite      = "calculator",
        phase       = "mid",
        cost_chip     = 7,
        unlock = { kind = "total_upgrade_levels", threshold = 130, text = "{c:upgrade:upgrade} levels bought" },
        effects     = {
            { kind = "shove_rate_add",            value = 0.006 },
            { kind = "run_upgrade_strength_mult", value = 0.15 },
        },
        corrupt = {
            cost_achip = 4,
            effects = { { kind = "run_upgrade_strength_mult", value = 1.5 } },
            effect_text = "{c:upgrade:Sharper_Reads}, {c:upgrade:Pot_Control} and {c:upgrade:Cursor_Speed} +150%.",
        },
    },
```

Effect kinds left with no catalog user by these: `start_bankroll_add`,
`void_first_loss`, `bust_refund_pct`. Their applicators stay.

**The Calculator came back on 2026-09-07 (later the same day)**: the Value
Buys card stopped being a repeat of a shelf card, so the Rack had a free
slot, and the Stash Box and Kettle are covered by other rack items. Its
entry above is what is live again.

## Retired 2026-09-07 (b): the cursors shelf repurposed

The swarm got its own weather (two cursors clashing rolls a tilt on the
table under them; see `Balance.CURSOR_CLASH`), and three items on the
Cursors shelf were rewritten around it. **Ids, names, sprites and unlock
gates stayed.** These are the entries as they were, verbatim.

```lua
    {
        id            = "desk_lamp",
        refactor        = true,   -- flagged for refactor (designer tag); the book washes it red
        act           = 2,
        name          = "Desk Lamp",
        effect_text   = "Placeholder: this item is being rewritten.",
        description   = "Optical sensors need light to work.",
        sprite        = "desk_lamp",
        phase         = "late",
        cost_chip     = 10,
        requires    = "box_of_mice",
        unlock = {
            kind      = "total_cursor_deals",
            threshold = 3000,
            text      = "hands dealt by {c:upgrade:cursors}",
        },
        effects       = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "cursor_optical_sensor" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "cursor_optical_sensor" },
                { kind = "cursor_speed_mult", value = 1.5 },
            },
            effect_text = "{c:upgrade:Cursor} speed ×1.5.",
        },
    },
    {
        id            = "glass_partition",
        act           = 2,
        name          = "Glass Partition",
        effect_text   = "{c:upgrade:Cursors} pass through each other.",
        description   = "Everyone gets a lane.",
        sprite        = "glass_partition",
        phase         = "late",
        cost_chip     = 12,
        requires    = "laptop_terminal",
        effects       = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "cursor_collision_phasing" },
        },
    },
    {
        id            = "cleaning_robot",
        refactor        = true,   -- flagged for refactor (designer tag); the book washes it red
        act           = 2,
        name          = "Cleaning Robot",
        effect_text   = "Win a {w:stack}: {c:upgrade:cursor} speed ×2 for 10 seconds.",
        allow_numbers = { 2, 10 },
        description   = "Overdrive. It only speeds up after someone {c:won:wins} big. Nobody knows why.",
        sprite        = "cleaning_robot",
        phase         = "late",
        cost_chip     = 24,
        requires    = "gaming_keyboard",
        unlock = {
            kind      = "total_stacks",
            threshold = 500,
            text      = "{w:stack} {c:won:wins}",
        },
        effects       = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "cleaning_robot_overdrive" },
        },
    },
```

The robot's proc, from `data/procs.lua`:

```lua
    cleaning_robot_overdrive = {
        trigger = "on_stack_win",
        target  = { kind = "none" },
        payload = { kind = "timed_buff", buff = "cursor_speed_mult",
                    value = 2.0, t = 10 },
        ghost   = "cleaning_robot",
    },
```

Effect kinds deleted with them (applicators removed from
`models/poker_effects.lua`): `cursor_collision_phasing`,
`cursor_optical_sensor`. Second Monitor's corrupt line went from
`+6 FOCUS` to `+2 FOCUS and the penalty ×0.5` the same day (the board
cap became a full 6x6, so +6 overshot it).

## Retired 2026-09-07 (c): the Heads-Up odds cards

Heads-Up is the chip engine. Its two flat win-chance cards became the
engine's own dials (the Mirror throttles stack odds per Heads-Up table
open, the Dusty Console pays stacks more) and the shelf gained the Trophy
Shelf (a bounty sometimes pays double). **Ids, names, sprites and unlock
gates stayed.** Verbatim:

```lua
    {
        id          = "mirror",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Mirror",
        effect_text = "+10% {c:chance:odds} at {k:Heads-Up}.",
        description = "A nice big one. You should see yourself.",
        sprite      = "mirror",
        phase       = "demo",
        cost_chip     = 3,
        requires    = "wall_hanger",
        position    = { x = 160, y = 220 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.10, gtype = "hu" },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "win_chance_shift", amount = 0.35, gtype = "hu" },
            },
            effect_text = "+35% {c:chance:odds} at {k:Heads-Up}.",
        },
    },
    {
        id          = "dusty_console",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Dusty Console",
        effect_text = "+3% {c:chance:odds} at {k:Heads-Up}.",
        description = "Two controllers. Built for one-on-one.",
        sprite      = "dusty_console",
        phase       = "mid",
        cost_chip   = 5,
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "hu",
            threshold = 1000,
            text      = "Heads-Up hands",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "win_chance_shift", amount = 0.03, gtype = "hu" },
        },
    },
```

## Retired 2026-09-07 (d): Desk Speakers

The Heat & Tilt shelf's one flat odds card became the room-runs-hot card
(every heater burning lifts every table). **Id, name, sprite and unlock
gate stayed.** Verbatim:

```lua
    {
        id          = "desk_speakers",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        act         = 2,
        name        = "Desk Speakers",
        effect_text = "+5% {c:chance:odds} at {k:tournaments}.",
        description = "Two small ones. The bass is all wall.",
        sprite      = "desk_speakers",
        phase       = "mid",
        cost_chip   = 10,
        unlock = {
            kind      = "total_chips_banked",
            threshold = 160,
            text      = "{chip} {c:chip:banked}",
        },
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.05, gtype = "ko" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "win_chance_shift", amount = 0.30, gtype = "ko" },
                { kind = "win_chance_shift", amount = -0.10, gtype = "six_max" },
            },
            effect_text = "+30% {c:chance:odds} at {k:tournaments}, -10% at {k:6-Max}.",
        },
    },
```

The same day the shelf's Value Buys intro changed from Dish Soap (a
router, nothing to teach) to the Nightstand (rebuy, heater), and two new
items joined it: the Gas Stove (a heater wins one more hand) and the Cast
Iron Pan (a tilt landing on a heater counts but the heater keeps its hand).
The rule "no deck lengthens a punch" in data/decks.lua's header was an
earlier pass's, not the designer's; struck.

## Retired 2026-09-07 (e): the 6-Max shelf's four flat cards

The tank's shelf had three cards about absorbing and converting punishment
and four flat stats that said nothing about 6-Max. The four became the
money half and the role half of the tank (Desk Plant: a tilt's hands lose
smaller; Red Rug: a large 6-Max win is sometimes the family pot; Space
Heater: tanking pays the neighbour; Laminated Blueprint: with every game
on the board a 6-Max win lights a table) and the Floor Plant joined (a
6-Max stack spills a size-up onto every neighbour). **Ids, names, sprites
and unlock gates stayed.** Verbatim:

```lua
    {
        id          = "desk_plant",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Desk Plant",
        effect_text = "+6% {c:chance:odds} at {k:6-Max}.",
        description = "Real. Someone waters it when you're not looking.",
        sprite      = "desk_plant",
        phase       = "mid",
        cost_chip   = 8,
        requires    = "bonsai",
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.06, gtype = "six_max" },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "win_chance_shift", amount = 0.35, gtype = "six_max" },
            },
            effect_text = "+35% {c:chance:odds} at {k:6-Max}.",
        },
    },
    {
        id          = "red_rug",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Red Rug",
        effect_text = "+2% {c:chance:odds} at the top-left table.",
        description = "Really ties the room together. The top-left table sits on it.",
        sprite      = "red_rug",
        phase       = "mid",
        cost_chip   = 8,
        unlock = {
            kind      = "total_hands_played",
            threshold = 6500,
            text      = "hands played",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "corner_win_chance", value = 0.02 },
        },
    },
    {
        id          = "space_heater",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Space Heater",
        effect_text = "{c:lost:Losses} ×0.8.",
        description = "Hums all night. The cold stops mattering.",
        sprite      = "space_heater",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 280, y = 200 },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 225,
            text      = "{l:stack} {c:lost:losses} taken",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.008 },
            { kind = "loss_mult",      value = 0.80 },
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "loss_mult", value = 3.0 },
            },
            effect_text = "{c:lost:Losses} ×3.",
        },
    },
    {
        id          = "laminated_blueprint",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        act         = 2,
        name        = "Laminated Blueprint",
        effect_text = "The deck in play earns ×1.5 XP.",
        description = "Wall blueprint chart for systematic study.",
        sprite      = "laminated_blueprint",
        phase       = "late",
        cost_chip   = 19,
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "deck_xp_mult",   value = 1.50 },
        },
        unlock = {
            kind      = "decks_unlocked_count",
            threshold = 5,
            text      = "decks unlocked",
            -- "???" until decks exist (Act 2)
            mystery   = { kind = "shove_r1_won" },
        },
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "deck_xp_mult", value = 8.0 },
            },
            effect_text = "The deck in play earns ×8 XP.",
        },
    },
```

Effect kinds left with no catalog user: `corner_win_chance`, `deck_xp_mult`.
Their applicators stay.

## Retired 2026-09-07 (f): the Zoom shelf

Zoom is the firehose: six times 6-Max's hands, tiny pots, a stack rate
capped near 4%, new opponents every deal. Four flat or cascade cards and
the Diploma's 1-in-100 board roll became fast-fold (Handheld: a loss deals
the next hand now; Headset: a tilt does not follow to the next hand),
volume as progression (Copy Machine: a Zoom hand counts as two), and the
speed loop (Receipt Printer: faster per adjacent Zoom; Washing Machine,
new: wins in a row deal faster; Framed Diploma: hands per second feed
Zoom's odds). **Ids, names, sprites and unlock gates stayed.** Verbatim:

```lua
    {
        id          = "handheld",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Handheld",
        effect_text = "+3% {c:chance:odds} at {k:Zoom}.",
        description = "Fits in a pocket. Fast games between fast games.",
        sprite      = "handheld",
        phase       = "mid",
        cost_chip   = 5,
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "zoom",
            threshold = 1200,
            text      = "Zoom hands",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "win_chance_shift", amount = 0.03, gtype = "zoom" },
        },
    },
    {
        id          = "headset",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Headset",
        effect_text = "+6% {c:chance:odds} at {k:Zoom}.",
        description = "Foam mic cover. Someone else's earwax.",
        sprite      = "headset",
        phase       = "mid",
        cost_chip   = 6,
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.06, gtype = "zoom" },
        },
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "zoom",
            threshold = 2600,
            text      = "Zoom hands",
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "win_chance_shift", amount = 0.35, gtype = "zoom" },
            },
            effect_text = "+35% {c:chance:odds} at {k:Zoom}.",
        },
    },
    {
        id          = "copy_machine",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        act         = 2,
        name        = "Copy Machine",
        effect_text = "The Receipt Printer also deals the empty {k:Zoom} tables.",
        see_also    = { "receipt_printer" },
        description = "The printer's big sibling.",
        sprite      = "copy_machine",
        phase       = "mid",
        cost_chip   = 19,
        requires    = "receipt_printer",
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "cascade_deals_empty" },
        },
    },
    {
        id          = "receipt_printer",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        act         = 2,
        name        = "Receipt Printer",
        effect_text = "Win a {w:stack} anywhere: every {k:Zoom} table finishes its hand now.",
        description = "Chatters out a slip for every table. Feed it more paper.",
        sprite      = "receipt_printer",
        phase       = "mid",
        cost_chip   = 19,
        -- Late-Act-1 machine at a late-Act-1 price: 1,100 stacks ≈
        -- shove seven at the measured ~155/shove (see the Candle's note).
        unlock = {
            kind      = "total_stacks",
            threshold = 1100,
            text      = "{w:stack} {c:won:wins}",
        },
        position    = { x = 330, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "proc", proc = "receipt_printer_cascade" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "proc", proc = "receipt_printer_cascade_corrupt" },
            },
            effect_text = "Win a {w:stack} anywhere: {k:every_table} finishes its hand now.",
        },
    },
    {
        id          = "framed_diploma",
        act         = 2,
        name        = "Framed Diploma",
        effect_text = "Win a hand: 1 in 100 chance {k:every_table} rolls 1 in 3 each for a {c:heat:heater}, a {c:tilt:tilt}, or nothing.",
        allow_numbers = { 1, 3 },   -- the roll's thirds are proc weights, not a chance field
        description = "Wall-mounted certificate. Handsome on the wall.",
        sprite      = "framed_diploma",
        phase       = "late",
        cost_chip     = 18,
        -- Millennium IS century, bigger — lesson two of the counter items.
        requires    = "wall_clock",
        position    = { x = 450, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "proc", proc = "framed_diploma_century" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "proc",          proc = "framed_diploma_century" },
                { kind = "earnings_mult", value = 0.70 },
            },
            effect_text = "Same, and {c:won:Winnings} ×0.7.",
        },
    },
```

Their procs, from `data/procs.lua`:

```lua
    receipt_printer_cascade = {
        trigger = "on_stack_win",
        target  = { kind = "gtype", gtype = "zoom", exclude_self = true },
        payload = { kind = "resolve_now" },
        ghost   = "receipt_printer",
    },
    receipt_printer_cascade_corrupt = {
        trigger = "on_stack_win",
        target  = { kind = "any_other" },
        payload = { kind = "resolve_now" },
        ghost   = "receipt_printer",
    },
    framed_diploma_century = {
        trigger = "on_hand_won",
        chance  = 1/100,
        target  = { kind = "all" },
        payload = { kind = "roll_status",
                    outcomes = { { status = "heater", weight = 1, magnitude = 0.35, t = 6 },
                                 { status = "tilt",   weight = 1, magnitude = 0.35, t = 5 },
                                 { weight = 1 } } },
        ghost   = "framed_diploma",
    },
```

Effect kind deleted with them: `cascade_deals_empty` (and its branch in
the `resolve_now` payload). `resolve_now` itself stays.

## Retired 2026-09-07 (g): the Stats shelf

The plain build, six cheap flat numbers, became numbers on conditions the
player arranges: stakes seated (Wall Hanger), a loss's d6 (Stack of
Books), the table in your hand (Lava Lamp), a table with nothing beside it
(Throw Pillow), a 6-Max reading as empty (Comfort Bed), empty cells beside
a table (Yellow Sticky Note), and the Cutting Board (new): the player's
own win streak. The Corkboard stays the flat intro; the Chrome Toaster
stays. **Ids, names, sprites and unlock gates stayed.** Verbatim:

```lua
    {
        id          = "wall_hanger",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Wall Hanger",
        effect_text = "{w:stack} {c:won:winnings} ×1.2.",
        description = "Sturdy wall hook for hanging your hat and gear.",
        sprite      = "wall_hanger",
        phase       = "demo",
        cost_chip     = 2,
        position    = { x = 120, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "stack_mult",   value = 1.20 },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "shove_rate_add", value = 0.15 },
                { kind = "stack_mult",   value = 5.00 },
            },
            effect_text = "{w:stack} {c:won:winnings} ×5.",
        },
    },
    {
        id          = "stack_of_books",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Stack of Books",
        effect_text = "1 in 4 chance: {w:small} {arrow} {w:medium}.",
        description = "Pile of bestselling self-help guides.",
        sprite      = "stack_of_books",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 280, y = 220 },
        unlock = {
            kind      = "total_hands_won",
            threshold = 250,
            text      = "hands won",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "win_tier_shift",
              from = "small", to = "medium", chance = 0.25 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "win_tier_shift", from = "small", to = "medium", chance = 1/2 },
            },
            effect_text = "1 in 2 chance: {w:small} {arrow} {w:medium}.",
        },
    },
    {
        id          = "lava_lamp",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Lava Lamp",
        effect_text = "1 in 6 chance: {w:medium} {arrow} {w:large}.",
        description = "Soothing to watch. Hypnotic, almost.",
        sprite      = "lava_lamp",
        phase       = "demo",
        cost_chip   = 5,
        position    = { x = 400, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "win_tier_shift",
              from = "medium", to = "large", chance = 1/6 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "win_tier_shift", from = "medium", to = "large", chance = 1/2 },
            },
            effect_text = "1 in 2 chance: {w:medium} {arrow} {w:large}.",
        },
    },
    {
        id          = "throw_pillow",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Throw Pillow",
        effect_text = "1 in 4 chance: {l:large} {arrow} {l:medium}.",
        description = "Soft plush pillow. Perfect for cushioning rough beats.",
        sprite      = "throw_pillow",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 320, y = 220 },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 1,
            text      = "{l:stack} {c:lost:losses} taken",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "loss_tier_shift",
              from = "large", to = "medium", chance = 0.25 },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "loss_tier_shift", from = "large", to = "stack", chance = 2/5 },
            },
            effect_text = "2 in 5 chance: {l:large} {arrow} {l:stack}.",
        },
    },
    {
        id          = "comfort_bed",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Comfort Bed",
        effect_text = "1 in 6 chance: {l:stack} {arrow} {l:large}.",
        description = "Restful memory-foam bed to sleep off heavy {c:lost:losses}.",
        sprite      = "comfort_bed",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 440, y = 220 },
        -- 4-tier note: spec called this "15% Big loss → Medium". The code's
        -- outcome model has 4 tiers (small/medium/large/stack — no Big).
        -- Repointed to Stack loss → Large so the catastrophic-loss-
        -- insurance reading is preserved. Pairs with Stress Ball's
        -- large-loss cushion.
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "loss_tier_shift", from = "stack", to = "large", chance = 1/6 },
        },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 110,
            text      = "{l:stack} {c:lost:losses} taken",
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "anti_award_mult", value = 2.0 },
            },
            effect_text = "{l:stack} {c:lost:losses} pay ×2 {achip}.",
        },
    },
    {
        id          = "yellow_sticky_note",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Yellow Sticky Note",
        effect_text = "{c:won:Winnings} ×1.25.",
        description = "A pad of yellow notes. Sticks to anything.",
        sprite      = "yellow_sticky_note",
        phase       = "demo",
        cost_chip   = 5,
        effects     = {
            { kind = "shove_rate_add", value = 0.008 },
            { kind = "earnings_mult",  value = 1.25 },
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "earnings_mult", value = 4.0 },
            },
            effect_text = "{c:won:Winnings} ×4.",
        },
    },
```

Effect kinds left with no catalog user: `loss_tier_shift`
(Closer's capstone still uses it), `earnings_mult` (decks and corrupt
lines still use it). Their applicators stay.

