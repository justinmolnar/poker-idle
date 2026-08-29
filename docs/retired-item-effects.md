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
