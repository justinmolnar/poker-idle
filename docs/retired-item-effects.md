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
