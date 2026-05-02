# Juice and Theater — Two Refactors

The grind tables aren't fun yet. The math is correct, the skin is bare, and most hands resolve as a quiet number tick with five anonymous card-pairs sitting at the top of the felt. These two refactors raise the dopamine floor and ceiling: more stuff happening every hand, bigger feedback, louder rewards, more poker shape on the cinematic.

The mandate is **density of feedback per second of play**. Vampire Survivors. CloverPit. Slot-machine cabinets. Things, things, things. Lights, music, particles, sirens, legendary-chest moments. The poker client is supposed to feel like *a casino*, not like a spreadsheet with a green felt skin.

This is on-tone, not against it. Cookie Clicker's tonal trick (cheerful chrome lying about the content) is a pillar of the design — the dread is structural, accumulated from the room around the laptop and the captivity frame, NOT from making the felt itself feel oppressive. The felt should feel exciting. That's the trap.

## Two refactors, one goal

**Refactor A — Juice.** Game-feel pass. Sounds, lights, shaders, particles, animations, screen-shake, casino chrome. Same math, same hand structure, much louder.

**Refactor B — Poker theater.** Rebuild the per-hand cinematic to play out as actual poker — blinds posted, betting rounds, folds during play, showdown reveals only when something's worth revealing. Predetermined outcome, scripted action. Player still has zero per-hand input.

A is a foundation. B layers on top of it. Each can ship without the other; both together is the demo experience.

---

## Refactor A — Juice

The rule: anything that resolves on a table should produce noise, motion, or both. Anything big should produce *a lot* of noise and motion. Most-of-screen feedback for the rare moments. Polite-but-present feedback for the hundred-hands-an-hour baseline.

### Felt motion

- Click DEAL → table panel lifts a few pixels with a slight rotation wobble. Held-aloft feel for the whole hand.
- Showdown / settle → hard slam back down. Panel-confined screen-shake on the slam, scaled by tier. (The jackpot-shake mechanism already exists; generalize to all settles.)
- Big wins → panel gold-border pulse, brief upward bounce, stays elevated an extra beat.
- Big losses → panel red-border pulse, brief desaturation flash that fades, low thud.

### Particle / chip overload

- Bigger chip bursts on every resolution. Tier-scaled — Tiny is a tasteful trickle, Jackpot is a fountain.
- Confetti on jackpot wins. Stake-tier-tinted so a T6 jackpot looks distinct from a T1 jackpot.
- Chip stacks on the felt actually grow visibly as bets land; the pot is a real chip pile, not a text label.
- Floating-text rebuild: bigger numbers, scaled by magnitude, tier-tinted, arc trajectory instead of straight-up float, settle-into-bankroll on big wins.

### Sound coverage

Default state: hands make noises constantly. Every shipped SFX should have at least one trigger.

- Card snap per card dealt.
- Chip rattle on every bet push.
- Fold whoosh per opponent fold.
- Showdown ding on hand reveal.
- Big-win siren / cheer / coin-cascade on jackpots.
- Big-loss low-thud / brief silence-then-thud on jackpot losses.
- Cursor-tap per autonomous click.

**No background ambient.** The room is silent. No chatter, no hum, no atmosphere. The silence IS the atmosphere — non-descript room, no one around, nowhere in particular. Casino-loud noise on the felt against dead-quiet around it is the captivity-tone contrast we want; faking a room with ambient hum would soften that and pull the game toward "you're at a casino" instead of "you're in a room with a poker client."

### Shaders / per-moment effects

- Jackpot win: radial glow shader on the panel + brief panel-zoom punch.
- Jackpot loss: vignette pull-in around the panel + slight chromatic-aberration jolt.
- Streak detection — 3+ wins in a row → glow intensity ramps. Adds anticipation when running hot.
- Bloom on chip stacks above some size threshold.

### Per-stake panel identity

Every tier renders visibly different. Right now T1 and T6 are interchangeable. Climbing stakes should feel like upgrading hardware — the visual pop on first sit at a new tier is its own dopamine event.

- T1: scuffed cheap green felt, plain wood frame, dim lighting.
- T2: same family but a touch cleaner.
- T3: blue felt, brass trim.
- T4: deeper green, more polish, brighter chips.
- T5: black-and-gold, velvet feel, neon table edge.
- T6: full Vegas — chrome trim, animated table-edge LEDs, glowing pot label, the works.

### Multi-table priority

Eight panels of full juice = unwatchable. Solution: **feedback intensity scales by outcome tier**. Most hands are Tiny, most panels are quiet at any moment, the occasional Jackpot pop genuinely catches the eye. The system is naturally self-prioritizing.

| Tier | Feedback level |
|---|---|
| Tiny | Subtle. Click sound, small chip motion, no shader, no shake. |
| Small | Medium chip burst, modest sound, no shake. |
| Medium | Full chip burst, full sound, brief shake. |
| Jackpot | Everything. Shaders, screen-shake, sirens, confetti, panel pulse, the works. |

Side benefit: the player learns to recognize tier outcome from the feedback alone, without reading numbers.

---

## Refactor B — Poker theater

Make the cinematic actually look like a poker hand. Predetermined outcome (already true today), scripted action (new). No per-hand player input.

### Hand structure

Replaces the current `dealing → flop → turn → river → showdown → settling` timeline with a more granular walk:

```
posting_blinds → preflop_action → dealing_flop → flop_action
             → dealing_turn  → turn_action  → dealing_river
             → river_action  → showdown_or_foldout → settle
```

Every `*_action` state plays out scripted folds and bet pushes for the seated opponents — and for the player, where appropriate.

### The fold problem, solved by tier mapping

The "everyone folds but the player never does" weirdness has a cleaner answer than dragging the player into decisions. **The magnitude tier already encodes how the hand played out.** Map it to a poker script:

| Outcome | Script |
|---|---|
| Tiny win | Stole the blinds. Everyone folds preflop or to a continuation bet on flop. No showdown. |
| Small win | Two opponents call a street, fold to a turn or river bet. No showdown — they mucked. |
| Medium win | Heads-up to showdown. Cards revealed. Decent hand wins. |
| Jackpot win | Multi-street action, big pot, showdown reveals nuts or near-nuts. Full reveal. |
| **Tiny loss** | **Player folds preflop or flop to a 3-bet.** Lost only blinds + a small call. No showdown. |
| **Small loss** | **Player folds the turn after some action.** Modest pot lost. No showdown. |
| Medium loss | Showdown, player flips second-best. Cards revealed. |
| Jackpot loss | Big pot, deep action, showdown reveals a cooler / suckout. Reveal everything. |

The player's fold is naturally the Tiny/Small loss script. The fold IS the loss. No decision required, no contradiction in the fiction. The math doesn't change. The poker feel does — and now the tier system finally reads as poker (right now Tiny vs Medium loss is just "size of the red number"; in the new world it's "did I fold the turn or eat a bad showdown").

### Showdown only when it matters

Most hands won't reach showdown. Tiny + Small outcomes end as fold-outs — community cards fade out, pot pushes to winner, no card reveal. Medium + Jackpot reveal cards, name the hand, border-pulse the winner.

This makes the card reveal a **payoff moment**. Today every hand reveals at showdown regardless and nothing feels rare.

### Pot building

Bets during action states actually push chip stacks toward the pot. The pot label updates live as streets resolve. By the end of the cinematic the chip pile reflects (roughly) the magnitude that was rolled.

It doesn't have to be exact — the script generator just produces action whose totals are close to the rolled magnitude. Nobody's doing arithmetic; they see the pot grow, they feel the stakes.

### Hand-name labels

When a hand reaches showdown, the reveal includes hand-strength names: "Pair of Aces", "Two Pair, Kings & 8s", "Flush, Ace high". HandEval already produces the rank tuple; this is a formatter pass.

### Opponent type tags

Each name in `data/opponent_names.lua` gets a tag — loose, tight, fish, nit, aggro, passive. The tag drives action scripting:

- LooseLuke calls everything, rarely folds early. Pots they're in tend to grow.
- TightTed folds preflop 80%. If they're still in by the turn, watch out.
- AggroDan 3-bets preflop, forces folds.
- FishMan calls light, weird value plays.
- ButtonBoss raises in late position.
- BB_Ninja defends big blind aggressively.

Tags don't affect math — they affect *which* opponent does *what* in the script. Same outcome plays differently with loose seats vs tight seats.

### Multi-tabling scaling

Full theater on eight panels is too much. Theater detail scales with panel size:

- Single-panel mode (one table): full theater, hand names, narrator caption, all chip motion.
- Mid-grid mode (2–4 tables): theater plays out, no narrator caption, smaller chip stacks, hand names still appear.
- Mini-grid mode (5+ tables): compressed timeline. Skip preflop action display, jump to flop, fold animations only on showdown reveals.

The existing `mini` flag in TablePanel already bifurcates rendering for small panels — extend it to bifurcate timelines too.

### Pacing

Real poker theater is longer than the current 4.4s/hand baseline. The new structure needs retuned timings in `data/cinematic_timelines.lua` so it fits a workable playtime budget — or accept that hands take longer and adjust EV/minute expectations downstream. Energy Drink (and any future pace catalog item) become more valuable because they compress the longer cinematic — that's a balance lever, not a bug.

---

## How the two refactors interact

Refactor A does not need Refactor B to work. The juice can land on the existing simple cinematic and improve the game noticeably on its own.

Refactor B introduces new moments that *want* juice: the fold whoosh, the pot push between streets, the showdown reveal beat, the hand-name appearing, the border pulse on the winning cards. The juice pass should be revisited after B lands so the new moments aren't dry.

If only one refactor ships, A is the higher-leverage one — most of the dopamine deficit is feedback density, not poker authenticity. B is the prestige version, the thing that makes the game feel like a poker game and not a spreadsheet wearing a felt.

---

## Tonal anchors

- Casino loud is the right register. Cookie Clicker's cheerful trap.
- The dread lives in the room around the laptop, not on the laptop. The laptop is supposed to feel like a slot machine that wants you to keep playing.
- Vampire Survivors / CloverPit density of feedback is the target, scaled to a poker-room context.
- The gauntlet stays tonally distinct — slow, ritualistic, sparse, dread-soaked. The grind tables are loud, the all-in moment is quiet. The contrast is the whole point.

---

## Open questions

- Per-stake panel themes — how dramatic? Every tier should be visible at a glance, but going *full* fantasy at T6 (animated LEDs, neon edges) may fight the otherwise-grounded room. Tune in playtest.
- Player-tag count — 6 archetypes covers most of the texture, but more variety = better long-game. Add as content grows.
- Showdown reveal dwell — long enough to read the hand name, short enough that multi-tabling doesn't drown.
- Background room ambient volume — barely audible vs clearly present. Probably barely audible, but worth a pass.
- Concurrent jackpot effects on multi-tabling — the per-tier scaling solves overload in the typical case, but a frame with 3 panels jackpotting at once might still be chaos. Cap concurrent siren / shader instances?
- Whether folds-as-theater needs to honor *opponent* tags too on the win side — i.e., a Tiny win against a table of LooseLukes shouldn't really be "everyone folds preflop" because that's not how Loose Lukes play. Script generator may need to bias which seats are seated when generating the fold-out narrative.
