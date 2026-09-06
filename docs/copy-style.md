# The style sheet: one language for the rules

Every rule the player reads (catalog effect lines, corrupt lines, deck
bonuses and capstones, status blurbs, run-upgrade blurbs, stickers) is
written in the forms below. The House's spoken lines (data/story.lua) keep
his voice (docs/the-house-voice.md) and use these nouns when they name a
mechanic. Two lints enforce this:

    lua sim/lint_terms.lua     the colour code ({c:meaning:word})
    lua sim/lint_copy.lua      this sheet: retired words, and every printed
                               number checked against the effect it describes

Both walk sim/copy_fields.lua, the one list of copy fields. Add a field
there and both lints see it. Why the sheet exists: docs/copy-audit-2026-09.md.

## Numbers: three forms, and the form is the operation

| What | Form | Never |
|---|---|---|
| A roll that happens or not | `1 in N chance` (`2 in 3`, `2 in 5` allowed) | 25%, half the time, a third, may, sometimes |
| An additive quantity (win chance, a lean, a bankroll add, a level) | `+N%`, `-N%`, `+$N`, `+N` | N% more, N% less, N% stronger, softer, heavier |
| A multiplier | `×N` (`×2`, `×1.2`, `×0.8`) | double, quadruple, twice, N× bigger, 5.0× |
| A cadence | `Every N hands won:` | |
| A share of something | `N% of the buy-in` | |

A lean (Maniac, Nit, Pot Control) is a quantity, not a roll: `+10% each`.
A step is a roll: `1 in 4 chance`. Both can sit in one line.

Chance values in data are the fraction they print, written as a Lua
expression (`chance = 1/3`). Allowed denominators: 2, 3, 4, 5, 6, 8, 10, 12,
plus 2/3 and 2/5. The lint refuses anything else, in effects, procs and
routers alike. That is what lets "1 in N" stay honest.

The `×` is the real multiplication sign (U+00D7). IconText prints it.

## Nouns: one word each, and the taught word wins

| Meaning | The word | Retired |
|---|---|---|
| Pot classes | the glyphs `{w:small}` … `{l:stack}`; "size" when a word is needed | tier, Large/Small as words |
| A stake | stake | table tier; "rung" is the House's word, glossary only |
| The good status | a `{c:heat:heater}`; a table **catches** one | heat (noun), heats, heats up, running hot, burnt-out; "on fire" and "hot" are story-only |
| The bad status | a `{c:tilt:tilt}`; a table **takes** one; a redirected one **lands on** X **instead** | spent, runs its course, absorbed |
| Either status | a heater or a tilt | status |
| Adjacent table | the table beside it | nearby, neighbour, neighbouring |
| Any other table | a random table | another table |
| A seat busted in a tournament | a knockout (taught in the glossary) | tournament finish |
| Tournament outcomes | win (first place), cash (top three), bust | finish, place |
| Zoom mass-resolve | settles ("every other Zoom table settles now") | sweep, resolves, cascade |
| Prize Vase's run bonus | the plain rule: `+1% win chance at every table for the run` | ratchet, lifts |
| A table that has paid its chip | paid / unpaid | unbanked |
| Focus headroom | `+2 tables at full FOCUS` | focus capacity |
| Win chance scope | `at Heads-Up`, `at Zoom`, `at 6-Max`, `at tournaments`, `at every table` | "tables" suffix, bare "Heads-Up", "at all tables" |
| Game types | Heads-Up, Zoom, 6-Max, tournament | 6-max |
| Money kept from the shove | `{c:chip:banked}` | |
| The chip a table pays | `{c:chip:bounty}` | |

Trigger nouns, closed set: `Win a {w:stack}`, `Win a tournament`, `A
knockout`, `Rebuy`, `Bust`, `Open your first table at a stake`, `A
{c:tilt:tilt} lands on`, `A {c:tilt:tilt} ends`, `A 6-Max catches a
{c:heat:heater}`, `Every N hands won`.

Scope words, closed set: `for the run`, `each run`, `this hand`, `the next
hand`, `while it runs`, `for 10 seconds` (real time is what the cursors do).

## Skeletons: one per rule family

| Family | Skeleton | Example |
|---|---|---|
| Static quantity | `<what> <form>.` | `+10% win chance at Heads-Up.` |
| Multiplier | `<what> ×N.` | `{w:stack} {c:won:wins} ×2.` |
| Size step | `1 in N chance: {from} {arrow} {to}.` | `1 in 4 chance: {w:small} {arrow} {w:medium}.` |
| Any-size step | `1 in N chance a {c:won:win} lands one size up.` | Chrome Toaster, Maniac |
| Trigger, roll, effect | `<Trigger>: 1 in N chance <effect>.` | `Win a {w:stack}: 1 in 4 chance that table catches a {c:heat:heater}.` |
| Trigger, certain effect | `<Trigger>: <effect>.` | `Rebuy: that table catches a {c:heat:heater}.` |
| Cadence | `Every N hands won: <effect>.` | `Every 50 hands won: a table's next {c:won:win} lands one size up.` |
| Redirect | `A {c:tilt:tilt} aimed at <X>: 1 in N chance it lands on <Y> instead.` | Dish Soap, Waste Basket |
| Start of run | `Start each run with <thing>.` | |
| An on/off | `Opens <thing>.` | `Opens 6-Max.` |
| Corrupt line | the full corrupted rule in the same skeleton; a pure penalty is `Same, and <penalty>.` | `Same, and {c:lost:Losses} ×1.5.` |
| Deck bonus | the rule with `{n}` where the number goes, under eight words | `+{n}% {c:won:wins}` |
| Deck capstone | one sentence in the family skeleton | `First place: every table catches a {c:heat:heater}.` |
| Unlock sticker | lowercase noun phrase the counter completes | `0 / 3,000 Zoom hands` |

The effect line is the rule and nothing else. Metaphor and jokes live in
`description`, the name and the art.

## The rest of the rules (unchanged, gathered here)

- The colour code: a mechanic word is tinted `{c:<meaning>:<word>}`, seven
  meanings in data/theme.lua `sem`, the words per meaning in data/terms.lua.
  Tint the noun, not the sentence; first occurrence per block; only a word
  its meaning owns; never a stake, a game type, money, the House, the shove,
  the bankroll or the cards' names.
- No em-dashes, anywhere.
- `{chip}` / `{achip}` tokens, never the words "chip" / "chips" for currency.
- No question marks in anything that can play before `panic_won`.
- Cut filler. A block is one click's worth of reading.
- Reveal rule: nothing that can play before the first runout win names a
  runout, a cheat, a card count, or the second hand.
- Corruption and `{achip}` are never taught; the corrupt line is the only
  surface, and it still follows this sheet.

## Before and after

| Was | Is |
|---|---|
| 25% chance to boost {small} {arrow} {medium}. | 1 in 4 chance: {w:small} {arrow} {w:medium}. |
| 8% chance a win bumps one tier. | 1 in 12 chance a {c:won:win} lands one size up. |
| Half your wins read a tier bigger, the other half pay double. | {c:won:Wins}: 1 in 2 chance one size up, else ×2. |
| {c:lost:Losses} 20% softer. | {c:lost:Losses} ×0.8. |
| Heads-Up bounties pay double {chip}. | Heads-Up {c:chip:bounties} pay ×2 {chip}. |
| Knockouts have a 20% chance to heat a nearby table. | A knockout: 1 in 5 chance the table beside it catches a {c:heat:heater}. |
| A 6-max may take a status aimed at the table beside it. | A {c:heat:heater} or {c:tilt:tilt} aimed beside a 6-Max: 1 in 2 chance it lands on the 6-Max instead. |
| +5% {w:stack} chance at unbanked tables | +{n}% {w:stack} chance at unpaid tables |
| +7.5% cash winnings per table tier | +{n}% {c:won:wins} per stake |
