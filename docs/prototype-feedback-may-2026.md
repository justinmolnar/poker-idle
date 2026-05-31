# Prototype Feedback — May 2026

First public drop. Posted to itch.io + r/incremental_games on 2026-05-18 with a "looking for feedback" framing. This doc captures the analytics snapshot, the feedback themes, and the design discussion that came out of reading them. Solutions here are direction-level, not implementation specs.

**Update 2026-05-30:** itch's own discovery engine gave the page a second, larger push in week 2 (surfaced on new-and-popular / tag-incremental / tag-idle browse pages — see referrers below). Roughly 4× the launch-day traffic and a fresh batch of comments. The second-wave analytics and feedback are folded in below; the new comments both *reinforced* the week-1 themes and surfaced two issues week 1 didn't (an endgame MTT payout bug and an endgame solved-state). Grounded root causes for the recurring PP-confusion and the MTT bug are now in the design discussion — they're no longer "needs investigation."

## Analytics — week 1 (5 days post-launch)

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

## Analytics — week 2 (cumulative, as of 2026-05-30)

| Metric | Week 1 | Cumulative |
|---|---|---|
| Views | 1,634 | **8,741** |
| Browser plays | 1,255 | **6,321** |
| Page → play conversion | ~77% | **~72%** |
| Downloads | 6 | 61 |
| Ratings | 3 | 19 |
| Collections | 9 | 71 |
| Comments | ~13 | ~14 (itch) + reddit |
| 7d impressions | 28.9k | **353k** |
| CTR | 3.05% | **1.38%** |

Shape: the launch-day spike decayed to near-zero by ~May 21, then a **second, larger hump** ran ~May 22–26 (peaking ~1,700 views / ~1,250 plays per day) before tailing off into the 30th.

**Where the second push came from:** the top referrers are all *itch's own browse/discovery surfaces*, not an external repost — `itch.io/` (1,204), `games/platform-web` (827), `games/tag-incremental` (821), `new-and-popular/platform-web` (663), `games/tag-idle` (480), and a long tail of new-and-popular × tag permutations. Reddit is a distant secondary (191). So this was itch algorithmically surfacing the game on new-and-popular and the incremental/idle tag pages — editorial/algorithmic lift, not a campaign we ran.

**Read:**
- **Conversion held under 4× the volume** (~77% → ~72%). The page is robust; broader, colder browse traffic only cost ~5 points. The pitch still works.
- **CTR fell 3.05% → 1.38% — and that's fine.** Impressions ballooned 10× (28.9k → 353k) because tag/browse placement shows the thumbnail to a much wider, less-targeted audience. Lower CTR on an order of magnitude more impressions is the expected, net-positive trade.
- **The funnel bottleneck is unchanged and now better-sampled.** ~5× the plays of week 1 ran into the same week-1 walls. The second wave didn't change the diagnosis — it raised the confidence and N behind it.

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

## Second-wave feedback (week 2)

The itch push brought ~11 new commenters. They split clean: most re-hit the week-1 walls (confirming the diagnosis at higher N), and two reached the *endgame* and found problems week 1's players never got far enough to see. New commenters: Finvalli, ZombiePanda13, boazz, onciblu, keetony, pickledoge, SeninWorld, WolfOfRavens, Lakkendoes, kalux, IllFatedStudios.

### Reinforced — "how do I earn PP?" is now the dominant complaint *(was Theme 1, now its own crisis)*

Week 1 had one or two "what's PP" notes folded into general onboarding confusion. Week 2 made PP-legibility the single most-repeated failure:

- "I honestly have no clue how I am earning PP. After a dozen shoves… I still do not know how the PP is earned. Needs some sort of consistency." — *ZombiePanda13*
- "On my 20th run at least and haven't got a single point… I just keep busting both at the table and during the shove." — *kalux*
- "Doesn't seem possible to get the first prestige point." — *pickledoge*
- Finvalli (who *did* solve it) describes it as multi-step reverse-engineering: "It took me a while to figure out the whole process of getting PP."

This is no longer "needs investigation" — the mechanic is now traced (see Design discussion → **Problem 3**). PP is awarded only on the **first jackpot win per (stake, game-type) bracket**, banked on Shove. Winning ordinary hands grants nothing; the player has to (a) hit a *jackpot*, which (b) at most stakes requires Pot Control to even be probable, and (c) only banks when they Shove. None of those three gates is surfaced. Players doing the obvious thing — winning hands — correctly observe their PP stays at zero.

### Reinforced — early-game is unwinnable until you find the hidden free unlock

The "I just lose, every time" cluster got much louder, and one comment cracked the cause open:

- "Fail. Fail. Fail… No chance to game." — *SeninWorld*
- "I just keep losing. Bought sharper reads once, promptly lost anyway, and it was gone once I reset." — *boazz*
- "If this was actually random then shove should be winning 50% of the time. I played 20+ hands and lost 100%… your odds of winning are far too low in the regular game." — *WolfOfRavens*
- **The fix, surfaced by a player to other players:** "skill issue. Seriously, open the catalog and buy the free skill. It makes you win more than lose." — *onciblu*

onciblu's "free skill" is the **Poker Poster** (`cost_pp = 0`). It silently removes the `no_poster_handicap` — a `wc_mult = 0.4` debuff plus a loss-distribution skew that the game auto-applies on run 0. Run 0 is *designed* to be near-unwinnable (~20% win chance); buying the free Poster restores normal poker math. The problem: nothing tells the player the debuff exists or that a free item lifts it, so WolfOfRavens' "odds are far too low" is a correct reading of an *un-removed tutorial handicap*, and players are getting rescued by word-of-mouth in the comments instead of by the game. This is exactly what Problem 2's modal is for — but it confirms the modal must name the free Poster explicitly, not just allude to it.

### Reinforced — catalog descriptions still opaque, now with a tooltip ask *(Theme 4)*

- "The upgrade explanations could be more detailed. There should be tooltips when I drag on upgrades on the right. I didn't know what 'focus' did for 15 minutes." — *IllFatedStudios*

Same root as Kesash's week-1 note, plus a concrete UX request: hover/drag tooltips on the right-hand run-upgrade rail, not just the catalog.

### Reinforced — captor-bailout, independently requested by a player

The week-1 design direction (Problem 1, the no-cost reset-to-stake button) was proposed by *us* reading the feedback. A week-2 player asked for it almost verbatim, unprompted:

- "A quick reset to $2 button would be nice as the shove at 0% takes a bit of time." — *Lakkendoes*

This is direct validation that the "I'm stuck, get me out" job should be decoupled from Shove and made instant. Lakkendoes is describing the exact friction Problem 1 targets — the slow 0%-bankroll Shove being the only exit. Ships as-specified.

### New — endgame bug: high-multiplier MTT "doesn't pay off" *(blocking the completion fantasy)*

Finvalli is the first commenter to reach the content ceiling, and the payoff broke:

> "Try to get a 20x MTT just for the feeling of accomplishment… only to feel disappointment that the 10x and 20x MTT doesn't work, it resets after 8 wins (yes, I did watch it — it ticked over to the 8th win, paid out and reset back to hand one)."

**This is real and live in the shipped build.** The prototype runs with `MTT_KO = not PROTOTYPE_MODE` → **off**, so MTT uses the *legacy* binary system (`models/MttSession_legacy.lua`): it auto-plays 8 hands, pays `mtt_payouts[hands_won]` (20× buy-in at 8 cleared per `data/mtt_payouts.lua:14-18`), then resets `hands_won` to 0 and loops. There is no terminal "you won the tournament" state — the top of the ladder is an infinite 8-hand loop that re-pays and resets, which reads as the jackpot *failing to fire*. Meanwhile the richer chip-flow KO MTT (`Table.lua` / `MttSession.lua`, payout keyed by finish position) is **already built but feature-flagged off** for the prototype. Finvalli hit the stub. See Design discussion → **Problem 4**.

### New — the endgame collapses into a solved AFK state

Finvalli also documents the optimal-play attractor, which is a balance signal in its own right:

> "Farm Zoom for money → buy 3–4 Sharper Reads + Pot Control → branch into Heads-Up/6-Max → turn my brain off and click a four-square of Heads-Up tables (fastest, biggest bang for buck) → save PP for the cursor upgrade → let the game do it for me on the other monitor for 3 hours. Do this over 3 days and unlock everything. MTT is trash except for getting the unlock PP after shoving."

Read:
- **One dominant line exists** (Zoom-to-bankroll → Heads-Up four-square → Cursor) and everything else is dominated. 6-Max is a footnote and MTT is "trash except the one-time shove-unlock PP" — corroborating week-1's read that MTT is a thin stub.
- **The Cursor upgrade (`box_of_mice`, gated behind the 10-PP `cursor_pool` unlock) trivializes interaction.** Once bought, the game plays itself; the player's only input is occasionally picking upgrades. That's *fine for an idle game's late state* — but here it arrives before there's enough content depth behind it, so "everything unlocked in 3 days" lands as content-exhaustion, not idle bliss.
- **The whole game is consumed in ~3 days of mostly-AFK play.** Endgame depth/retention is the next-tier problem after onboarding — out of scope for the immediate fix pass, but logged.

### New — design tension: in-run catalog buys evaporate on Shove

> "Bought sharper reads once, promptly lost anyway, and it was gone once I reset. Either upgrades like sharper reads should persist across shoves, or there needs to be something else to help the player get started." — *boazz*

boazz conflates two upgrade tiers (run-upgrades reset by design; PP catalog items persist), but the *feeling* is legitimate: spending your scarce early resource on Sharper Reads, losing anyway, and watching it vanish on the next reset reads as a rug-pull. This is really a symptom of the early-game win-rate problem (the un-lifted Poster handicap) plus weak teaching of which upgrades are permanent vs per-run. Fix the Poster legibility and the catalog-vs-run-upgrade distinction and this complaint largely dissolves — no need to actually make run-upgrades persist.

### Reinforced — positive signal holds

Players who pushed through still liked it: "the loop is fun" once figured out *(keetony)*, "interesting game" *(ZombiePanda13)*, "definitely has potential" *(keetony)*. Same shape as week 1 — the wall is comprehension, not fun.

## Design discussion

Four problems now have concrete direction. Problems 1–2 came out of week 1; Problems 3–4 were forced into focus by the week-2 push (PP-legibility going from a footnote to the loudest complaint, and the first player reaching the broken MTT endgame). They're related but have separate solutions. **Priority order for the next pass: Problem 3 (PP legibility) and Problem 2 (onboarding modal) are now co-headline — they're the same disease (the game doesn't teach its own core loop) and a player can't progress without solving both. Problem 1 (captor) and Problem 4 (MTT) are high-value but secondary.**

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

### Problem 3: PP is invisible — players can't see the path from playing to prestige

This is the week-2 headline. The mechanic, now traced through code, has **three sequential gates the UI never surfaces**:

1. **PP comes from a *jackpot* win, not a normal win.** `GrindController` awards PP only when a hand resolves at `tier == "jackpot"`. A player winning hands all day sees zero PP and concludes the system is broken (ZombiePanda13, kalux, pickledoge).
2. **It's the *first* jackpot per (stake, game-type) bracket, once per run.** 24 bracket "bounties" (6 stakes × 4 game types), each worth its stake's `pp_award` (1–6 PP), ~84 PP for a perfect run. Repeat jackpots in a cleared bracket pay nothing — so even a player who *does* hit jackpots sees PP stop accruing and reads *that* as broken too.
3. **It only banks on Shove.** `pp_this_run` is provisional; `initiateShove()` commits it to `state.pp`. A player who never connects "Shove = cash in my run's PP" (the same player the captor/modal work targets) can earn PP all run and lose the mental model of where it went.

And underneath all three: at most stakes the **naked jackpot rate is ~2% (0% at T4+)**, only reshaped upward by **Pot Control** filling the win distribution. So "win a jackpot" is itself improbable until the player has spent PP on Pot Control — a chicken-and-egg the player has no way to see.

**Direction (not implementation spec):**

- **Make the bracket-bounty grid a visible objective.** The 24 bounties are already a clean progression structure — expose them. A small matrix (stakes × game types) showing which brackets are "claimed this run" and the PP each is worth turns an invisible rule into a checklist. This single surface answers "how do I earn PP," "why did Zoom stop paying," and "where do I go next" at once.
- **Teach jackpot ≠ win.** When a jackpot fires and banks a bounty, say so loudly and explicitly ("Bracket cleared! +N PP banked on next Shove"). The first time it happens is the teaching moment; right now it's silent.
- **Show provisional vs banked PP.** Display `pp_this_run` distinctly from `state.pp` with a clear "Shove to bank" affordance, so the Shove↔PP link is impossible to miss. This also reinforces Problem 1/2's framing of Shove as the cash-in beat.
- **Surface Pot Control's role.** Tie it into the catalog-numbers fix (smaller wins, below): Pot Control's description should read as "raises your jackpot rate" so the chicken-and-egg becomes a legible goal instead of a hidden wall.

The onboarding modal (Problem 2) should state the one-sentence version of this — *"You earn PP by hitting your first jackpot in each table type, then Shoving to bank it"* — but the modal alone won't carry it; the in-game bounty surface is what makes it stick after the modal closes.

### Problem 4: MTT endgame pays nothing climactic — ship the KO system

Finvalli reached the top of MTT and found an infinite 8-hand loop instead of a payoff. **Root cause is confirmed, not speculative:** the shipped prototype has `MTT_KO` off (it follows `PROTOTYPE_MODE = true`), so MTT runs the legacy binary stub — auto-play 8 hands, pay `mtt_payouts[8]` = 20× buy-in, reset `hands_won`, loop forever. There's no terminal win state, so the "20× MTT" reads as a jackpot that fires and then *un-fires*.

The real fix already exists in the tree: the chip-flow **8-max KO MTT** (`Table.lua` / `MttSession.lua` / `HandScript.lua`), payout keyed by finish position, built in commit 1617f0d and gated behind `MTT_KO`.

**Direction:**

- **Preferred: turn `MTT_KO` on for the next build** and let MTT graduate from stub to the real mode. This also retires the "MTT is trash" read (Finvalli, week-1 IAmSoDamnGood) — a real tournament with a real finish-position payout is a destination, not a footnote. Cost is validation/balance time on the KO path, which is why it was flagged off for the first drop.
- **Fallback if KO isn't ship-ready:** give the legacy MTT an actual terminal state — after the 8th clear, present a "tournament won" payout and *stop*, rather than silently looping back to hand 1. Cheaper, removes the rug-pull, but leaves MTT shallow.

Either way the current behavior — loop-and-reset with no climax — is the worst option and should not survive the next pass.

### Smaller wins worth bundling with the above

- **Jargon expansion on first appearance.** First time the UI shows "PP" it reads as "Poker Points (PP)"; subsequent uses are just "PP." Same for BB, EV. Costs almost nothing, kills 80% of the "what does this mean" comments.
- **Numbers on catalog items, plus tooltips on the run-upgrade rail.** "Read your opponents better" → "+X% win rate per level." Kesash and IllFatedStudios both asked for this; IllFatedStudios specifically wants hover/drag tooltips on the right-hand rail ("didn't know what 'focus' did for 15 minutes"), not just on the catalog. Pot Control's text should explicitly read as "raises jackpot rate" (ties into Problem 3).
- **Name the free Poker Poster in onboarding.** onciblu had to tell other players to "buy the free skill" in the comments. The modal (Problem 2) already mentions the Poster — make sure it's named as *free* and framed as the thing that fixes the "I always lose" early game, since that's the exact rescue players are giving each other manually.
- **Fix esc menu crash.** Investigate PerfectFriendship146's report.
- **Zoom PP — root cause found, not a bug.** rahares' "zoom wins don't count toward PP for a long stretch" is explained by Problem 3: PP needs a *jackpot* win (not a normal win), and Zoom's small pots keep the jackpot rate low until Pot Control reshapes it. The bracket-bounty surface (Problem 3) makes this legible rather than mysterious. No code bug to chase here.

### Out of scope for the next pass

- **Restructuring the progression curve** (Kesash's table-slot-vs-%-upgrade ordering). Real concern but a bigger design conversation than the immediate prototype fix needs. Note it and revisit.
- **Production-grade scripted in-game tutorial.** Comes after the modal validates that the loop holds with proper context — no point building it twice.
- **Endgame depth / content exhaustion.** Finvalli unlocked everything in ~3 days of mostly-AFK play, with one dominant strategy line (Zoom→Heads-Up four-square→Cursor) and the rest dominated. Real, but it's a post-onboarding problem — there's no point deepening the endgame until players can reliably *reach* it. Log it; revisit after the comprehension wall is down.
- **Whether the Cursor auto-clicker arrives too early.** It trivializes interaction before there's depth behind it. Tied to endgame depth above; same "later" bucket.

## Open questions

- Does the buy-in / bankroll formula monotonically widen with PP upgrades? (Determines whether captor auto-retires correctly.)
- Should captor unlock automatically as a side effect of first Shove, or as a near-free first catalog purchase? Both work; auto-unlock is simpler, catalog-item is more pedagogical.
- Should the onboarding modal also cover game-type differences (6-max, Heads up, Zoom, MTT), or keep those for in-game discovery? Risk: bloating the modal past the one-page rule.
- **Is the PP bracket-bounty grid the right primary objective surface, or does it over-expose the system?** It cleanly answers "how do I earn PP," but a 24-cell matrix on screen might read as a chore-list. Prototype it and watch whether it reads as "goal" or "spreadsheet."
- **Ship `MTT_KO` on now, or fix the legacy stub's terminal state first?** Depends on how close the KO path is to validated. Decision needed before the next build.
- **Does removing the `no_poster_handicap` need to be more visible than a free catalog buy?** onciblu's word-of-mouth rescue suggests the free Poster might warrant being *auto-granted* or aggressively prompted rather than left for the player to discover.

## Takeaway

The prototype passed its core test twice now: the second, 4×-larger itch push hit the same walls as the first, which means the friction points are *structural and reproducible*, not launch-day noise — and conversion held at ~72% under colder, broader traffic, so the concept keeps pulling players in. What the second wave changed is the priority stack. Onboarding is no longer one problem but two co-headline ones: the intro reading as broken (Problem 2's modal) **and** PP being an invisible mechanic players literally cannot find the on-ramp to (Problem 3). Those are now the gate — nearly every week-2 complaint is a symptom of one or the other. Behind them sit captor-bailout (Problem 1, now player-requested verbatim) and the MTT endgame fix (Problem 4, root cause confirmed — ship the KO system that's already built). The longer-horizon signal is that the endgame is shallow enough to exhaust in ~3 days, but that's a problem for *after* players can reach it. Get comprehension right and the rest of the funnel finally gets sampled.
