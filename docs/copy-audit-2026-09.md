# Copy audit: the catalog, the decks, and what Balatro does instead

2026-09-06. Audit only; nothing in `data/` was changed. Sources: every
`effect_text`, `corrupt.effect_text`, `unlock.text` and `description` in
data/catalog.lua, every `bonus`/`capstone`/`levels_on`/`unlock` in
data/decks.lua, data/run_upgrades.lua, data/statuses.lua, data/glossary.lua,
data/rail.lua, the mechanic lines in data/story.lua; and for Balatro the
English localization file (all 150 Jokers, 32 Vouchers, 22 Tarot, 18
Spectral, 16 Backs, 24 Tags, enhancements, editions, seals) plus the wiki.

## Verdict

The game's copy is not vague sentence by sentence. It is vague across
sentences: the same mechanic is written a different way almost every time it
appears, so the player has to learn each line as prose instead of reading it
as a rule. Balatro's text is not smarter or shorter. It is the same ten
sentence shapes and the same forty nouns used four hundred times, with the
operation carried by notation (`+`, `X`, `$`, `1 in N`) instead of by verbs.
That is the whole difference, and it is fixable in data.

The counts below are from the current tree.

| Mechanic | Ways it is currently said | Where |
|---|---|---|
| A win moves up one pot size | 7 | boost, bumps one tier, reads a tier higher, read a tier bigger, reach a tier higher, run a tier bigger, lean Large |
| A loss moves down one pot size | 4 | soften, read one tier smaller half the time, lean Small, lose N% less |
| Multiply money | 10 | 1.2×, 5.0×, pay double, pay quadruple, pay 4×, pay 25% more, pay 50% more, +N% cash winnings, twice as hard, pays {achip} twice |
| Losses scaled | 5 | 20% softer, 40% heavier, 3× bigger, run a tier bigger, lose N% less |
| A table gets a heater | 8 | catches a heater, catches heat, heats that table, heats up, heats a neighbour, arrive as heat, on fire, running hot |
| Which other table | 7 | nearby, every nearby, the table beside it, a neighbour, a neighbouring table, another table, a random table |
| A probability | 5 | N% chance, half the time, a third, may, every N hands |
| The pot classes themselves | 3 | sizes (glossary, story), tiers (catalog, statuses), Large/Small as words (Maniac, Nit) |
| A stake | 3 | stake, rung, table tier (The Bank) |
| Trigger then effect | 6 skeletons | see A3 |

## Part A: the game

### A1. "Tier" and "size" name the same thing, and "tier" also names a stake

The House teaches pot classes as **sizes**: "Hands come in four sizes"
(glossary), "You can see the size of the win here" (story). Every catalog
and status line calls them **tiers**: "reads a tier higher", "bumps one
tier", "Next pot bumped one tier". The player is taught one word and sold
under another.

The Bank then uses "tier" for a stake: "+7.5% cash winnings per table
tier". Stakes are "rungs" in the glossary and "stakes" everywhere else. So
"tier" is doing two jobs and neither is the taught word.

Recommendation: one word, and it is the one the House already teaches.
Better still, no word: the glyphs already are the noun. `{w:small} {arrow}
{w:medium}` reads without "tier" or "size" in it.

### A2. Seven verbs for one effect kind

`win_tier_shift` and `win_tier_bump_chance` are two effect kinds (a fixed
from/to step, and "any win, one step up"). Copy uses seven verbs across
them and the split does not follow the mechanic:

| Line | Effect kind |
|---|---|
| "25% chance to **boost** {small} {arrow} {medium}." (Stack of Books) | win_tier_shift |
| "45% chance {small} {arrow} {medium}." (corrupt: verb dropped) | win_tier_shift |
| "8% chance a win **bumps one tier**." (Chrome Toaster) | win_tier_bump_chance |
| "Half your wins **read a tier bigger**" (Maniac capstone) | win_tier_bump_chance |
| "a table's next win **reads a tier higher**" (House Cat, Tower Upgrade) | next_win_tier_up status |
| "Next pot **bumped one tier**." / "The next pots **run a tier bigger**." (MARKED blurbs) | tier_bump_chance |
| "Wins **reach a tier higher**." (SHARP blurb) | tier floor |
| "Wins **lean Large** and {w:stack}, +10% each" (Maniac bonus) | win_dist_shift (a different mechanic: odds, not a step) |

Losses mirror it: "soften {l:large} {arrow} {l:medium}" (Throw Pillow),
"read one tier smaller half the time" (Nit and Closer capstones, which are
the same effect kind as Comfort Bed's "15% chance to soften"), "lean Small".

The corrupt lines show the fix already: "45% chance {small} {arrow}
{medium}." has no verb and loses nothing. The glyph and the arrow are the
sentence. One shape for every step: `N% chance: {from} {arrow} {to}`. The
"any win, one up" kind needs its own one shape, used by Toaster, Maniac
and the MARKED blurb alike.

### A3. Six skeletons for "on trigger, chance, effect"

The proc items say the same three-part rule six ways:

- "Winning a {stack}: 25% chance that table catches a heater." (colon)
- "Every 25 hands, a Zoom table catches a heater." (comma, no chance)
- "Knockouts have a 20% chance to heat a nearby table." (subject has a chance)
- "When a 6-max is tilted: 50% chance another table catches a heater." (When, colon)
- "A rebuy has a 50% chance to heat that table." (article-subject has a chance)
- "Win a {stack} and every Zoom table settles at once." (imperative and)
- "After a tilt runs its course, 25% chance the table heats up." (After, comma)
- "A tilt landing on an already tilted 6-max heats the table beside it." (participle)

Balatro uses one: `When [event], [effect]` for triggers and `[N in M]
chance [effect]` for probability, and nests them in that order. Pick one
skeleton for the twenty proc lines. The colon form is already the most
used here and scans best in a single line: `Trigger: N% chance, effect.`

### A4. Multiplication is written ten ways

"{stack} pays 1.2×", "5.0×", "pay double", "pay quadruple", "pay 4×",
"pay 25% more", "pay 50% more", "+50% cash winnings", "twice as hard",
"pays {achip} twice", "2.5× stronger", "25× last run's bankroll", "8× XP",
"3× bigger". Same operation. The reader has to convert each one.

Balatro writes exactly two forms and the form is the operation: `+N`
(additive) and `XN` (multiplicative). "Double" appears four times in the
whole game and never on a number that could be written XN.

Recommendation: additive is `+N%`, multiplicative is `×N`, and "double",
"quadruple", "twice", "N× bigger", "N% more", "N% less" go. "5.0×" and
"1.2×" become "×5" and "×1.2" (no trailing .0; "4×" already drops it).
"Losses 20% softer" becomes "{c:lost:Losses} ×0.8", or if that is too
cold, "{c:lost:Losses} -20%"; either way the whole loss family
(softer/heavier/bigger) collapses to one.

### A5. Probability is a percentage, except when it is not

The deck header rule says "every 'never' is a percentage." The copy has
"half the time" (two capstones), "a third catch heat, a third tilt, a third
nothing" (Framed Diploma), "Every N hands" (a certainty written as a
rhythm), and **"may"**: "A 6-max **may** take a status aimed at the table
beside it" (Console Television). The router rolls 50%. The one line with
no number is a line that has a number.

Balatro's rule: every probability is `N in M`, always green, never a
percentage, so "Doubles all listed probabilities" (Oops! All 6s) is
unambiguous: the green numbers. This game's numbers (8%, 12%, 15%, 35%)
do not fit "1 in N", so keep percent, but keep it everywhere: "50%", "33%
each", and no "may".

There is no free colour for chance (the seven meanings are spoken for),
which is fine; the consistency does the work the colour does in Balatro.

### A6. Heat has eight spellings and terms.lua licenses five of them

"catches a {c:heat:heater}" (6 items), "catches {c:heat:heat}" (3),
"to {c:heat:heat} that table" (verb), "heats that table" (untinted verb),
"heats the table beside it", "heats a neighbour", "heats up", "arrive as
heat", "on fire" (story), "running hot" (status blurb), "burnt-out heater"
(Hot Hand). The status is named HEATER on the felt. data/terms.lua lists
heat, heater, heaters, on fire, hot as one meaning, so the lint passes all
of them.

One noun, and it is the one on the pill: **a heater**. A table "catches a
heater". Nothing "heats", nothing is "on fire", nothing "heats up". The
verb form is what makes "heats the table beside it" and "heats a neighbour"
drift; with the noun fixed the sentence has to say what catches it.
Tilt is in better shape (lands on, aimed at) but "spent on", "runs its
course", "takes for a neighbour" are three more.

### A7. "Nearby" hides two radii and "another" hides a third rule

data/procs.lua defines nearby as Manhattan distance on the board, and the
items use radius 1 (Gaming Chair, Shredder, Tower Upgrade) and radius 2
(Curved Monitor) under the same word "nearby". "The table beside it" is
radius 1 with a random pick. "Another table" and "a random table" are
`any_other`. So there are three targeting rules and seven phrasings, and
the phrasings do not partition the rules.

Recommendation: two words, one per rule. "the table beside it" for
adjacency (and if radius 2 must exist, say "within two tables"); "a random
table" for any. Kill nearby, neighbour, neighbouring, another.

### A8. Words the player was never taught

- **Knockout.** Six items and a deck level on it ("Knockouts have a 20%
  chance…", "Levels on knockouts", "Each knockout's effect lands on {n}
  more table"). The glossary's Tournaments entry never uses the word. In
  code it is one seat busting out of a tournament. Balatro would never put
  an unexplained noun on a card; here it needs a glossary line or a
  different word ("Each seat you bust in a tournament…").
- **Status.** "A 6-max may take a **status** aimed at the table beside it."
  Dev vocabulary. The player knows heaters and tilts, not the class.
- **Ratchet.** Prize Vase says "lifts every table 1% for the run";
  Whiteboard says "tournament wins **ratchet** twice as hard". Same
  mechanic, two names, one of them never introduced. Also: 1% of what.
- **Sweep / settles / resolves / cascade.** Receipt Printer: "every Zoom
  table settles at once". Copy Machine: "The Receipt Printer's **sweep**".
  Firehose capstone: "**resolves** every other Zoom table on the spot".
  Code: cascade. One effect, four words, across two surfaces.
- **Unbanked.** Bounty Hunter: "+5% {w:stack} chance at **unbanked**
  tables". The taught word for a table that has not paid its {chip} is
  **paid** ("You can tell if a table's paid by the border"). "Banked" is
  the shove column. The deck uses the wrong one of the two chip words.
- **Focus capacity.** Second Monitor: "+2 focus capacity". The rail says
  FOCUS and TABLES; the glossary says "raise your Focus". "Capacity" is
  new.
- **Tournament finish / First place / tournament win / knockout** are four
  events on the tournament and the copy does not say which is which.

### A9. Flavor is inside the effect line

The schema separates `effect_text` (mechanical) from `description`
(flavour). Nine lines put the flavour in the effect slot:

- "Opens the 6-Max tables, **the deep game**." (Bonsai)
- "**The table in the board's top-left corner plays on the rug:** +2% win chance." (Red Rug)
- "**The corner is the basket:** a tilt aimed anywhere…" (Waste Basket)
- "**The plan, drawn out:** tournament wins ratchet twice as hard." (Whiteboard)
- "The Receipt Printer's sweep DEALS the Zoom tables it finds empty." (Copy Machine)
- "Cursors **never pause to clean their trackballs**." (Desk Lamp)
- "Cursors **see everything and forget nothing**." (Desk Lamp corrupt: what does it do)
- "Cursors **coordinate targeting**: no two race to the same table." (Telephone)
- "Winning a {stack} sends the cursors **into overdrive**: double speed for 10 seconds." (Cleaning Robot)

Balatro's cards carry no flavour text at all; the name and the art do it.
This game has a description slot for it. Move the metaphor down a line
and leave the rule.

### A10. Two grammars for one sticker

Catalog unlock stickers are a noun phrase that finishes the counter's
sentence ("0 / 100 tables busted"). Deck unlock stickers are an imperative
("Play 3,000 Zoom hands", "Bank 30 {chip}", "Hit 5,000 {w:stack}") with a
counter beside them. Same fact, two shapes, and "Hit" is a fourth verb for
winning a {stack} (win, hit, {stack} wins, whole stack). Balatro uses one
unlock grammar for jokers, vouchers and decks: "Play a total of 2500
cards" with "(N/M)" in grey.

### A11. Corrupt lines

- Receipt Printer and Bonsai: the corrupt line and effects are identical to
  the base. Corruption changes nothing and the copy says so by repeating.
- Tower Upgrade corrupt: "{c:lost:Losses} run a tier bigger." The effect is
  loss_tier_shift 35%, medium to large. No chance, no from/to. Inaccurate.
- Eleven corrupt lines restate the whole base sentence and append a
  penalty, so the card's longest line is the purple one. Balatro's pattern
  for "same plus a cost" is the second clause alone ("+20 Mult; -4 Mult
  per round"). The base line is already on the card.
- "5.0×", "3× bigger", "pay {achip} twice", "pays {achip} 3×" (A4 again).

### A12. Small inconsistencies, listed once

- 6-Max / 6-max: both, in the same file. Heads-Up and Zoom are stable.
- "at Heads-Up" / "at Heads-Up tables" / "Heads-Up" (deck, no "at") / "at
  Zoom" / "at Zoom tables" / "at 6-max" / "at tournaments" / "cash games
  at its stake".
- REBUY and DEALS in caps: REBUY is a button name, DEALS is emphasis.
- "1.2×" vs "5.0×" vs "4×".
- Maniac and Nit write Large and Small as capitalised words beside a
  {w:stack} glyph in the same line.
- Sharper Reads: "Higher win chance" (card) / "Raises your odds of winning"
  (tooltip) / "+N% win chance" (every item). Pot Control: "More {w:stack},
  fewer {l:stack}" is the only place the mechanic is put that plainly.
- "T10 ULTRA stake" / "Ultra stake" / "the top table".
- "for the run" / "each run" / "Your run's first" / "this run" all fine;
  "for 10 seconds" is the only real-time duration in the catalog and reads
  like one.

### A13. What already works

- The colour code is stricter than Balatro's: seven meanings, one word
  set per meaning, a lint. Balatro has a dozen colours and a catch-all
  "attention" used 415 times, three times more than any other code.
- The tier glyphs with a win/loss prefix have no Balatro equivalent and
  are stronger than any word would be. They are underused: the copy keeps
  adding verbs around them.
- Deck tooltips show the bonus in play now with the per-level rate in grey
  beneath it. That is Balatro's "(Currently +X Mult)" pattern, done.
- "Levels on X" is one shape used twelve times. It is the only field in
  the game with one shape.
- Locked cards show what the object is and how to earn it, never what it
  does. Balatro's "Not Discovered" cards make the same promise.

## Part B: Balatro

How the text on a Joker, Voucher, Tarot, Tag or Back conveys its rule.

### B1. A closed vocabulary

Roughly forty nouns cover every card: Mult, Chips, X Mult, $, hand, discard,
hand size, Joker slot, consumable slot, Blind, Boss Blind, round, run, shop,
reroll, sell value, played, scored, held in hand, full deck, face card,
Enhanced, Edition, Seal, poker hand, level, rank, suit, Tarot, Planet,
Spectral, Booster Pack, Tag. About fifteen verbs: gains, gives, earn,
create, destroy, retrigger, upgrade, copies, adds, converts, enhances,
prevents, disables, allows, sell. Nothing is a synonym of anything else.
"Retrigger" is never "replay" or "score again". "Destroy" is never "remove"
or "lose". Once you have read twenty cards you have read the language.

### B2. The operation is in the notation

`+4 Mult`, `+50 Chips`, `X1.5 Mult`, `$3`, `+1 hand size`, `-1 hand`,
`1 in 4 chance`. Sign, number, unit, in that order, every time. The player
never converts "double" or "25% more" into an operation; the symbol is the
operation. Percent appears twice in 400 strings, both times as a fraction
of something ("25% of required chips", "25% off"), never as a probability.

### B3. Ten skeletons

- static: `+N Unit`
- conditional: `+N Unit if played hand contains a [Hand]`
- per card: `Played [X] cards give +N Unit when scored`
- scaler: `This Joker gains +N Unit [per/every/when] [event]` then `(Currently +N Unit)`
- trigger: `When [Blind] is selected, [effect]`
- money: `Earn $N [at end of round | if …]`
- retrigger: `Retrigger [all/each/first] [played/held] [cards]`
- chance: `1 in N chance [to/for] [effect]`
- self-cost: `+N Unit; -N Unit per [round/hand]`
- sell: `Sell this card to [effect]`

The same family always gets the same skeleton, so the eye lands on the
number and the condition and skips the rest. Fifteen suit/hand jokers are
literally one template with two variables.

### B4. Two layers of colour

Category colours name a unit: red Mult, blue Chips, yellow money, green
probability, purple Tarot, and so on. Then a highlighter, "attention", marks
the condition noun in any sentence (face, Blind, first hand, consecutive,
Ace, King, 4 cards). So a card reads as: what unit, what condition. Grey
("inactive") is the third layer and means "not the rule": current values,
examples, "(Must have room)", "(A, 9, 7, 5, 3)". The game's seven-meaning
code is the first layer; it has no highlighter and no grey, which is a
choice worth keeping, but note the highlighter is what lets Balatro point
at the condition without a verb.

### B5. Scalers show their current value

Every accumulating Joker (about thirty) ends with "(Currently +X)" in grey,
computed live. The card is the readout. The deck tooltips do this; catalog
items that accumulate (Prize Vase's lift, High Roller Pass's bonus, House
Cat's count to the next proc, Cleaning Robot's ten seconds) do not.

### B6. A referenced thing explains itself beside the card

`{T:tag_double}`, `{T:v_crystal_ball}`, `{T:c_fool}`: a card that names
another object opens that object's box next to it. Enhancements, seals and
editions on a playing card do the same. Nobody memorises what a Steel Card
is. The catalog has items that name other items (Copy Machine names the
Receipt Printer; Calculator names Sharper Reads and Pot Control; Whiteboard
depends on Prize Vase) and none of them show the referenced thing.

### B7. Scope and timing are always stated, from a closed set

"when scored", "held in hand", "at end of round", "when Blind is selected",
"when discarded", "per hand played", "this round", "this run", "every
round", "permanently". A card never leaves the reader asking "for how
long" or "counting what".

### B8. No flavour on the card

Name and art carry all of it: Gros Michel, Ride the Bus, Oops! All 6s,
Egg, Ice Cream. The rule line is pure rule. The few tonal touches are
marked as not-rule: "Does nothing?" in grey (Blank), "self destructs" in
red with a shake (Mr. Bones), Misprint's randomised number.

### B9. One unlock grammar everywhere

"Play a total of 2500 cards", "Discard a total of 2500 cards", "Reroll the
shop a total of 100 times", "Win a run", "Lose 5 runs (2/5)", "Reach Ante
level 12". Jokers, vouchers, backs: same shape, progress in grey.

### B10. Vagueness is deliberate and marked

Blank's "Does nothing?", Erratic Deck's "randomized", Misprint, and every
undiscovered card's "Purchase or use this card in an unseeded run to learn
what it does". Hidden is stated as hidden. Once shown, a rule is exact.
That is the analogue of the "???" sticker and of corruption's "not his"
text, and it supports the House-voice decision: the mystery is allowed to be
vague because it announces itself; the catalog rule is not.

### B11. Where Balatro is not clear, honestly

"Retrigger" is never defined on a card. "Scoring card" versus "played card"
(Splash) is a distinction most players learn the hard way. "Full deck"
versus "deck". "Held in hand" versus "in hand". Order of operations across
Jokers (left to right) is written nowhere on a card. The wiki carries the
interactions. So Balatro is not accurate all the time at the system level;
it is accurate and consistent at the sentence level, and the consistency is
what makes the interactions learnable. That is the standard to hold this
catalog to: one shape per rule family, one word per noun, the operation in
the notation.

## Part C: the style sheet this implies

Not applied. Each rule names the lines it would touch.

1. **Pot classes are glyphs, and the taught noun is "size".** Delete
   "tier" from player copy (catalog, statuses, The Bank). A step is
   `N% chance: {from} {arrow} {to}`. "Any win one step up" is one fixed
   phrase used by Toaster, Maniac and MARKED.
2. **Two number forms.** `+N%` / `-N%` additive, `×N` multiplicative.
   No double, quadruple, twice, more, less, softer, heavier, bigger,
   stronger. Touches ~25 lines.
3. **Percent everywhere for chance.** 50%, 33% each. No "may", no "half
   the time", no "a third".
4. **One trigger skeleton.** `Trigger: N% chance, effect.` (or `When X,
   Y.` if you prefer; pick one). Touches ~20 proc lines.
5. **One heat noun.** A table "catches a {c:heat:heater}". Trim
   data/terms.lua's heat list to heater/heaters so the lint enforces it.
   "On fire" can stay in the House's mouth only.
6. **Two target words.** "the table beside it" (adjacent) and "a random
   table" (any). Kill nearby, neighbour, neighbouring, another. Curved
   Monitor's radius 2 either becomes radius 1 or says "within two tables".
7. **No untaught nouns.** Knockout, status, ratchet, sweep/resolve, unbanked,
   focus capacity: each gets a glossary line or the taught word.
8. **Flavour in `description`, never in `effect_text`.** Nine lines move.
9. **One unlock grammar** across catalog and deck stickers.
10. **Corrupt lines say only what changed**, and a corrupt line identical to
    base is a bug (Receipt Printer, Bonsai).
11. **Referenced items show beside the card** (Copy Machine, Calculator,
    Whiteboard): a UI change, but it is the one Balatro feature this
    catalog visibly lacks.
12. **Accumulators show their current value** in the muted colour under
    the effect line, like the deck tooltip already does.

### Before and after, twelve lines

| Now | Under the sheet |
|---|---|
| 25% chance to boost {small} {arrow} {medium}. | 25% chance: {w:small} {arrow} {w:medium}. |
| 8% chance a win bumps one tier. | 8% chance: any {c:won:win} one size up. |
| Half your wins read a tier bigger, the other half pay double. | {c:won:Wins}: 50% one size up, 50% ×2. |
| {c:lost:Losses} 20% softer. | {c:lost:Losses} ×0.8. |
| {c:lost:Losses} 3× bigger. | {c:lost:Losses} ×3. |
| Heads-Up bounties pay double {chip}. | Heads-Up {c:chip:bounties} ×2 {chip}. |
| Knockouts have a 20% chance to heat a nearby table. | Bust a tournament seat: 20% chance the table beside it catches a {c:heat:heater}. |
| A 6-max may take a status aimed at the table beside it. | A {c:heat:heater} or {c:tilt:tilt} aimed beside a 6-max: 50% chance it lands on the 6-max. |
| Every rebuy heats that table. | Rebuy: that table catches a {c:heat:heater}. |
| The Receipt Printer's sweep DEALS the Zoom tables it finds empty. | The Receipt Printer also deals the empty Zoom tables. |
| +5% {w:stack} chance at unbanked tables | +5% {w:stack} chance at unpaid tables |
| +7.5% cash winnings per table tier | +7.5% {c:won:wins} per stake |

Every "after" line is one skeleton from Part B applied with this game's
glyphs and colour code. The voice survives because it was never in the
effect lines; it is in the names, the descriptions and the House.
