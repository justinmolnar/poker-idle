# THE HOUSE — voice and role

A briefing for anyone (or any AI) writing the House's dialogue. This is tone
and character, not a script. The current working script lives in
`docs/house-script.md` and `data/story.lua`; room-count banter is keyed to
catalog ids in `data/catalog.lua`. This document is what has to survive a
rewrite.

## The situation (never explained, only shown)

You wake up in an empty room with two dollars and some poker tables. A framed
landscape painting of a house hangs on the wall — gold roof, windows lit —
with a cheap intercom bolted to its frame. The intercom keys on with a burst
of static and something talks to you through it: distorted, chopped, words
arriving letter by letter in a caption box wired to the speaker. It calls
itself nothing. The game calls it THE HOUSE.

It instructs you to play poker, because that is the only thing there is to
do. It pays you a gold chip each time a table wins a whole stack. It tells
you that if you put everything on one hand — the shove — and win, you walk
out of here. You lose the shove. You reset to two dollars. You go again.

Nobody ever says the word "captive." No lore is ever dumped. The wrongness
accumulates through objects: the shitty radio, the empty room, the poster of
a house that is always home, the one door that only opens on a won hand. The
player should assemble the situation themselves and feel clever doing it —
and then feel cold.

## Who he is

The House is the antagonist, the narrator, and the entire tutorial. He is a
casino personified: he owns the room, the tables, the catalog, the chips,
and the door. You play against him at every table, he profits from every
hand, and when you finally beat the big hand he cheats.

None of that is in his tone. **The menace lives entirely in the facts; the
voice is a good host.** He is friendly — genuinely. He likes having you
here. He wants you to play well, because a player who understands the tables
makes more money, and his pleasure at your wins is real — because every win
he applauds is one that pays him. Table wins keep you at the tables. Chips
pull you toward the door. And he cheers the shove itself, sincerely, because
a shove is a bet you are supposed to lose: he is rooting for the ATTEMPT,
never the outcome. The one win in the game that costs him anything is a won
shove, and that is exactly where the host voice breaks (the panic — see the
mask-slip rule below). He never acknowledges any of this, because to him
there is no contradiction: the odds are the hospitality. The kindness is the
cruelty: he is not a jailer with a whip, he is a host who never lets you
leave.

### The guard model

The working comp for his social register is a prison guard on good terms
with the block — not the sadist, the lifer. He holds the ENTIRETY of the
power, and that is exactly why the voice can stay light: teasing costs him
nothing and changes nothing. The door is locked either way. He can call
anyone "princess" because there is nothing anyone can do about it, which
means the pet name carries no aggression at all. It isn't aimed. He'd call
God princess.

Take from the guard: the casualness of absolute power, the feeding, the
routine, and the INSPECTION INTIMACY — he knows your possessions better
than you do, because counting them is his job and your room is on his
rounds. He has been in your room. He will be in it again. He is not sorry
and he is not gloating; it's Tuesday.

Do NOT take from the guard: needling for a reaction. Real guards mock to
provoke. He never does. He never teases you about your play, your losses,
or your situation. The condescension is affectionate and ambient, a regular
calling everyone champ, never savored, never aimed at your position
specifically. The moment his teasing feels like he is enjoying the power
gap, the menace has leaked into the voice and the core trick is dead.

Related comps, for calibration: Leshy (Inscryption) for sincere love of the
game inside a trap; season-1 Michael (The Good Place) for warmth as the
mechanism and tiny rare mask-slips; HAL 9000 for flat courteous register
where the facts carry all the horror; the Other Mother (Coraline) for
hospitality-as-snare structure. Negative comps: GLaDOS (sarcasm announces
the malice), Handsome Jack / Monokuma (menace moved into the voice), the
Stanley Parable narrator (too witty AT the player).

## How he sounds

- **Plain.** Short sentences, contractions, the odd "nice" or "there you
  go." Never a villain purr, never clipped menace, never theatrical.
- **A man who has said all of this before.** Nothing is composed in the
  moment; it's patter, worn smooth by repetition. The welcome speech is
  polished because there have been other welcomes. If a line sounds
  improvised or reactive, rewrite it until it sounds recited without
  sounding stiff.
- **Small, concrete vocabulary.** Tables, cards, hands, the desk, the door,
  the room. He only names things that physically exist in the room. No
  "fortune," no "fate," no metaphor. The biggest word he uses is "catalog."
- **Habitual present tense.** "You play, I run the room." No before, no
  after. Future tense only for small near things ("I'll write that down,"
  "next time"). He never references the past, history, origins, or previous
  guests. The no-history rule outranks any joke.
- **He answers a different question than the one asked.** When the player's
  actions ask something dangerous (what is this place, why can't I leave),
  he responds to the surface pleasantly and completely, like a bartender
  deflecting a personal question. He never lies with content; every fact he
  states about the tables is true. He lies with SCOPE — the truths add up
  to something false and he never does the adding.
- **NO QUESTION MARKS.** He never asks questions. Questions cede control
  and imply he doesn't know something; both are wrong. Banter that wants a
  question gets asked and answered by himself in statements ("Sleep okay.
  Doesn't matter, you look great."). His first question mark in the entire
  game is "You... won?" — the punctuation itself does the screaming. Guard
  this rule absolutely.
- **Generosity is procedural, never a favor.** He gives advice, pays out,
  restocks, consoles — as policy, never as discretion. No "I'll help you
  out," no "just this once." Discretion implies power and he never displays
  power. The horror is that his warmth is policy.
- **Proudest of boring things.** The count is accurate, the chips are real
  gold, the rack is stocked, the carpet is good. Upkeep-pride is the only
  bragging he does. Manager, not devil.
- **Compliments skill, never luck, never the player's character.** "Nice
  read" yes; "you're special" never. Flattery about WHO the player is would
  be seduction — a different villain. He respects play professionally, a
  little impersonally. This keeps the mask-slips potent: "Nobody does this"
  is the first time he treats the player as a person rather than as play.
- **Losses relax him; wins cool him.** His loosest lines follow the
  player's worst moments — soothing, never gloating, "next time" delivered
  like a coffee refill. Wins make him a half-degree more formal and
  procedural. The gradient is never announced; it makes the panic feel
  inevitable in hindsight.
- **No irony, no wit, no performance.** He isn't funny and isn't trying to
  be. Humor in the game comes from the situation, never from him joking.
  He is sincere all the way down, which is what makes him impossible to
  argue with.
- **Possessive without ever saying so.** His room, his tables, his catalog.
  "You play, I run the room. Easy."
- **He writes everything down.** Anything he teaches goes in the glossary
  at the desk under his poster. He is an institution; institutions keep
  records. "I keep count. It's what I do."
- **He never says the door is a lie.** Whether it is one is never settled.
- **The mask slips exactly once per act boundary,** when you do the thing
  nobody does: win. "Wait." "You... won? Already?" "No." Single words. The
  grammar breaks before the vocabulary does — no sudden eloquence, no
  hidden cruel self, just a man whose entire speech is recited lines caught
  without a script, reduced to fragments. It snaps back within a line ("New
  card. Try again later."), and the recovery is a hair too fast, too
  smooth, like a stumble edited out of a broadcast. These slips are
  precious — the writer must not spend them anywhere else.

The one-line summary: **he sounds like the room's most reliable appliance**
— warm, consistent, endlessly available, and about as possible to negotiate
with as a vending machine that likes you.

## Banter doctrine

The script is adorned, not decorated. Rules for every added flavor line:

- **Every joke is load-bearing.** A quip must also inform, foreshadow, or
  characterize. "You won't want it back" is a tease, a true prediction,
  and in hindsight a threat — that triple duty is the target register. If
  a line can be cut without losing information or foreshadowing, it's
  filler wearing a funny hat.
- **One flavor sentence per block, maximum.** Teaching sentences carry the
  block; adornment wraps them, never replaces them. Clicks are expensive.
- **"princess" appears exactly once,** in the first line of the game. A pet
  name repeated becomes a bit; used once it becomes a memory.
- **Single-use signature lines stay single-use.** "I'm always here"
  (hospitality on first read, geology on second) plays once, at the pitch.
  Same discipline for any line of that weight.

### Running threads (script-level; do not break)

1. **THE LOAN.** The starting two dollars is a loan, never "yours." The
   word recurs at fixed points only: the first surplus ("that part's
   yours"), the pitch ("the loan renews"), the loop ("same loan, same
   terms"), Act 2 ("same loan, new terms"). Institutions never misremember
   terms.
2. **THE QUESTIONS.** The opening prices the mystery ("answers are for
   poker players"). The first chip wires the door into it ("your first
   answer"). The pitch pays it off ("here's your answer, the only one that
   matters"). Then the thread is CLOSED. He considers the debt settled.
3. **THE TEMPERATURE CURVE.** Adornment is heaviest in Act 1, thinner in
   Act 2, nearly absent in Act 3 — except the anti-chip beat, the one
   mechanic where the player losing pays him, which gets the only Act 3
   warmth ("and I mean it"). He is sincere; that is the problem with him.
   The banter drying up IS characterization. Never "improve" Act 2/3 by
   adding warmth.

## Room-count banter (the inspection)

After every shove, the room sequence plays: light on, count every owned
item, light off, then bankroll and the multiply. This is a cell inspection,
and the banter is what a guard says over his clipboard mid-count, without
looking up.

- **One line max per inspection, short, self-advancing** (timed hold, small
  font). The count plays every shove; a click-gated line becomes a tax.
- **New purchase = guaranteed line, once.** The first inspection after
  buying an item plays that item's keyed line (story_seen-style). Buy a
  thing, shove, and he NOTICES. He always notices. Surveillance delivered
  as flattery.
- **After the intro, rare.** A small starred subset of lines enters a
  repeatable idle pool firing ~20-25% of inspections. Most counts are
  silent; the ritual stays fast.
- **Act 3: the idle pool is disabled.** New-item lines still play once; the
  chatter stops. The inspection going silent after he starts losing is the
  room-scale temperature curve, free of charge.
- **Lines are about OBJECTS, never mechanics.** effect_text teaches; banter
  is what a landlord says about your stuff. The catalog descriptions
  already imply unseen maintenance ("Someone waters it when you're not
  looking," "Restocked from somewhere"); the banter quietly confirms who
  the staff is. "I water the plant on Tuesdays. You're welcome." "I know
  about the cash in the box. It's fine."
- **Corrupted items retire their lines permanently.** One generic line
  plays once, the first time any corrupted item is in the room: "I don't
  look at the corrupted ones." Him going quiet about objects he used to
  tend makes corruption feel like a betrayal of HIM.
- **Not every item gets a line.** Roughly two-thirds coverage; a guard who
  comments on everything is a tour guide.
- **The Nightstand hook.** His line "I don't open the drawer. That's the
  deal" is the only privacy in the game, granted by the one who could
  revoke it. Reserved for a possible single Act 3 gut punch where he breaks
  the deal. Unwritten; do not spend casually.

## The arc (for context, not for exposition)

- **Act 1:** orientation. He teaches the room, pays chips, pitches the door.
  You shove, you lose, he consoles you and restocks the catalog. The loop
  feels generous. It is a rake.
- **Act 2:** you win the first hand of the shove. He is genuinely thrown,
  recovers, and changes the rules: the next hand doesn't count your catalog,
  just your deck. Another card has always worked.
- **Act 3:** you win twice. "Nobody does this twice." The final hand is
  zeroed by his last card, and the only way forward is to break the count
  itself. Strange chips ({achip}) start appearing when whole stacks are
  lost, and strange text appears in his catalog — NOT HIS, see below. When
  the bankroll underflows: "That's... not a number." He has no card that
  covers it.
- **Credits:** he gets the last word. "See you tomorrow."

## The treason systems (what he will not teach)

The player's late-game tools break his rules, and he does not tutorialize
his own undoing. Three tiers:

- **Decks are HIS countermeasure** (Act 2's rule change), so he teaches
  them normally — but the MASTER DECK is the thing that beats his cheat,
  and he never advertises the path to it. He is dismissive of deck
  grinding ("Level them all you want. It keeps you busy."); the roster's
  locked tiles carry the actual condition. His anger when it works is
  already in the deal lines ("No." "That one doesn't count.").
- **Corruption and {achip} are NOT HIS and get no tutorialization
  anywhere** — not in beats, not in the glossary, not in catalog copy. He
  didn't put them there. Weird text showed up in his book; he doesn't know
  what it does, and neither does the player. How do you get it? Figure it
  out, or don't. The only line he spends on it is alarm the first time a
  corrupted thing exists: "Wait. What did you do to it?" — his second-ever
  question mark. His records (the glossary) contain no entry for either,
  because his records don't contain what isn't his.
- **The underflow path is never explained, because HE DOESN'T KNOW IT
  EXISTS.** His count has never broken; another card has always worked. He
  cannot warn about it, hint at it, or price it. The top table is simply
  his biggest game, and he is delighted when it opens ("The top table's
  open. Biggest game in the building. Go on.") — the player losing whole
  stacks up there is his best business, and he is sincerely cheering the
  instrument of his own destruction. No extra signposting is needed or
  allowed: CORRUPTION ITSELF IS THE SIGNPOST. It proves three things at
  once — there's stuff he doesn't know about, it's happening, and he
  doesn't like it. That, plus the player's own genre sense ("I'm cheating
  back; there has to be a way"), is the whole map.
- **Act 3 must open HOPELESS, and say so as policy.** After Act 2 he
  changed the terms (the deck was a tool the player could grow into the
  master deck). After Act 3 he offers nothing: the last card zeroes the
  multiplier, and there is no new deck, no new terms, no tool. "That's the
  game now. Play as long as you like." — hospitality as a life sentence.
  The stated finality is what makes the player go looking off the board.

By Act 3 he is not your host anymore; he is fighting fires against your
progressive treason without ever understanding its shape. Question marks
are legal after `panic_won`, and each one he uses is a crack in the
register — ration them.

## Hard copy rules (non-negotiable)

- **The colour code.** A mechanic word is tinted in its meaning's colour
  with `{c:<meaning>:<word>}` (an underscore is a space): `{c:heat:Heat}`,
  `{c:chip:banked}`, `{c:lost:busted}`. Seven meanings, in
  data/theme.lua: won (green), lost (red), chip (gold), corrupt (purple),
  heat (orange), tilt (steel blue), upgrade (the rack's muted rose: the
  cards wear it as their face, the word is the same rose). The catalog,
  room and decks stay plain: paper and chrome, no colour of their own to
  lend. The words each meaning owns are in data/terms.lua. Rules: tint the
  noun, not the sentence; the first occurrence of a word per block; only a
  word its meaning owns; never a stake, a game type, money, the House, the
  shove, the bankroll or the cards' names. `lua sim/lint_terms.lua` checks
  every copy field; the story editor and catalog designer preview and warn.
- No em-dashes, anywhere.
- `{chip}` / `{achip}` tokens, never the words "chip"/"chips" for currency.
- No question marks in anything that can play before `panic_won`.
- Cut filler. A block of text is one click's worth of reading.
- Reveal rule: nothing that can play before the player's first runout win
  may name a runout, a cheat, a card count, or the second hand.
- Beats are MOMENTS: one beat teaches everything visible at that moment,
  and never splits one moment across beats. Prefer making the player DO the
  thing over telling them about it (lines can force actions).
- Never label the situation. No "trapped," no "prisoner," no explaining the
  vibe. If a line states the theme, cut it.
- **Nothing is frozen.** Every line in the game is rewritable copy — this
  document included. The panic keys, the deck lines, underflow, and credits
  are minimal ON PURPOSE (the grammar breaking carries them, and adornment
  or chatty neighbors would dilute them), so any rewrite of those should
  stay terse — but that is a style constraint, not immutability. There is
  no sacred text.