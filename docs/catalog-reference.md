# Catalog Reference

Generated from data/catalog.lua, data/catalog_pages.lua, and
models/catalog_unlock_rules.lua. Snapshot as of 2026-08-05.

48 buyable items across 8 departments, 822 {chip} total.

Build assumed: PROTOTYPE_MODE = false, so FEATURES.TUTORIAL = true, which
strips the two run0 entries at module load. In a PROTOTYPE build add the
hidden handicap entry and the free Poker Poster at the head of Value Buys
(see "Hidden entries" at the bottom).

Every item carries a shove_rate_add on top of its headline effect; that is
the "shove" number on each line. "Unlock: none" means available from the
start.

total_* gates tick from hand one. lifetime_* and deck-count gates only start
accruing once the deck system unlocks (first R1 win, the end of Act 1).


═══════════════════════════════════════════════════════════════════════
VALUE BUYS · 34 {chip} · shove +0.079
═══════════════════════════════════════════════════════════════════════
The starter shelf. No shared mechanic by design; these are just the cheap
things worth buying first.

Branded Hat · 2 {chip} · shove +0.012
    {stack} pays 1.2× (jackpot_mult 1.20)
    Unlock: none

Mirror · 3 {chip} · shove +0.010
    +10% win chance at Heads-Up
    Unlock: none

Energy Drink · 3 {chip} · shove +0.008
    Hands resolve 25% faster (hand_pace_mult 1.25)
    Unlock: none

Whiteboard · 4 {chip} · shove +0.010
    +5% win chance at all tables
    Unlock: none

Self-Help Book · 4 {chip} · shove +0.012
    25% chance to boost {small} → {medium}
    Unlock: none

Lucky Coin · 5 {chip} · shove +0.010
    +50% starting bankroll
    Unlock: none

Lava Lamp · 5 {chip} · shove +0.012
    15% chance to boost {medium} → {large}
    Unlock: none

Sticky Notes · 8 {chip} · shove +0.008
    Wins pay 25% more (earnings_mult 1.25)
    Unlock: none


═══════════════════════════════════════════════════════════════════════
BED & BATH · 87 {chip} · shove +0.071
═══════════════════════════════════════════════════════════════════════
Softens what losing costs you: tier downgrades, loss multipliers, voids,
and the free rebuy when it still goes wrong.

Stress Ball · 4 {chip} · shove +0.014
    25% chance to soften {l:large} → {l:medium}
    Unlock: none

Worry Stone · 5 {chip} · shove +0.014
    15% chance to soften {l:stack} → {l:large}
    Unlock: 3 {l:stack} losses taken

Rubber Duck · 6 {chip} · shove +0.005
    Run's first loss is voided
    Unlock: 3 tables busted

Headphones · 12 {chip} · shove +0.008
    Losses 20% softer (loss_mult 0.80)
    Unlock: none

First Aid Kit · 24 {chip} · shove +0.012
    20% of rebuys are free
    Unlock: 250 rebuys

Claw-Foot Tub · 36 {chip} · shove +0.018
    Wins never roll {w:small} (win_tier_floor medium)
    Unlock: 1 deck maxed


═══════════════════════════════════════════════════════════════════════
KITCHEN & APPLIANCES · 160 {chip} · shove +0.090
═══════════════════════════════════════════════════════════════════════
Machines that fire on their own at an event: a pot bumps, a beat gets
eaten, a bust drains back, last run's losses come back clean.

Compact Fridge · 18 {chip} · shove +0.012
    Run's first {l:stack} is voided
    Unlock: 25 {l:stack} losses taken

Chrome Toaster · 22 {chip} · shove +0.014
    8% chance a pot bumps one tier
    Unlock: 250 Jackpots hit

Utility Sink · 22 {chip} · shove +0.012
    Busted tables refund 30% of the buy-in
    Unlock: 100 tables busted

Microwave Oven · 28 {chip} · shove +0.014
    5% chance a pot pays double
    Unlock: 500 Jackpots hit

Portable Dishwasher · 35 {chip} · shove +0.016
    Start each run with 10% of last run's losses
    Unlock: win your first shove (flag gate, no counter shown)

Fire Extinguisher · 35 {chip} · shove +0.018
    Losses never roll {l:stack} (loss_tier_ceiling large)
    Unlock: 250 {l:stack} losses taken


═══════════════════════════════════════════════════════════════════════
HOME OFFICE · 151 {chip} · shove +0.087
═══════════════════════════════════════════════════════════════════════
Attention: focus capacity, the penalty for exceeding it, and the
per-game-type edges you get from paying attention at one kind of table.

Water Cooler · 14 {chip} · shove +0.010
    +6% win chance at 6-max
    Unlock: 2K hands at 6-max

Gaming Chair · 15 {chip} · shove +0.012
    Focus penalty halved
    Unlock: 500 hands over focus cap

Second Monitor · 16 {chip} · shove +0.012
    +1 focus capacity
    Unlock: 1K hands at 4+ tables

Headset · 16 {chip} · shove +0.010
    +6% win chance at Zoom
    Unlock: 2K Zoom hands

Wall Clock · 20 {chip} · shove +0.013
    3% of hands win outright
    Unlock: 5K hands played

Ceiling Projector · 30 {chip} · shove +0.016
    At NL1K and above, wins skew bigger
    (win_dist_shift small -.10 / medium -.05 / large +.08 / jackpot +.07,
     tier_min 4)
    Unlock: $50.0M won (lifetime_money_won, money-formatted counter)

Console Television · 40 {chip} · shove +0.014
    +2 focus capacity, but wins pay 10% less
    Unlock: 2.5K hands over focus cap


═══════════════════════════════════════════════════════════════════════
DESK & STATIONERY · 114 {chip} · shove +0.062
═══════════════════════════════════════════════════════════════════════
Paper goods. Everything here bends the run-upgrade economy or the bounty
paperwork around it.

Calculator · 10 {chip} · shove +0.006
    Upgrades are 15% stronger
    Unlock: none

Ring Binder · 10 {chip} · shove +0.006
    Upgrades cost 15% less
    Unlock: 25 upgrade levels bought

Pen · 12 {chip} · shove +0.006
    +1 {chip} on every bounty
    Unlock: 60 {chip} banked

Filing Cabinet · 24 {chip} · shove +0.014
    Upgrades reach one level further (fill_window_widen 1)
    Unlock: 150 upgrade levels bought

Copy Machine · 26 {chip} · shove +0.014
    First denied {chip} each run banks anyway
    Unlock: 10 {chip} denied

Supply Closet · 32 {chip} · shove +0.016
    +1 level on every upgrade
    Unlock: 300 upgrade levels bought


═══════════════════════════════════════════════════════════════════════
COMPUTER ACCESSORIES · 76 {chip} · shove +0.046
═══════════════════════════════════════════════════════════════════════
The cursor swarm. Item-gated rather than counter-gated: the three crew
items are hidden entirely until Box of Mice is owned. Box of Mice is
slots = 3, so it fills its own leaf as a hero card.

Box of Mice · 20 {chip} · shove +0.014
    Unlocks the cursor swarm and the Cursor upgrade
    Unlock: none

Trained Cursor · 18 {chip} · shove +0.010
    +1 cursor
    Unlock: own Box of Mice (hidden until then)

Mouse Pad · 18 {chip} · shove +0.010
    Cursors travel 30% faster
    Unlock: own Box of Mice (hidden until then)

Tireless Assistants · 20 {chip} · shove +0.012
    Cursors also click REBUY; [R] in the panel header opts a table out
    Unlock: own Box of Mice (hidden until then)


═══════════════════════════════════════════════════════════════════════
AWARDS & WALL ART · 121 {chip} · shove +0.064
═══════════════════════════════════════════════════════════════════════
Things on the wall that pay you: bounty bonuses, tournament payout tiers,
deck XP.

Dogs Playing Poker · 8 {chip} · shove +0.006
    First {chip} bounty each run pays +1
    Unlock: 25 {chip} banked

Plastic Trophy · 18 {chip} · shove +0.010
    Tournament cashes pay 4× / 8× / 20×
    Unlock: 1 tournament win

Engraved Plaque · 28 {chip} · shove +0.014
    Tournament cashes pay 5× / 10× / 20×
    Unlock: own Plastic Trophy (shown while locked)

Study Chart · 30 {chip} · shove +0.014
    Active deck earns 50% more XP
    Unlock: 3 decks unlocked

Change Jar · 37 {chip} · shove +0.022
    {chip} bounties pay 50% more
    Unlock: 500 {chip} banked


═══════════════════════════════════════════════════════════════════════
MEMBERSHIPS & VOUCHERS · 79 {chip} · shove +0.056
═══════════════════════════════════════════════════════════════════════
Paperwork that makes sitting down cheaper or richer.

Money Clip · 8 {chip} · shove +0.006
    +$5 starting bankroll
    Unlock: none

Gift Certificate · 14 {chip} · shove +0.010
    Start each run with 1 table
    Unlock: none

Coupon Book · 14 {chip} · shove +0.010
    Buy-ins cost 15% less
    Unlock: none

Punch Card · 15 {chip} · shove +0.010
    Rebuys cost 25% less
    Unlock: 50 rebuys

Frosted Glass Door · 28 {chip} · shove +0.014
    Buy-ins 30% cheaper at NL1K and above (tier_min 4)
    Unlock: 4 stake tiers reached

Ultra Stake · 0 {chip} · no shove
    Unlock the T10 ULTRA stake. The base entry has no effects at all;
    the corrupt buy below is the real purchase.
    Unlock: requires_act3, hidden until shove_r2_won


═══════════════════════════════════════════════════════════════════════
ACT 3 CORRUPT VARIANTS
═══════════════════════════════════════════════════════════════════════
Bought with anti-{chip} on top of the base item, replacing its effects.

Branded Hat · 2 anti-{chip}
    {stack} pays 5.0×, shove +0.15 (up from +0.012)

Worry Stone · 5 anti-{chip}
    90% chance to soften {l:stack} → {l:small}, shove +0.20

Headphones · 8 anti-{chip}
    Losses 50% softer

Ultra Stake · 25 anti-{chip}
    ultra_unlock_effect: the T10 ULTRA stake goes live


═══════════════════════════════════════════════════════════════════════
HIDDEN ENTRIES (PROTOTYPE builds only)
═══════════════════════════════════════════════════════════════════════
Both are run0 entries, stripped at module load under FEATURES.TUTORIAL.

(handicap) · 0 {chip} · never shown in any UI
    granted_at_start, removed_by = poker_poster.
    wc_mult 0.4 plus a 4-tier loss skew (small -.50, medium -.30,
    large +.50, jackpot +.30). Knocks T1's naked 50% win chance to ~20%.

Poker Poster · 0 {chip}
    No direct effects. Owning it is what neutralizes the handicap above.
    The only catalog item that names poker directly, on purpose.


═══════════════════════════════════════════════════════════════════════
BAND TOTALS VS. THE HEADER BLOCK
═══════════════════════════════════════════════════════════════════════
data/catalog.lua's band comment claims 800 {chip} and shove 0.570. Actual
sums, cost then shove, claimed then actual:

Band A · Act 1 early, T1-T2 · 12 items
    cost   47 claimed,  49 actual   (+2)
    shove  0.115 claimed, 0.115 actual   OK

Band B · Act 1 late, T2-T3 · 14 items
    cost   190 claimed, 190 actual   OK
    shove  0.135 claimed, 0.125 actual   (-0.010)

Band C · Act 2, deck era, T4-T6 · 15 items
    cost   330 claimed, 350 actual   (+20)
    shove  0.200 claimed, 0.190 actual   (-0.010)

Band D · Act 2 late · 7 items
    cost   233 claimed, 233 actual   OK
    shove  0.120 claimed, 0.120 actual   OK

TOTAL · 48 items
    cost   800 claimed, 822 actual
    shove  0.570 claimed, 0.550 actual

Two consequences if the header is the intended target:

  - A+B carry 0.240, not the 0.250 that catalog_target(T3) in docs/math.md
    says a fully-bought Act 1 catalog needs to make the first shove
    winnable.
  - The full catalog lands at 0.550 against catalog_target(T6) = 0.57.

Band A is +2 {chip} (Sticky Notes at 8) and Band C is +20 {chip}. Either
the items were repriced without updating the header, or the header is the
budget and those two bands are over.


═══════════════════════════════════════════════════════════════════════
DEPARTMENT COVERAGE
═══════════════════════════════════════════════════════════════════════
All 48 visible items appear in data/catalog_pages.lua, so nothing falls
into the trailing "&c." catch-all department.
