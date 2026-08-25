> **Legacy (moved 2026-08-25).** May brainstorm: ~8 decks, 10 levels, swap at shove. Live: 12 decks (`data/decks.lua`), max_level 5 with a capstone rule at 5, master deck adds to ITEMS capped at things-you-own (capstone lifts the cap). Superseded by `docs/deck-new-roster.md` and the data.

# Deck System — Design Notes

A brainstorm record for the third progression system (after per-run upgrades and catalog upgrades). Nothing here is final; this is the shape the system has taken across one extended design conversation.

## What slot it fills

The game already has two progression systems:

- **Per-run upgrades** — ephemeral, tactical. *"What's my chess this run?"*
- **Catalog upgrades** — permanent, additive. *"Am I stronger than I was?"*

The deck system answers a third, distinct question: **what kind of player am I right now?** Permanent across runs, but expressed-one-at-a-time. Loadout, not growth. That's why it doesn't feel redundant with catalog even though both persist — catalog is power; decks are *expression*.

## Core rules

- ~8 decks total, bounded by available win98-solitaire-cardback assets. Each deck has its own visual identity.
- Player has **only one active deck at a time**.
- **Swap point is at shove**, as part of the post-shove ritual: shove → gauntlet → catalog → choose deck → next run.
- **All unlocked decks contribute their banked passive at full strength simultaneously.** Passives stack.
- **Only the active deck accrues XP.** The active deck is the one being trained.
- Levels persist forever. Every level you ever earn keeps contributing.
- **Soft level cap** — XP per level scales with tier/money. You can theoretically max a deck at T1 by leaving the game on for months, or progress naturally and hit the same cap in hours. Same cap either way; no hard tier gate needed.
- Late-game balloon (8 stacked passives at full strength) is **intentional**. The unlock curve *is* the late-game pacing. Each unlock is a real power spike. Tuning assumes "fully unlocked = trivial T1, easy T2, comfortable T3."

## Strategic shape

- **Broad-and-shallow > narrow-and-deep.** XP cost per level needs to be steep enough that 8 decks at L3 beats 1 deck at L5 for the player's actual goal. This is the load-bearing balance decision; get it wrong and the system collapses to "pick the best deck and grind it."
- **Rotation pressure produces self-pacing.** Optimal play is constant rotation, which means constant variety, which means difficulty curve and content rotation come from one rule.
- **Home deck pattern emerges.** Players develop a default deck for normal play and swap off only to train. Most decks are visited; one or two become home. Player-emergent character.

## The two-phase deck lifecycle

Each deck has two distinct phases:

- **Trial phase** (active, leveling): the deck demands a playstyle. Sometimes uncomfortable.
- **Banked phase** (passive, leveled): the deck donates its bonus to whatever you're doing now. Silent contributor.

The deck isn't really "a bonus" — it's *a trial that pays out a permanent dividend*. The training is the price; the passive is the wage.

This produces:

- **Decks acquire narrative.** "I trained the loss-deck during my second T2 run, it sucked, but now my downswings barely matter." Each deck has a story of when you committed to it. Friction creates memory.
- **Hard-to-level decks become evergreen late-game content.** Player with 6 decks banked still has 2 trials waiting. The trial doesn't get easier as the roster levels — it gets *more affordable*, because there's more capital to spend on suffering.
- **Difficulty of training and power of bonus can be decoupled.** Hard-to-train utility decks and easy-to-train power decks are both legitimate.
- **The shove screen quietly becomes a mission-select screen.** Players plan deck commitments around their meta-state.

## Design space — the 2x2

Two independent axes:

- **XP rule**: bread-and-butter (hands, money, time) ↔ trial (constraint-on-playstyle)
- **Bonus**: stat-stick (number bump) ↔ playstyle-defining (changes how poker plays)

The four quadrants:

- **Grinder** (boring rule, boring bonus) — leave game on, deck levels, passive number. Idle-genre staple. Couple of these as filler.
- **Stat stick** (boring rule, cool bonus) — easy to train, real change to the game. Good early/mid unlocks.
- **Test of patience** (trial rule, boring bonus) — rare, only if patience itself feels like growth. 0–1 in roster.
- **Signature deck** (trial rule, cool bonus) — the loss-deck pattern. Pillar moments.

Mix matters for **session-energy** as much as variety. Tired player at 11pm picks a grinder. Saturday afternoon picks a signature. The deck choice becomes a self-pacing tool — player decides how engaged they want to be, the deck honors that decision. Without grinders, every shove is a commitment to focus, and that burns players out.

**Unlock order is a tutorial.** Grinder first → stat stick second → trials saved for mid-game when player has a banked roster to absorb the awkwardness.

## XP rule flavor

XP rules carry the deck's *personality* alongside the bonus. Loosely tied to the bonus is fine ("MTT-easier deck levels on MTT hands played"), but some intentional mismatches produce the most interesting decks (loss-deck makes losses smaller and levels on losses — playing it well gradually starves its own XP source).

Rough flavor variants:

- Hand-volume (bread-and-butter)
- Money-won (bread-and-butter)
- Real-time (bread-and-butter)
- Money-lost (signature inversion)
- Big-pots-only (trial)
- Win-streak (trial)
- All-ins-only (trial)
- Rebuys (trial)
- Folds (trial)

All-different XP rules is the load-bearing flavor decision. If they all level on "play hands," it's 8 grind buckets in costumes. If each demands a different *behavior*, the player internalizes 8 ways to play poker over the lifetime of the game.

## Meta-trial / anti-feature decks

A separate category from felt-trial decks: decks that disable game systems. The constraint isn't a goal — it's the play environment itself for the whole run.

Examples:

- **Catalog-disabled** — no catalog buys this run.
- **Cursors-off / no automation** — forces active engagement.
- **Upgrades-disabled** — no in-run upgrade purchases.
- **Single-table-type** — only one table type available.
- **No-fold** — fold button removed.

These produce **structurally different runs**, not just stylistically different ones. A no-cursors run feels like a different game mode, not a poker variant. Each one reframes what the run is *for*.

The active-vs-idle deck is fighting the genre's gravity deliberately. Idle games drift toward disengagement; an opt-in "active engagement" deck is a counter-current the player can deploy when they want to be present.

**Per-deck tuning cost is higher** for meta-trials. Each one creates its own run economy that has to be soloable. Probably means meta-trials are a smaller subset of the 8 than felt-trials are.

## Deferred amplification — the killer pattern

The cleanest articulation of what this system *is*: **deferred amplification**. You spend runs deliberately weakened so future runs can be cumulatively stronger.

The pattern, generalized:

> **Disable system X during training → bonus scales system X afterward.**

Concrete instances:

- Catalog-off deck → catalog items 1.5x post-grind
- Upgrades-off deck → upgrades cheaper or stronger post-grind
- Cursors-off deck → automation runs faster post-grind
- Other-decks-off deck → all banked passives 1.5x post-grind (the *amplifier* — train it bare, graduation makes everything you'd built feel bigger)
- No-fold deck → folds become more profitable post-grind

Why it works emotionally: **the trial conceals its own reward.** You can't feel the bonus while training, because the trial disables the system the bonus scales. Graduation isn't a smooth transition — it's a *reveal*. You swap off, the catalog comes back, and now it's better than it ever was. The contrast makes the bonus land. You feel the absence first, then you feel the absence repaired-and-improved. Double payoff from one level-up.

Numbers (`1.5x` etc.) used in this section are illustrative only. Each deck has its own bonus shape; there is no shared template.

## Cross-system entanglement

The deck system **couples** with catalog progression in non-trivial ways:

- **Catalog progression modulates which deck trials are practical to attempt and how rewarding their graduation is.** Weak-catalog player suffers little from a catalog-off trial AND gains little from the bonus. Strong-catalog player suffers more AND gains more. Trial scales to investment level. Self-balancing.
- **Decks create demand for specific catalog upgrades.** "I cursed myself, now I need to grind catalog to unlock the cure." Catalog progression gets *narrative motivation* — solving a self-inflicted problem, not just buying the next thing on the list.
- **Catalog can act *on* decks**, not just alongside them. Once that role exists (see cursed deck below), catalog can be a *deck-modifier vendor*: items that flip a deck's curve, change a deck's XP rule, raise a deck's max level, etc. Whole sub-system available.

## Endgame shape

- **The stack reveal beats the unlock pop.** Most idle endgames climax on a triumphant purchase. This one climaxes on *putting your normal deck back on after a lot of trialing* and noticing the world feels different. No fanfare in any single level-up. The big number lives quietly in the background until the player chooses to feel it. Subtler power fantasy, rewards the long view.
- **"Get this to L4 and I can beat the game"** is a fundamentally different goal-shape than "earn $50M and buy the last upgrade." It names a specific *trial* as the bottleneck. Player commits to suffering through deck X for Y runs to clear the wall. That gives the milestone weight.
- **Self-authored endgame.** Player at the wall asks: what's my weakest amplifier? Which deck's next level gives the biggest marginal jump? Different players hit T_n with completely different deck-level distributions.
- **The wall is never final.** Amplifier stack always has more room to grow. Future content plugs into the existing stack without invalidating prior work.

## The cursed deck — redemption-arc design

A deck whose value is gated behind a different progression system. The most narratively rich deck in the proposed roster.

**Mechanics (illustrative numbers):**

- **Active (running this deck this run):** DOUBLE upgrade potency. The temptation.
- **Banked passive:** +10% upgrade cost per level. Negative from L1 onward.

The deck only pays out *while you're actively running it*. Every time you do, you accumulate XP and (eventually) push another level of permanent cost. There's no "L1 free passive" — banked, it's pure cost.

Strategic relationship the player has with leveling on this deck is genuinely different from every other deck:

- Other decks: optimal play is "level it up."
- Cursed deck: optimal play is "minimize total uses, each use justified by the active bonus paying for the marginal level."

**The cure** — a catalog upgrade — flips the curve. Two mechanical sketches considered:

1. **Reverse-leveling post-cure** (XP earned after the cure de-levels the deck or pushes it into negative levels, removing cost or adding discount). Player grinds the deck twice — once to curse, once to redeem. More grindy but every level is a chosen step.
2. **Default-L5-and-regress** (cursed deck starts cursed, cure unlocks regression). More dramatic; less grind.

Leaning toward (1) — preserves agency on both halves of the arc.

The emotional engine: **the past curse becomes the baseline against which the cure feels good.** Player suffered through +50% upgrade cost; post-cure they're at -10% and the lizard brain reads it as a 60-point swing. Pain remembered amplifies present feeling.

**The full arc is unique in the roster:**

1. Resist (don't engage, no cost)
2. Calculated trade (one or two clutch uses, eat a few levels of curse)
3. Crisis (over-leveled, +X% cost hurts)
4. Catalog grind motivated by the curse (cure-quest)
5. Inversion (cure obtained, direction flips)
6. Redemption (use freely, each use makes upgrades cheaper, runaway loop)

Other decks have linear arcs (train → bank). This one has a *story*. Players will remember which run they cursed themselves on and which run they un-cursed themselves on the way they don't remember which run they leveled the MTT deck.

## Theater / juice implications

The juice-and-theater layer needs to support several distinct moments this system produces:

- **Loss-deck active**: feedback should *celebrate* losses, not tolerate them. Different shake, different sound, "+XP" flying out of busted pots. Otherwise the lizard brain still reads loss as bad and the deck feels miserable to play even when it's optimal.
- **Restriction-deck signposting**: at deck-select, restriction decks ("no cursors," "no catalog") need visual weight that scales with constraint severity. Player should not be surprised five hands in by something they didn't read.
- **Graduation reveal**: first time the player swaps off a "system-off" deck and returns to that system, the reveal should be punctuated. Items flash, a "first time seeing your post-trial catalog" beat. The moment is what makes the trial worth it in retrospect.
- **Cursed deck redemption**: post-cure, the moment upgrade costs flip from inflated to discounted should be a *moment*. The cure is one of the highest-value catalog purchases in the game emotionally; the UI should treat it that way.

## Things still open

- Exact level cap (probably ~5, kept tight so each level is a real event).
- Specific 8-deck roster.
- Specific bonus values and curve shapes.
- XP cost curves (the rotation-pressure tuning is the load-bearing balance work).
- Which decks land in which 2x2 quadrant.
- Whether catalog-as-deck-modifier becomes its own sub-system or stays scoped to the cursed-cure pattern.
