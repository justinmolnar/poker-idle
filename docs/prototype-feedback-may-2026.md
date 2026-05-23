# Prototype Feedback — May 2026

First public drop. Posted to itch.io + r/incremental_games on 2026-05-18 with a "looking for feedback" framing. This doc captures the analytics snapshot, the feedback themes, and the design discussion that came out of reading them. Solutions here are direction-level, not implementation specs.

## Analytics (5 days post-launch)

| Metric | Value |
|---|---|
| Views | 1,634 |
| Browser plays | 1,255 |
| Page → play conversion | **~77%** |
| Downloads | 6 |
| Ratings | 3 |
| Collections | 9 |
| Comments | 3 (itch) + ~10 (reddit) |
| 7d impressions | 28.9k |
| CTR | 3.05% |

Shape: single spike on launch day (~740 views), decaying over 4 days to near-zero. Normal for a one-shot post with no follow-up.

**Read:** page-to-play conversion is strong — the title, screenshots, and pitch are pulling their weight. The bottleneck isn't getting players to start; it's what happens in the first 2 minutes after they do.

## Feedback summary

Sentiment overall: healthy. No "this game is bad" comments. Every negative note is "I like it / it looks cool BUT this part was awkward," which is the constructive version of negative feedback. The prototype did its job — it validated that people want to play this and surfaced specific friction points.

### Theme 1: Onboarding is opaque *(dominant theme)*

Almost every commenter hit some version of this:

- "no idea what PP, BB, Shove, or 0% mean" *(eatmyscoobysnacks)*
- "lost all money in 5 seconds, couldn't figure out what to do" *(PerfectFriendship146, koshail)*
- "built a table, dealt twice, no money, stuck" *(FrontBadgerBiz)*
- "if you put idle in the name don't make me RNG my way through hundreds of games manually" *(IAmSoDamnGood)*
- One commenter correctly reverse-engineered the intended design (forced loss → Shove → catalog → real game) but framed it as detective work *(kasumitendo)* — itself a tell that the design intent isn't surfacing in-game

The itch page and reddit post both had clear written instructions. **Players did not read them.** External text is not a substitute for in-game teaching, and the fact that having the instructions handy during self-playtesting masked the severity of this from the dev.

### Theme 2: Post-shove rebound rug-pull

> "I prestiged, got a poster, tried again. Bought a table, lost twice, am broke." — *FrontBadgerBiz*

Matches a known pacing issue from self-playtesting. The intro bankruptcy is **narrative** — it's a scripted tutorial beat per `demo-balance.md` Run 0 framing. The post-shove rebound bankruptcy is **just variance** at the floor stake, and reads as the game being unfair rather than as a designed moment.

### Theme 3: Progression curve feels backwards

> "Instead of saving ages for a 2x upgrade, get the 10% upgrades first for cheaper. The extra table unlocks in the prestige or something? They are the most valuable upgrades but also the very first one you have access to, which makes any prestige unlocks feel lackluster." — *Kesash*

The first available upgrade (+1 table) is a 2x income jump. Every subsequent upgrade feels small in comparison. Suggestion: cheap %-upgrades available first, additional table slots gated behind prestige.

### Theme 4: Opaque catalog descriptions

> "'Read your opponents better' doesn't really tell me anything." — *Kesash*

Catalog needs concrete numbers (+X% win rate per level, etc). Players are spending hard-earned PP and need to know what they're buying before they commit.

### Theme 5: Zoom hands not contributing to PP

> "...especially from zoom games as they seem not to count for some reason for a very long time even after winning multiple hands in the row." — *rahares*

Concrete pacing claim worth verifying against the data. Either there's a bug, or zoom's smaller pots are pushing jackpot frequency below what feels reasonable.

### Theme 6: Bug — esc menu crash

> "couldnt restart, when trying so via escape menu game crashes" — *PerfectFriendship146*

Needs investigation.

### Theme 7: Positive signal

Players who cleared the onboarding wall liked it. Specifically called out:

- Animations, UI, sound design *(Kesash: "amazing")*
- "The loop is engaging" *(Kesash)*
- "Fun idle game with different concept" *(rahares)*
- "Looks soo rad" *(SuspeceousPateto)*

This is the part you can't fake — if onboarding worked, more players would land here.

## Design discussion

Two distinct problems came out of the feedback. They're related but have separate solutions.

### Problem 1: Post-shove rebound RNG → "Captor spots you"

Direction: a **contextual bail-out button** that resets the player to starting bankroll *without* triggering Shove + catalog. Flavored as the captor spotting the player a fresh stake (fits the institutional-cheerful tone established in `designv2.md`).

**Trigger condition:** appears only when player is bricked — **no tables open AND bankroll < cheapest buy-in.** Does not appear during normal play. The trigger condition is the entire rate limit; you have to actually be stuck to see it.

**Placement:** overlapping or adjacent to the Shove button on the bricked state. Tooltip: *"Reset to starting bankroll without shoving."*

**Cost:** none. Adding a cost punishes the player for the RNG outcome we're trying to soften, which is the opposite of the mechanic's job. The Shove option is still right there, and the player will choose it when they have meaningful PP banked this run — that's the natural decision point.

**Why decoupling matters:** Shove is currently doing two jobs — "I'm stuck, get me out" (recovery) and "I made progress, let me cash in" (prestige). Separating them lets Shove stay ceremonial as the intentional prestige beat, while captor handles the everyday "ugh, bad run" moments.

**Tutorial compatibility:** captor **does not exist before first Shove.** Before first Shove, the tutorial bankruptcy still routes to Shove as the only option (preserves the Run 0 narrative beat). After first Shove unlocks captor, it becomes the lightweight everyday safety net. This sequencing teaches both mechanics in the right emotional order:

1. First bankruptcy → *"Shove is the only way out. It's heavy and dramatic."* → teaches Shove as the prestige beat
2. Captor unlocks (either as a side effect of first Shove, or as a near-free first catalog purchase)
3. Subsequent bankruptcies → *"I have the lighter option now."*

The contrast is the lesson. Captor only feels lightweight because Shove was experienced first as the heavy version.

**Self-deprecating curve:** as PP upgrades raise starting bankroll and shove %, the joint probability of the bricked state approaches zero. The mechanic retires itself without an explicit gate — but this only holds if cheapest buy-in scales **slower** than starting bankroll. Sanity-check the buy-in/bankroll formulas to make sure the gap monotonically widens.

### Problem 2: Onboarding → forced-acknowledge modal

For the prototype phase, a **one-page modal that forces the player to click through before play starts.** Not the production answer — the production answer is scripted in-game teaching beats with contextual overlays at the moments they're needed. But for a prototype where the goal is validating the loop, a modal is cheap, easy to remove later, and infinitely better than the current ~0% read rate on the itch page.

**Content priorities (in order):**

1. **The punchline first:** *"You're going to lose your starting money — that's intentional. It teaches you Shove, the main progression mechanic. After your first Shove, buy the Poker Poster from the catalog to start playing for real."* This single paragraph converts every "I lost in 5 seconds, game broken" comment into "ah, that was the tutorial."
2. **Annotated screenshot:** one UI shot with arrows pointing at bankroll, EV, deal button, shove button. Does more work than three paragraphs.
3. **Brief glossary:** PP, BB, EV, jackpot — each one short line.
4. **Tone-setting:** *"This is a prototype, expect rough edges, here's what to focus on for feedback."* Preempts a chunk of "this is buggy" feedback by framing roughness as expected.

**UX rules:**

- **One page, no Next button.** Dropoff jumps the moment you add pagination.
- **One real button, labeled with the action.** *"Got it, deal me in"* beats *"OK."* The label is the last microbeat of teaching.
- **Replayable from a persistent help button.** Means the modal can be denser without optimizing for one-shot comprehension.

### Smaller wins worth bundling with the above

- **Jargon expansion on first appearance.** First time the UI shows "PP" it reads as "Poker Points (PP)"; subsequent uses are just "PP." Same for BB, EV. Costs almost nothing, kills 80% of the "what does this mean" comments.
- **Numbers on catalog items.** "Read your opponents better" → "+X% win rate per level." Kesash explicitly asked for this.
- **Fix esc menu crash.** Investigate PerfectFriendship146's report.
- **Verify zoom PP contribution.** rahares' claim that zoom wins weren't counting toward PP for a long stretch needs to be checked against the data.

### Out of scope for the next pass

- **Restructuring the progression curve** (Kesash's table-slot-vs-%-upgrade ordering). Real concern but a bigger design conversation than the immediate prototype fix needs. Note it and revisit.
- **Production-grade scripted in-game tutorial.** Comes after the modal validates that the loop holds with proper context — no point building it twice.

## Open questions

- Does the buy-in / bankroll formula monotonically widen with PP upgrades? (Determines whether captor auto-retires correctly.)
- Should captor unlock automatically as a side effect of first Shove, or as a near-free first catalog purchase? Both work; auto-unlock is simpler, catalog-item is more pedagogical.
- Should the onboarding modal also cover game-type differences (6-max, Heads up, Zoom, MTT), or keep those for in-game discovery? Risk: bloating the modal past the one-page rule.

## Takeaway

The prototype hit two of its goals — it validated that the concept pulls players in, and it surfaced a coherent, fixable list of friction points rather than a vague "this isn't fun." The headline fixes for the next pass are captor-bailout (so the post-shove rebound stops feeling like punishment) and the onboarding modal (so the intro bankruptcy reads as a tutorial beat instead of a broken game). Everything else is downstream of those two.
