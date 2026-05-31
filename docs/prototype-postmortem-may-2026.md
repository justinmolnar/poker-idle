# Poker Idle — Prototype Post-Mortem

*Build: public prototype (PROTOTYPE_MODE on). Launched 2026-05-18 on itch.io + r/incremental_games. Window: ~12 days, two distinct traffic waves. Companion to `prototype-feedback-may-2026.md` — that doc is the raw feedback log and direction-level design discussion; this is the narrative retrospective across all of it.*

---

## 1. What the prototype was actually testing

This wasn't a content drop — it was a hypothesis test with three questions baked in:

1. **Does the concept pull people in?** ("Poker, but it's an idle/incremental game" — does that pitch convert a browser into a player?)
2. **Does the core loop hold?** (Lose → Shove → spend PP in the catalog → play for real → earn PP → Shove again.)
3. **What breaks first?**

The answer to #1 is an emphatic yes. The answer to #2 is "the loop is good but almost nobody can find it." The answer to #3 is the whole middle of this document.

The single most important framing fact: **the game ships with the instructions living outside the game** — on the itch page and the reddit post. Players don't read those. So the prototype was, in effect, testing the game *without* its tutorial, and the results are what you'd expect from that.

---

## 2. The numbers, and what they mean

### Two waves, not one

| Metric | Week 1 (launch, ~5 days) | Cumulative (as of 2026-05-30) |
|---|---|---|
| Views | 1,634 | **8,741** |
| Browser plays | 1,255 | **6,321** |
| Page → play conversion | ~77% | **~72%** |
| Downloads | 6 | 61 |
| Ratings | 3 | 19 |
| Collections | 9 | 71 |
| Comments | ~13 | ~14 itch + reddit |
| 7-day impressions | 28.9k | **353k** |
| CTR | 3.05% | **1.38%** |

**The shape of the traffic tells a story.** Week 1 was a textbook one-shot post: a launch-day spike (~740 views), then a 4-day decay to near-zero. That's what a single reddit/itch post with no follow-up always does.

Then something we *didn't* do happened: around May 22–26 a **second, bigger hump** appeared — peaking at ~1,700 views and ~1,250 plays per *day*, larger than launch. The referrer breakdown explains it. The top incoming sources are all **itch's own discovery surfaces**, not an external link:

- `itch.io/` (1,204), `games/platform-web` (827), `games/tag-incremental` (821)
- `new-and-popular/platform-web` (663), `games/tag-idle` (480)
- a long tail of `new-and-popular × tag` permutations
- reddit a distant secondary (191)

Translation: **itch's algorithm surfaced the game on its New & Popular and incremental/idle tag pages.** That's an editorial/algorithmic lift, earned by the week-1 engagement (collections, ratings, play-time), not by anything we pushed. That's a genuinely good signal — the platform decided the game was worth showing to its browse audience.

### What the rates mean

- **~72% page-to-play conversion is excellent**, and it *held under 4× the volume.* The cold, broad browse audience of week 2 only knocked ~5 points off the week-1 number. The store page — title ("I hardly know'er"), screenshots, pitch — is doing its job. **Getting people to start is a solved problem.**
- **CTR fell from 3.05% to 1.38% — and that's fine, arguably good.** Impressions exploded 10× (28.9k → 353k) because tag/browse placement shows your thumbnail to a much wider, much less self-selected crowd. A lower click rate on an order of magnitude more eyeballs is the expected trade and is net hugely positive. Don't read the CTR drop as a regression; it's the cost of free reach.
- **The funnel bottleneck is consistent and now well-sampled.** Roughly 5× the players of week 1 ran into the *exact same walls.* The second wave didn't change the diagnosis — it raised the confidence and the sample size behind it. When two independent traffic sources, ~5× apart in volume, produce the same complaints, those complaints are structural, not noise.

### The quiet metrics

- **61 downloads / 6,321 browser plays** → people overwhelmingly play in-browser, as expected for the genre. Good to know for where to invest (web build quality matters most).
- **71 collections, 19 ratings** → people are bookmarking and rating it despite the friction. That's retention intent leaking through a broken funnel. If the onboarding wall came down, those numbers suggest there's a real audience underneath.
- **No "this game is bad" comments anywhere.** Every negative note is the constructive kind: "I like it / it looks cool, BUT this part was awkward." That's the best possible failure mode for a prototype.

---

## 3. What went right

Worth stating plainly before the list of problems, because the problems are all fixable and the strengths are the part you can't fake:

- **The pitch converts.** ~72% under cold traffic.
- **The platform endorsed it.** itch surfaced it organically.
- **Production values landed.** Repeatedly and specifically praised: "the animations, UI and sound design are all amazing" (Kesash). "Looks soo rad" (SuspeceousPateto).
- **The loop is fun once found.** "The loop is engaging" (Kesash). "Definitely has potential once you figure it out, the loop is fun" (keetony). "Fun idle game with different concept" (rahares). "Interesting game" (ZombiePanda13).
- **The design is *legible enough to reverse-engineer.*** Multiple players (kasumitendo in week 1, Finvalli in week 2) correctly figured out the entire intended progression on their own. That's a double-edged result — the loop is coherent, but the fact that understanding it requires detective work is itself the headline problem.

The throughline: **everyone who got past the comprehension wall liked the game.** The job now is to get more people past that wall.

---

## 4. The issues players identified

These are sorted by severity/frequency, merging both waves.

### Issue #1 — Onboarding is opaque, and PP is invisible *(the dominant, game-gating problem)*

This started as one theme in week 1 and split into two distinct, equally-blocking problems by week 2. Nearly every other complaint is downstream of these.

**4a. The game never teaches its own vocabulary or its first move.** Players don't know what PP, BB, Shove, EV, or "0%" mean, what to do first, or that losing everything at the start is *intentional*:

- "No idea what PP, BB, Shove, or 0% mean." (eatmyscoobysnacks)
- "Lost all money in 5 seconds, couldn't figure out what to do." (koshail, PerfectFriendship146)
- "Okay, I just saw the 'instructions' thing — that should have been explained in game." (WolfOfRavens)
- "Needs a lot more explanation in the final product." (keetony)

The instructions exist — on the itch page — and **players do not read external text.** Having those instructions next to you while *you* playtest is exactly what hid the severity of this from us: the dev experiences the game with a tutorial that the player never sees.

**4b. PP — the entire progression currency — is invisible.** This became the single loudest complaint in week 2. Players cannot find the on-ramp from "playing" to "prestige":

- "I honestly have no clue how I am earning PP. After a dozen shoves I still do not know how PP is earned." (ZombiePanda13)
- "On my 20th run at least and haven't got a single point. I just keep busting." (kalux)
- "Doesn't seem possible to get the first prestige point." (pickledoge)
- Even Finvalli, who *solved* it: "It took me a while to figure out the whole process of getting PP."

Traced through the code, the players are not being dumb — **PP is gated behind three sequential rules, none of which the UI surfaces:**

1. **PP comes from a *jackpot* win, not a normal win.** You can win hands all day and earn zero PP. (`GrindController` only awards on `tier == "jackpot"`.)
2. **It's the *first* jackpot per bracket, once per run.** There are 24 "bracket bounties" — 6 stakes × 4 game types — each worth 1–6 PP, ~84 PP for a perfect run. Once a bracket is cleared, repeat jackpots there pay nothing. So even a player who *does* hit jackpots watches PP stop accruing and concludes *that's* broken too.
3. **It only banks when you Shove.** PP earned mid-run is provisional; Shove is what commits it. A player who never connects "Shove = cash in this run's PP" can earn it and never realize where it went.

And underneath all of that: at most stakes the **natural jackpot rate is ~2% (0% at the high tiers)** until the Pot Control upgrade reshapes the odds. So "go win a jackpot" is itself improbable until you've spent PP you don't know how to earn — a chicken-and-egg the player has no visibility into.

This is why "I played 20 runs and got zero PP" is a *correct* observation of the current build, not a skill issue.

### Issue #2 — The early game is unwinnable until you find a hidden free unlock

A large cluster of "I just lose, every time" feedback — and in week 2 a player cracked the cause open *in the comments:*

- "Fail. Fail. Fail… No chance to game." (SeninWorld)
- "I just keep losing." (boazz)
- "If this was actually random, shove should win 50% of the time. I played 20+ hands and lost 100%… your odds of winning are far too low in the regular game." (WolfOfRavens)
- **The fix, given by one player to others:** "Skill issue. Open the catalog and buy the free skill. It makes you win more than lose." (onciblu)

onciblu's "free skill" is the **Poker Poster** — a $0/0-PP catalog item. The game boots with a hidden handicap (`no_poster_handicap`: a 0.4× win-chance multiplier plus a loss-distribution skew) that makes **run 0 intentionally near-unwinnable (~20% win chance).** Buying the free Poster silently removes that handicap and restores normal poker math.

So WolfOfRavens' "your odds are far too low" is a *literally accurate reading of an un-removed tutorial debuff.* And the rescue mechanism right now is **word-of-mouth in the comment section** instead of the game telling you. That's the system working by accident.

### Issue #3 — The post-Shove rebound feels like a rug-pull

> "I prestiged, got a poster, tried again. Bought a table, lost twice, am broke." (FrontBadgerBiz)
> "Bought sharper reads once, promptly lost anyway, and it was gone once I reset." (boazz)

There are two bankruptcies in the early game and they feel identical to the player but mean different things:

- The **intro bankruptcy is narrative** — a scripted tutorial beat designed to teach Shove.
- The **post-Shove rebound bankruptcy is just variance** at the floor stake — and it reads as the game being unfair rather than as a designed moment.

boazz's version layers on a second grievance: spending your scarce early resource on Sharper Reads, losing anyway, and watching it *vanish on reset.* He's conflating run-upgrades (reset by design) with persistent PP catalog items, but the *feeling* is legitimate — it reads as a rug-pull because nothing teaches which upgrades are permanent.

Lakkendoes independently asked for the exact fix we'd already sketched:

> "A quick reset to $2 button would be nice, as the shove at 0% takes a bit of time." (Lakkendoes)

### Issue #4 — The progression curve feels backwards

> "Instead of saving ages for a 2x upgrade, get the 10% upgrades first for cheaper. The extra table unlocks in the prestige or something? They are the most valuable upgrades but also the very first one you have access to, which makes any prestige unlocks feel lackluster." (Kesash)

The first available upgrade (+1 table) is an instant 2× income jump. Everything after it — +50%, +33%, then small speed/win-rate bumps — feels small by comparison. Kesash's instinct: lead with cheap %-upgrades, gate the big table-slot jumps behind prestige so prestige feels rewarding.

### Issue #5 — Catalog and upgrade descriptions are opaque

> "'Read your opponents better' doesn't really tell me anything." (Kesash)
> "The upgrade explanations could be more detailed. There should be tooltips when I drag on upgrades on the right. I didn't know what 'focus' did for 15 minutes." (IllFatedStudios)

Players are spending hard-earned PP blind. They want concrete numbers (+X% win rate per level) and hover/drag tooltips — and notably IllFatedStudios is asking for tooltips on the **right-hand run-upgrade rail**, not just the catalog.

### Issue #6 — Zoom wins "don't count" toward PP

> "...especially from zoom games, as they seem not to count for some reason for a very long time even after winning multiple hands in a row." (rahares)

This looked like a possible bug in week 1. It isn't. It's a *symptom of Issue #1b:* PP requires a *jackpot*, not a win, and Zoom's small pots keep the jackpot rate low until Pot Control reshapes the distribution. rahares was winning hands and reasonably expected PP. No code bug to chase — it's a legibility failure wearing a bug costume.

---

## 5. The bugs

### Bug A — MTT high-multiplier jackpot loops instead of paying off *(confirmed, live)*

Finvalli is the first player to reach the content ceiling, and the climax broke:

> "Try to get a 20x MTT just for the feeling of accomplishment… only to feel disappointment that the 10x and 20x MTT doesn't work, it resets after 8 wins (yes, I watched it — it ticked over to the 8th win, paid out and reset back to hand one)."

**Root cause confirmed in code, not speculation.** The shipped prototype has the `MTT_KO` flag *off* (it follows `PROTOTYPE_MODE = true`), so MTT runs the **legacy binary stub** (`MttSession_legacy.lua`): auto-play 8 hands, pay `mtt_payouts[8]` = 20× the buy-in, then reset the hand counter and **loop forever.** There is no terminal "you won the tournament" state. The top of the ladder is an infinite 8-hand loop that re-pays and resets — which reads exactly like a jackpot that fires and then *un-fires.*

The kicker: **the real fix already exists in the codebase.** A full chip-flow 8-max knockout MTT (`Table.lua` / `MttSession.lua` / `HandScript.lua`, payout keyed by tournament finish position) was built in commit 1617f0d and is sitting behind the `MTT_KO` flag, turned off for the prototype. Finvalli hit the stub; the good version was one flag away.

### Bug B — Escape-menu crash

> "Couldn't restart, when trying so via escape menu the game crashes." (PerfectFriendship146)

Unverified, single report, needs reproduction. A crash on the restart path is high-severity because "restart" is exactly what a confused new player reaches for.

---

## 6. The endgame: it works, and then it's over

Finvalli is the only commenter who reached the end, and the report is a gift — it's a complete map of the solved game:

> "Farm Zoom for money → buy 3–4 Sharper Reads + Pot Control → branch into Heads-Up/6-Max → turn my brain off and click a four-square of Heads-Up tables (fastest, biggest bang for buck) → save PP for the cursor upgrade → let the game play itself on the other monitor for 3 hours. Do this over 3 days and unlock everything. MTT is trash except for the unlock PP after shoving."

Three things to read here:

- **There is one dominant strategy and everything else is dominated.** Zoom→Heads-Up four-square→Cursor is *the* line. 6-Max is a footnote and MTT is "trash except the one-time unlock" — which corroborates the week-1 read (IAmSoDamnGood) that MTT is a thin stub.
- **The Cursor auto-clicker trivializes interaction.** It's gated behind a 10-PP unlock, then bought with bankroll; once you have it, the game plays itself. That's *fine* for an idle game's late state in principle, but here it arrives before there's enough content depth behind it.
- **The whole game is consumed in ~3 days of mostly-AFK play, ending in disappointment** because the one climactic reward (the 20× MTT) is the broken stub from Bug A.

This is a real depth/retention problem — but it's a *next-tier* problem. There's no point deepening the endgame while 90% of players can't get past the first two minutes. Log it, fix it after the onboarding wall is down.

---

## 7. Solutions — direction, prioritized

The fixes cluster into a clear priority stack. **The top two are co-headline because they're the same disease (the game doesn't teach its own loop) and a player can't progress without both.** Full direction-level write-ups live in `prototype-feedback-may-2026.md` (Problems 1–4); summarized here.

### Priority 1 — Make PP legible *(Problem 3)*

Direction, not implementation:

- **Expose the 24 bracket-bounties as a visible objective** — a stakes × game-types matrix showing which brackets are claimed this run and the PP each is worth. One surface that answers "how do I earn PP," "why did Zoom stop paying," and "where do I go next."
- **Teach jackpot ≠ win, loudly, the first time it happens** — "Bracket cleared! +N PP, banked on next Shove." Right now it's silent.
- **Show provisional vs banked PP distinctly,** with an explicit "Shove to bank" affordance, so the Shove↔PP link is unmissable.
- **Make Pot Control's description say what it does** — "raises your jackpot rate" — so the chicken-and-egg becomes a stated goal instead of a hidden wall.

### Priority 2 — Onboarding modal *(Problem 2)*

A one-page, forced-acknowledge modal before play starts. Not the production answer (that's scripted in-game beats), but cheap, removable, and infinitely better than the current ~0% read rate. Content, in order:

1. **The punchline first:** "You're going to lose your starting money — that's intentional. It teaches you Shove. After your first Shove, buy the **free** Poker Poster from the catalog to start playing for real." This one paragraph converts every "lost in 5 seconds, broken" comment into "ah, the tutorial." **Name the Poster as free** — that's the rescue players are currently giving each other in the comments (onciblu).
2. **One annotated screenshot** with arrows at bankroll, EV, deal, shove.
3. **A one-line glossary:** PP, BB, EV, jackpot.
4. **Tone-setting:** "Prototype, expect rough edges, here's what to focus on." Preempts "this is buggy" feedback.

UX rules: one page, no Next button; one action-labeled button ("Got it, deal me in"); replayable from a persistent help button.

### Priority 3 — Captor bailout *(Problem 1)*

A no-cost, instant **reset-to-starting-bankroll button** that does *not* trigger Shove + catalog. Flavored as the captor spotting you a fresh stake. Appears *only* when the player is bricked (no tables open AND bankroll below the cheapest buy-in) — the trigger condition is the entire rate-limit. Crucially, it **doesn't exist before the first Shove**, so the first bankruptcy still teaches Shove as the heavy, ceremonial prestige beat; the captor unlocks afterward as the lightweight everyday safety net. The contrast *is* the lesson. Lakkendoes asked for this almost verbatim — ship it as specced.

### Priority 4 — MTT endgame *(Problem 4)*

- **Preferred: turn `MTT_KO` on** for the next build and let MTT graduate from stub to the real finish-position KO mode that's already built. This also kills the "MTT is trash" read. Cost is the validation/balance time on the KO path that got it flagged off in the first place.
- **Fallback** if KO isn't ship-ready: give the legacy MTT an actual terminal "tournament won" payout that *stops*, instead of silently looping to hand 1. Cheaper, removes the rug-pull, leaves MTT shallow.

Either way, the current loop-and-reset-with-no-climax is the worst option and must not survive the next pass.

### Bundled smaller wins

- **Jargon expansion on first appearance:** first "PP" reads "Poker Points (PP)," then "PP." Same for BB/EV.
- **Numbers on catalog items + tooltips on the run-upgrade rail** (Kesash + IllFatedStudios).
- **Fix the esc-menu crash** (reproduce PerfectFriendship146's report).

### Explicitly deferred (right concern, wrong time)

- **Restructuring the progression curve** (Kesash's table-vs-% ordering) — a bigger design conversation than the immediate fix needs.
- **A production scripted tutorial** — build it after the modal proves the loop holds with context; no point building it twice.
- **Endgame depth / the 3-day exhaustion / the too-early Cursor** — all post-onboarding problems. No value in deepening the endgame until players can reliably reach it.

---

## 8. Lessons learned (the meta layer)

A few things this prototype taught us about *how we build and test*, beyond the specific bugs:

1. **External instructions are not instructions.** The single biggest distortion was playtesting with the manual in hand. Every future test should assume the player reads nothing. The modal exists precisely to internalize what we'd been outsourcing to the itch page.
2. **A mechanic that needs reverse-engineering is a mechanic that isn't taught.** Two separate players correctly deduced the whole loop — which proves the design is coherent *and* proves it's hidden. "Smart players can figure it out" is not a passing grade.
3. **'Intentional difficulty' and 'broken' are indistinguishable without signposting.** The run-0 handicap and the narrative intro-bankruptcy are *designed* — but they read as bugs because nothing frames them. Designed pain needs a label or it just reads as pain.
4. **Feature-flagging the good version off can ship the broken version as the headline experience.** The MTT KO system was done and turned off; the player who reached the endgame got the stub. When you flag off your best work for a prototype, the stub becomes part of the review.
5. **The second wave is the real test.** Launch-day numbers are friends-and-algorithm noise. The itch organic push delivered a colder, 5× audience that hit the identical walls — that's what promotes a complaint from "anecdote" to "structural."

---

## 9. Bottom line

The prototype passed its core test — twice. A second, 4×-larger, colder traffic wave hit the *same* walls as the first, which means the friction is structural and reproducible, not launch-day noise; and conversion held at ~72% throughout, so the concept keeps pulling players in and itch's own algorithm vouched for it.

What the second wave changed is the priority stack. Onboarding is no longer one problem but two co-headline ones: **the intro reading as broken** (the modal) **and PP being a currency players literally cannot find the on-ramp to** (the bounty surface). Those two are the gate — nearly every complaint in both waves is a symptom of one or the other. Behind them sit captor-bailout (now player-requested verbatim) and the MTT endgame fix (root cause confirmed, the good version already built and one flag away). Further out, the endgame is shallow enough to exhaust in three days — but that's a problem for *after* players can reach it.

Get comprehension right and, for the first time, the rest of the funnel actually gets sampled. Everything good about this game is currently hidden behind two minutes of confusion. The whole next pass is about removing those two minutes.
