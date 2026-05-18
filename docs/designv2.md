# Poker Idle — Design Doc v2

*Updated after design pass on game types, MTT, catalog framing, shove rate refactor, demo structure, and tonal alignment.*

Working title: **I Hardly Know'er** (poker pun, performs the captor's cheerful institutional voice)

## Elevator Pitch

A short-form incremental game (~5–7 hours) about grinding online poker from a single room toward one terminal goal: win an all-in. But the all-in isn't fair — when you finally try it, the dealer cheats. They keep dealing extra cards until they win. The only way out is to grind so hard, accumulating so many small edges from your room and bankroll, that even a rigged poker game can't beat you. Build an undeniable edge. Walk out.

You start with a 0% chance of winning. Every dollar earned, every stake climbed, every item bought from the catalog exists to push that percentage up. When you can't viably grind further, you shove. You almost certainly lose. You spend your Poker Points, buy more upgrades, grind back up. Eventually, you win.

Tonally: not horror, not power fantasy. Captivity-grind. The slow, quietly compelling experience of a person who didn't choose this getting really good at it because there's nothing else to do.

## Reference Points

- **Scritchy Scratchy** — Closest commercial comp. Validates pricing (~$7), scope (5–13 hours), audience, and the "manual-only terminal action" mechanic. Same shelf, different content. Differentiation comes from the gauntlet endgame, the captivity-grind tone, and the room-as-physical-space catalog rather than from the high-level mechanical loop, which converges on idle-genre conventions.
- **Cookie Clicker** — Structural template for tonal counter-programming. Cheerful title and chrome that the game's content slowly betrays. The institutional voice never breaks character; the player figures out the dread from accumulated context. *I Hardly Know'er* does the same trick.
- **Unfair Flips** — Direct mechanical parallel for the core loop: 0% terminal RNG event, push it up via upgrades, eventually win.
- **Nasubi (Denpa Shōnen)** — Atmospheric and structural inspiration. The captivity, the grind, the slow accumulation of stuff, the protagonist becoming someone through the work. The catalog directly mirrors the prize structure: items are real rewards AND tools of compliance, both at once.
- **Buckshot Roulette** — Adjacent for the all-or-nothing terminal moment. Tonal touchstone for how heavy a single shove can feel.

## Title

**I Hardly Know'er** — performs the captor's institutional cheerfulness as cover. The title doesn't reference captivity, doesn't reference the gauntlet, doesn't telegraph the dread. The cheerful framing is the trap; the title participates in the trap. Tagline ("a poker idle game") in store-page chrome handles searchability without diluting the title's voice.

## Core Loop

1. Grind poker at multiple tables, building bankroll over time.
2. Climb stakes as your bankroll grows; add tables for parallelism; mix game types (cash + tournaments) for variance preference.
3. Shove rate climbs visibly during the grind — bankroll multiplies your catalog-derived shove rate. Every dollar earned makes the eventual all-in stronger.
4. When you can't viably grind further (or when shove rate looks good enough), shove. Watch your bankroll pour into the pot. Almost certainly lose somewhere in the gauntlet.
5. On loss: prestige. Bankroll resets. PP earned through bounties banks to permanent total. Spend PP on catalog items that go in the room and provide stat bonuses. Grind again, faster and stronger.
6. On clearing the gauntlet: credits roll. You leave the room. Game over.

That's the whole game.

## The All-In as Endgame

The single biggest design idea anchoring everything else.

- All-in win rate starts at 0%. Cannot be won early, by design.
- Shove rate is a **product**, not a sum (see *Shove Rate System* below). Both catalog progression and current-run bankroll must be developed; neither alone is sufficient.
- The all-in is always manual. The player chooses the moment.
- The shove plays out cinematically: chips pour from bankroll into the pot, the rate locks, then cards deal slowly with flop/turn/river revealed one at a time. The grind UI is dense and numerical; the shove UI is sparse and dramatic.
- **No hard cap on shove rate.** A player who grinds to extreme bankroll/catalog levels earns extreme rates — that's the payoff for grinding, not a balance failure.

### The gauntlet (cheating dealer)

The terminal challenge is not a single hand. To win, the player must clear three sequential runouts within a single all-in:

- **Runout 1:** Standard NLHE all-in. Hole cards, flop, turn, river. Five community cards on the felt. Shove rate determines result.
- **Runout 2 (if runout 1 wins):** The dealer adds a sixth community card. The hand reruns with the new card included.
- **Runout 3 (if runout 2 wins):** The dealer adds a seventh community card. The hand reruns again.

Lose any runout and you bust — full prestige reset, back to the grind. Each runout is gated by the same shove rate, so clear chance is rate³.

By runout 3, **seven** community cards on the felt — the standard five plus two cheat cards. The escalating visual is the cards.

The gauntlet is itself a runner-runner — two improbable consecutive wins after the standard runout. The whole game is tournaments all the way down.

#### Why this works

- Math forces real tension. 70% per-shove clears the gauntlet ~34% of the time; 90% clears it ~73%. The compounding does enormous work.
- Makes the 0% start diegetic. The cheat explains why you can't win early. The room doesn't want to let you go.
- Math and fiction do the same work. Re-rolls are mechanically what they are; narratively the room is cheating. Player sees both simultaneously.
- Transforms the grind. The protagonist isn't getting better at poker through skill — they're accumulating so much undeniable edge that probability bends. Every catalog item is one more piece of evidence on the player's side of the felt.
- The win moment is structurally perfect. Clearing the gauntlet means the cheat *fails*. The dealer keeps dealing extra cards. The player keeps winning anyway.

#### The cheat reveal

The cheat is silently revealed, not pre-explained. The first time the player wins runout 1 — which doesn't happen until they've built meaningful shove rate — the dealer slides a sixth card onto the felt and the hand resolves against them. *That* is the demo's climax (see *Demo Structure*).

The cheat reveal is also **the captor's institutional voice cracking**. Throughout the game the captor's voice is unbroken cheerful loyalty-program register. The card-6 slide is the only moment the mask slips — the captor panicking, improvising. After the loss the voice resumes. The crack closes. That recovery is more unsettling than the crack itself.

#### Presentation notes

- Lightest-touch staging. No dealer character on screen. No sleeves, no hands, no faces. The cheat happens in the cards alone.
- The escalating visual is the cards. By runout 3, seven community cards on the felt. The accumulation is the climax.
- Lose any stage = full prestige reset.

### Single shove, single ending

No multi-tier structure. No rug-pulls. No new rooms. Same room, same catalog, same poker client — the terminal hand just happens to be three runouts.

## Shove Rate System

The load-bearing mechanic that makes the grind meaningful.

```
base_rate     = catalog_shove_rate          (permanent, slow accumulation)
bankroll_mult = stake_tier_for_bankroll     (1x to 7x+ based on current bankroll)

total_rate = base_rate × bankroll_mult
total_rate = math.min(total_rate, 1.0)
```

That's it. Two sources, one multiplication. PP is **not** a shove rate input — PP is the meta currency you spend on catalog items between runs, nothing else.

### Why multiplicative

Additive lets each system stand alone — a player optimizes one axis and ignores the other. Multiplicative **forces both systems to be developed**. 5% catalog × 1x bankroll = 5% (useless). 0% catalog × 6x bankroll = 0% (useless). You need both.

This also fixes the "useless catalog items" problem naturally. A 1.5% catalog upgrade × 6x endgame bankroll = 9% shove rate from one item. Small base values become meaningful via the multiplier.

### Two systems, two distinct jobs

- **Catalog** = permanent base. Slow accumulation across prestiges.
- **Bankroll** = run multiplier. Fast accumulation each run.

Two distinct rhythms, no overlap. Each source has a clear role.

### Bankroll multiplier — stake-tier-keyed

Multiplier determined by which stake's buy-in your **current** bankroll could afford (not peak). Diegetically: the dealer doesn't care that your all-in *could have been* $4M. Your contribution is what you actually pour. If you bled your peak before shoving, that's on you.

| Bankroll covers | Multiplier |
|---|---|
| < T1 ($2) | 1x |
| ≥ T1 | 1x |
| ≥ T2 ($25) | 2x |
| ≥ T3 ($100) | 3x |
| ≥ T4 ($1k) | 4x |
| ≥ T5 ($10k) | 5x |
| ≥ T6 ($100k) | 6x |
| ≥ post-T6 ($1M+) | 7x+ |

Climbing stakes is now important not just for bigger pots but for bigger shove multipliers. Breakpoints become real grinding goals.

### The shove pour (visualization)

The shove is a *ritual*, not a button click. When the player presses SHOVE:

1. Current bankroll visibly pours into the pot via chip-flight animation
2. Shove rate locks at its calculated value
3. Brief beat of silence
4. Gauntlet begins

The pour is visualization of commitment — bankroll *is* the all-in pot, that's what shoving means literally. Locks at the start of the pour; doesn't recalculate as chips fly. The bankroll readout drains to $0 over 2-3 seconds. Player watches an hour of grinding empty into one moment.

### Thematic alignment

The captor wants money. You're rewarded for bringing in more money with a higher chance at "freedom." The whole economy reframes:

- Grinding isn't preparing to shove — it's **accumulating tribute**
- The catalog isn't metaprogression rewards — it's **the captor's investment in keeping you producing**
- PP isn't currency — it's **proof of how much you've already given them**
- The all-in isn't the gauntlet — it's **the moment you offer up everything you have**

The cheat reveal in this frame: you brought tribute, you offered it, and the captor *still* cheats to keep you in the system. Even paying everything isn't enough. The trap.

## Game Types

Four distinct modes, each with a one-sentence identity. The differentiation is on screen — cinematic shape, panel chrome, opponent presence — not just stat shifts.

### 6-max — patient baseline
Standard cash, baseline rhythm. Five seated opponents around a felt. Full deal-flop-turn-river-showdown cinematic at 4.4 seconds per hand. The reference point all other modes are read against. **Identity:** the steady starter, predictable income, watchable hands.

### HU (heads-up) — the duel
One opponent across the felt, rendered with visual presence (oversized seat, real name, central placement). Faster pace at 2.2s/hand. Showdown phase is **doubly long** versus other modes — this is the only moment in the game where two specific hands matter against each other. Dist shifts: smaller wins, deeper losses. **Identity:** high variance, fast clicks, the duel — when you win it's small, when you lose it's deep.

### Zoom — the firehose
Anonymous opponents that visibly cycle between hands (placeholder labels — "Seat 3", "Player ##" — that flash on reroll). Most hands resolve via a **compressed cinematic on Tiny outcomes**: deal phase only, skip community-card reveals, jump to settle. ~0.8s per Tiny hand vs. full 1.57s for non-Tiny. Dist shifts hard toward tiny on both win and loss; jackpots nearly extinct. **Identity:** volume play, small pots, no big wins, you don't track anyone.

### MTT (multi-table tournament) — risk burst
Pay buy-in once, watch a 30-second sequence of 8 consecutive hands. Single-axis survival check per hand using the table's win_chance. Win → advance. Lose → bust. Cash at hands 6, 7, 8.

Payouts (multiples of buy-in): **3x / 6x / 20x** at hands 6 / 7 / 8 respectively. Boosted by catalog perks (Plastic Trophy → 4/8/20, Engraved Plaque → 5/10/20).

Cinematic: 30-second total, ~3.75s per hand, with hand counter visible ("Hand 4 of 8") and payout ladder showing current position. No per-hand player input — you committed when you entered.

**Identity:** trap-flavored at low grind (wastes buy-ins), competitive mid-grind, dominant late-game. The endgame mode players graduate into.

The cubed-clear math (rate^8 to fully clear) and the gauntlet's rate^3 are structurally identical — both are "win N improbable rolls in a row." MTTs are the gauntlet in miniature. The whole game is tournaments all the way down.

## Prestige

Standard idle pattern, single axis:

- Bankroll resets to a small starting amount each run.
- Poker Points are the meta currency, persisting across prestiges.
- PP is earned during runs through stake bounties (first jackpot at each (stake, game_type) combo banks pp_award, scaled by catalog perks).
- PP earned this run is *banked* via the SHOVE button — mechanically, you commit to shoving in order to actually receive your earned PP. This makes the shove transactional in a literal sense: you're trading the run for the PP.
- Spent on catalog items that go in the room and persist forever.

## Two Upgrade Tracks

### Run upgrades (bought with bankroll)

- Spent during a run, lost on prestige.
- No room item — pure stat boosts in the run-tracker UI.
- Fill outcome-model dimensions (Sharper Reads → win_chance, Pot Control → win_dist + loss_dist, Focus → table capacity, Box of Mice/Cursor Speed → cursor swarm).
- Compete with stake-climbing for bankroll. Save up for next stake, or buy upgrades to grind current stake faster?

### Catalog (bought with Poker Points)

- Permanent. Items appear in the room. Persist across prestiges forever.
- Every item is an *object* with a name and visual identity. Mundane stuff: trash can, sticky mat, plastic trophy, headphones, calculator, stress ball.
- Mechanical effects are arbitrary — the trash can is a trash can, it just also gives you +X% something. The juxtaposition is the texture.
- Items that read as "poker abilities" (HU Specialist, Pot Odds Master, Damage Control, Cheap Coaching, Endorsement Deal) need renaming pass to fit the catalog-of-objects framing. Examples: HU Specialist → Mirror, Pot Odds Master → Whiteboard, Damage Control → Stress Ball, Cheap Coaching → Self-Help Book, Endorsement Deal → Branded Hat.

### The catalog is a flyer

Not a sidebar list. Hand-designed pages, grouped semi-thematically (awards & achievements, office supplies, snacks, reading material, audio gear). The visual register is **supermarket flyer / SkyMall catalog** — cheerful institutional photography, exclamation-mark copy, the kind of thing an institution gives out to keep customers happy.

This is *the captor's loyalty program*. PP is what you've earned them through your participation. The catalog is what they're willing to give you in exchange for points. The relationship is transactional. The cheerful presentation is part of the trap.

The catalog UI itself is post-VR work — months of polish away. For VR, current sidebar list is fine.

## Demo Structure

The demo is a marketing artifact built late, not an early prototype. ~60-90 minutes long, structured as a complete first chapter:

1. **Opening softlock + forced first shove.** Player starts at $2 bankroll, immediately can't afford much, busts within minutes. SHOVE is the only remaining action. Click → 0% gauntlet → instant loss. Pity 1 PP awarded for the forced shove (to teach the prestige loop).
2. **Catalog discovery.** Player spends pity PP on cheapest catalog item (Coaster, +$1 starting bankroll). Loop visible: PP → catalog → next run starts stronger.
3. **The grind cycle.** Multiple prestiges. Catalog grows. Bankroll multiplier becomes meaningful as stakes climb. Shove rate visible in top bar at all times, climbing as the player grinds.
4. **First successful runout 1.** After enough grinding (likely 60+ minutes in), the player has built enough rate to actually win the first runout. They feel the shift — they're getting close.
5. **Cheat reveal.** Card 6 slides in. They lose. The institutional voice cracks for a moment.
6. **Demo end.** "Thanks for your dedication! Session saved." The voice resumes pretending nothing happened. The next round will begin shortly. Demo just... stops continuing.

Save state carries from demo to full game purchase. Players don't replay 90 minutes after buying.

The demo's cliffhanger is the *captor pretending nothing happened* after the cheat. The crack closed. You're still in the room. The system continues.

## VR (Vertical Slice / Prototype)

Distinct from the demo. ~20-minute Itch upload for friends and feedback testing. Tests "is the loop fun" and "do the four game types feel distinct." Doesn't need narrative arc, doesn't need the cheat reveal, doesn't need full polish.

Already in place: multi-table grind, four differentiated game types, MTT, catalog, run upgrades, gauntlet cinematic, prestige loop.

Pending for VR ship:
- Shove rate refactor (multiplicative system, see above)
- Forced first-shove tutorial via softlock + pity PP
- Catalog rename pass (poker-ability names → object names) and qualitative-effect redesign

Itch feedback questions worth asking:
- "What other games does this remind you of?" (open-ended, captures unprompted Scritchy Scratchy comparisons)
- "Without playing further, what do you think the full game would be like?"
- "Have you played Scritchy Scratchy? If yes, what feels different here?"

## Aesthetic and Tone

The design test for any decision: does this serve the captivity-grind tone, or does it pull toward generic idle / generic horror?

### Lean into

- Mundanity. Routines. The protagonist becoming weirdly competent.
- Quiet, persistent strangeness. The arbitrary nonsense of a teddy bear granting poker bonuses.
- The protagonist as a person who's adapted, not a victim or a hero.
- Visual contrast: ordinary room, ordinary poker client.
- The all-in as a ritual. Different UI mode. Different music. Different pacing.
- **Institutional cheerful voice everywhere.** Catalog descriptions, prestige modal, achievement notifications, audio cues. The captor's loyalty-program register never breaks character. Players figure out the dread from accumulated context, not from the game telling them.

### Avoid

- No captors visible. No menacing dialogue, no threatening notes, no first-person captor character. The setup is "you're here." The flatness is the texture.
- No edgy satanic imagery. Possibly skip the satanic angle entirely.
- No explanation of the frame. Never confirm whether it's literal Satan, a coma, an experiment. Ambiguity is the texture.
- No power fantasy escalation. The protagonist is a worker, not a tycoon.
- No purely cosmetic items. Everything earns its place mechanically.
- **Don't let the game's voice notice what's happening.** The institutional voice never acknowledges the captivity. Like Cookie Clicker's tooltips never saying "this is sinister." The player notices; the game pretends not to.

### Tonal counter-programming

The game is built on Cookie Clicker's structural principle: cheerful framing the content slowly betrays. Title performs cheerful denial. Catalog performs institutional generosity. Audio performs casino-friendly comfort. The horror is environmental and accumulative — never narrated, always inferred.

The cheat reveal is the only moment the voice cracks, and it immediately resumes afterward. That recovery is the actual horror.

## Scope

- **VR (slice):** few days, primarily tuning and the shove rate refactor. Itch upload.
- **Demo (marketing artifact):** several months out. Music, graphics, story polish, full first chapter, ends at cheat reveal.
- **Full game:** 6-12 months solo. Demo + the rest of the catalog content, more upgrade depth, the path through the cheat to eventual win.

Target length: 5–7 hours main playthrough; ~10–13 hours for completionists.
Target price: ~$6.99.
Target platforms: PC (Steam) primary; mobile port plausible later.

### Why this scope is correct

- Captivity-grind tone has a structural ceiling — past a certain point the room becomes literal tedium rather than evocative duration.
- A reachable ending is a competitive advantage in the idle genre.
- Matches successful comps (Scritchy Scratchy, Unfair Flips, Buckshot Roulette).

### Explicitly out of scope

- Multiple poker variants in the core loop. Pick one (NLHE).
- Manual hand-by-hand poker decisions.
- Multi-tier prestige / multiple endings / "you thought you won" rug-pulls.
- Cosmetic-only items.
- Long-tail endless mode / NG+ as primary scope (small post-credits something fine if cheap).

## Mechanics Inventory

- Bankroll (current run currency)
- Poker Points (meta currency, persists across prestige, banked at shove)
- Run upgrades (bankroll-purchased, run-only, no room item)
- Catalog (PP shop; every item is a room object with permanent stat effects)
- Tables (running poker games in parallel — cash games in three modes, plus MTT)
- Stakes tiers (gate progression, multiply per-hand earnings, *and now multiply shove rate*)
- Game types (6-max, HU, Zoom, MTT — each visually distinct)
- Focus / capacity (multi-tabling penalty above N tables, raised by run upgrades)
- Cursor swarm (autonomous DEAL-clickers, gated by catalog unlock + run upgrades)
- Shove rate (multiplicative product of catalog × bankroll mult, no hard cap)
- The shove screen (chip-pour ritual, cinematic gauntlet, three runouts with cheat reveal)

## What This Game Is Not

- Not a poker simulator. Real poker skill is irrelevant; the game uses poker as material.
- Not a power fantasy. No yachts, no mansions, no tycoon escalation.
- Not a horror game. No jump scares, no menace. Unease is structural and ambient.
- Not a long idle game. Designed to be finished.
- Not Balatro. No deckbuilder elements, no roguelike runs.
- Not Scritchy Scratchy. Same shelf, different content.

## North Star

> Is this a person, in a room, becoming someone through the work?

If yes, the decision serves the game. If no, cut it.

---

## Appendix: Open Questions Resolved Since v1

- **Per-shove cap?** No hard cap. Natural ceiling from the multiplicative formula handles it.
- **Number of tables?** 32 hard cap (visual/sanity bound). Focus mechanic governs viability.
- **Stakes tiers?** Six (T1 $0.01/$0.02 through T6 $500/$1000), 10x jumps each.
- **Run-upgrade vs. catalog overlap?** Two distinct sources for shove rate: catalog (permanent base) and bankroll (run multiplier). PP is not a shove rate input.
- **How is the gauntlet revealed?** Silently, at the demo's climax. Player wins runout 1, dealer slides card 6, player loses. Demo ends.
- **Does each runout escalate?** Light touch. Cheat cards use the slow `cheat_card_dealt` animation curve and a longer pre-deal pause. Cards do the work.
- **How many catalog items?** Target ~30-50 for full game. VR ships with a redesigned set focused on qualitative effects rather than small percentage modifiers.
- **Items combo?** No mechanical combos. Independent items, each with its own effect.
- **Run-only items?** No. Catalog is permanent only.
- **Player sees what?** Cell only, with poker client as world-window. No outside reference.
- **Protagonist named/faced/heard?** No, no, no.
- **Title?** *I Hardly Know'er*. Tonal counter-programming.

## Appendix: Open Questions Still Open

- Final catalog item count and pricing curve for full game (post-VR design pass).
- Catalog flyer UI implementation (post-VR, demo-tier).
- Room view implementation — how the visual accumulation actually renders (demo-tier).
- Audio direction. Casino-comfortable cheerful, with cracks during the gauntlet.
- Art scope. Pixel art assumed but not committed.
- Specific tuning of the rebalanced game type bb/min curves once VR feedback comes in.
- Whether full game post-cheat-reveal arc requires *additional* upgrade categories (e.g., catalog items that counter the dealer's later cheats) or whether existing systems extended is enough.