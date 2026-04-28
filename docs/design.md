# Poker Idle — Design Doc (Working Draft)

Working title TBD. Living doc — open questions flagged throughout.

## Elevator Pitch

A short-form incremental game (~5–7 hours) about grinding online poker from a single room toward one terminal goal: win an all-in. But the all-in isn't fair — when you finally try it, the dealer cheats. They keep dealing extra cards until they win. The only way out is to grind so hard, accumulating so many small edges from your room and bankroll, that even a rigged poker game can't beat you. Build an undeniable edge. Walk out.

You start with a 0% chance of winning. Every dollar earned, every stake climbed, every item bought from the catalog exists to push that percentage up. When you can't viably grind further, you shove. You almost certainly lose. You spend your Poker Points, buy more upgrades, grind back up. Eventually, you win.

Tonally: not horror, not power fantasy. Captivity-grind. The slow, quietly compelling experience of a person who didn't choose this getting really good at it because there's nothing else to do.

## Reference Points

- **Scritchy Scratchy** — Closest commercial comp. Validates pricing (~$7), scope (5–13 hours), audience, and the "manual-only terminal action" mechanic. Their catalog system is a stake-tier gate, not a decoration system — relevant only as a possible model for table-tier progression.
- **Unfair Flips** — Direct mechanical parallel for the core loop: 0% terminal RNG event, push it up via upgrades, eventually win. Smaller-scale comp. The closest thing to "what this game is" mechanically.
- **Nasubi (Denpa Shōnen)** — Atmospheric and structural inspiration only. The captivity, the grind, the slow accumulation of stuff, the protagonist becoming someone through the work. Not a mechanical template — there's no multi-tier "you got moved" structure being copied. Just the feeling.
- **CloverPit** — Adjacent in framing only. Useful as a tonal touchstone for ambient unsettling-ness; nothing structural to take.
- **Buckshot Roulette** — Adjacent for the all-or-nothing terminal moment. Tonal touchstone for how heavy a single shove can feel.

## Core Loop

1. Grind poker at one or more tables, building bankroll over time.
2. Climb stakes as your bankroll grows; add tables for parallelism; unlock harder/better games.
3. Eventually the run becomes unviable — earnings flatten, the next stake tier is out of reach, or rep mechanics drag your win rate down. Time to shove.
4. Shove. All-in win rate is whatever your accumulated upgrades put it at — starts at 0%, climbs over many runs. You attempt the gauntlet (three runouts, dealer cheats by adding cards). Almost always you lose somewhere in the gauntlet.
5. On loss: prestige. Bankroll resets. PP awarded based on run performance. Spend PP on catalog items that go in the room and provide stat bonuses. Grind again, faster and stronger.
6. On clearing the gauntlet: credits roll. You leave the room. Game over.

That's the whole game.

## The All-In as Endgame

The single biggest design idea anchoring everything else.

- All-in win rate starts at 0%. Cannot be won early, by design.
- Every prestige earns Poker Points; PP is spent in the catalog on items that improve shove win rate, grind speed, earnings, rep handling, and other stats.
- Per-shove win rate caps below 100% — somewhere around 85–90%. Combined with the gauntlet structure (below), this gives an effective endgame win rate around 60–70%, even when fully built.
- The all-in is always manual. The player chooses the moment.
- The shove plays out cinematically: cards dealt slowly, flop/turn/river revealed one at a time. The grind UI is dense and numerical; the shove UI is sparse and dramatic.

### The gauntlet (cheating dealer)

The terminal challenge is not a single hand. To win, the player must clear three sequential runouts within a single all-in — but only the first runout looks like a normal poker hand. Mechanically:

- **Runout 1:** Standard NLHE all-in. Hole cards, flop, turn, river. Your shove rate determines the result.
- **Runout 2 (if you win runout 1):** The dealer adds an extra community card. The hand reruns with the new card included. You must win this runout too.
- **Runout 3 (if you win runout 2):** Another extra card. The hand reruns again. You must win this third runout to win the game.

Lose any runout and you bust — full prestige reset, back to the grind.

#### Why this works

- The math forces real tension at the end. A 70% per-shove win rate clears the gauntlet only ~34% of the time. An 80% per-shove rate clears it 51%. Even at the 90% cap, players win the gauntlet only 73% of the time. The compounding does enormous work — players genuinely have to grind to a high edge to feel safe attempting the gauntlet.
- It makes the 0% start diegetic. The cheat explains why you can't win early. The room doesn't want to let you go. Of course you lose at first. You haven't built enough edge to overcome the rigging.
- The math and the fiction are doing the same work. The dealer dealing additional cards is mechanically a re-roll on the runout, but narratively it's the room cheating. Player sees it both ways simultaneously.
- It transforms what the grind means. The protagonist isn't getting better at poker through skill — they're accumulating so much undeniable edge that probability itself bends. Every catalog item is another small piece of evidence stacked on the player's side of the felt. The teddy bear matters. The mousepad matters. The plant matters. Not because any one is decisive, but because together they're the only way through a rigged game.
- The win moment is structurally perfect. When the player finally clears the gauntlet, they don't just win a hand — the cheat fails. The dealer keeps dealing extra cards. The player keeps winning anyway. The credits roll on the rigging being defeated, not just on a poker hand being won.

#### Presentation notes

- The cheat should be silently revealed, not pre-explained. First time it happens, the player wins runout 1, the dealer slides another card onto the felt, and the hand resolves against them. Player goes "wait, what?" From then on, the gauntlet structure is known. The first cheat is a small narrative beat; subsequent attempts are just the rules of the room.
- Lightest-touch staging. No dealer character on screen. No sleeves, no hands, no faces. The cheat happens in the cards alone. The wrongness is contained in the fiction of the game itself, fitting the no-captors / no-explanation principle.
- The escalating visual is the cards. By runout 3, there are 8 community cards laid out on the felt. That accumulation is itself the climax — no additional flourishes needed.
- Lose any stage = full prestige reset. No partial-gauntlet progress carrying across runs. Lose any runout, you bust.

### Single shove, single ending

No multi-tier structure. No rug-pulls. No new rooms. The gauntlet happens in the same room with the same catalog at the same poker client — it's just that the terminal hand is three runouts instead of one. You attempt the gauntlet, you lose, you grind, you attempt again, you lose, you grind, you attempt again, you clear it, credits.

## Prestige

Standard idle pattern, single axis:

- Bankroll resets to a small starting amount each run.
- Poker Points are the meta currency, persisting across prestiges.
- PP is spent on catalog items (see below) — there's no separate skill tree, no second meta currency.
- Each prestige's PP gain scales with how far you got that run (peak bankroll, peak stakes, etc.) — incentivizes pushing the run before shoving but doesn't punish shoving early if a player wants to reset and try a new build.
- Rep / "burn" mechanic during a run: as you grind a single account, your rep rises and earnings curve flattens. Naturally pushes toward shoving rather than over-grinding. Justifies the reset narratively (account burned, new alias) without needing further explanation.

## Two Upgrade Tracks

The game has two parallel upgrade systems running off two different currencies. This is the core strategic decision the player makes throughout.

### Run upgrades (bought with bankroll)

- Spent during a single run, lost on prestige.
- Don't add items to the room. Pure stat boosts in the run-tracker UI.
- Similar kinds of effects to catalog items: +X% luck, bigger pot multipliers, +X% earnings, table speed, etc.
- Compete with stake-climbing for bankroll. Do you save up for the next stake tier, or do you buy upgrades that let you grind the current tier faster?
- Reset every prestige. They're how you push the current run further.

### Catalog (bought with Poker Points)

- Permanent. Items appear in the room. Persist across prestiges forever.
- Compound across runs. The longer you play, the more powerful your starting position becomes.
- This is where shove-rate bonuses live (most expensive, most important).

### Why both

- Classic idle two-track progression (push current run vs. compound across runs) without needing a second meta currency.
- Run upgrades create real in-run decisions (climb vs. boost) that bankroll-only spending wouldn't.
- Catalog progression carries the long-game emotional/visual weight; run upgrades carry the moment-to-moment optimization weight.

## Catalog Item Design

Detail on the catalog system introduced above.

The items are mundane and don't need to make in-universe sense. A teddy bear that increases your chance to beat aggressive opponents. A plant that gives +X% earnings on long sessions. A mousepad that adds a redo on lost hands. The juxtaposition of ordinary objects with arbitrary mechanical effects is the texture — it shouldn't feel labored or explained.

### Categories of effects (rough buckets, will iterate)

- **Direct shove bonuses** — +% all-in win rate (most expensive, most important)
- **Earnings multipliers** — +% bankroll per hand, +% per session
- **Speed** — +% hands per minute, +% table speed
- **Run length** — slower rep decay, tilt resistance, longer viable sessions
- **Specific situational bonuses** — bonuses vs. aggressive opponents, against specific table types, redo-lost-hand chances, bankroll insurance, etc.
- **Table/stake unlocks** — possibly — see Open Questions

Run upgrades (bought with bankroll) draw from similar effect categories, minus shove bonuses. Shove rate is only improved through catalog purchases — it's the meta-progression north star.

### Visual progression

The room visibly fills up. Empty room at start. By the time a player wins the all-in, the room is crowded with the accumulated junk of dozens of prestige cycles. That visual accumulation is the game's main visual storytelling — without ever stating it, the player can see how long they've been here.

## What Game You're Playing

No-Limit Hold'em. It's what people picture when they hear "online poker," which matters for instant readability. The shove-every-hand exploit doesn't apply here because the player never makes per-hand decisions — going all-in is gated as a deliberate prestige/win action, not a betting choice within a hand. NLHE is just the texture the auto-play sits inside.

Possible cosmetic swap to a 5-card variant (PLO, etc.) for readability/visual interest only — not for mechanical reasons. Decide based on what reads cleaner in the game UI.

Resolution: stat-based auto-play. The player makes strategic decisions (which tables, which stakes, when to shove); individual hands resolve via your stats vs. opponent stats + RNG weighted by edge. No hand-by-hand decisions in the core grind.

## Aesthetic and Tone Guidelines

The design test for any decision: does this serve the captivity-grind tone, or does it pull toward generic idle game / generic horror?

### Lean into

- Mundanity. Routines. The protagonist becoming weirdly competent.
- Quiet, persistent strangeness. The arbitrary nonsense of a teddy bear granting poker bonuses.
- The protagonist as a person who's adapted, not a victim or a hero.
- Visual contrast: ordinary room, ordinary poker client.
- The all-in as a ritual. Different UI mode. Different music. Different pacing.

### Avoid

- No captors. No menacing dialogue, no threatening notes. The setup is "you're here." The flatness is the texture.
- No edgy satanic imagery. Satanic-as-folklore (crossroads myths, Bergman) is a possible flavor; pentagrams and blood are not.
- No explanation of the frame. Never confirm whether it's literal Satan, a coma, an experiment, a metaphor. Ambiguity is the texture.
- No power fantasy escalation. The protagonist is a worker, not a tycoon. The wealth never leaves the room.
- No purely cosmetic items. Everything earns its place mechanically.

## Scope

- Target length: 5–7 hours main playthrough; ~10–13 hours for completionists.
- Target price: ~$6.99 (Scritchy Scratchy benchmark).
- Target platforms: PC (Steam) primary; mobile port plausible later.
- Estimated dev time (solo): 6–12 months depending on art scope.

### Why this scope is correct

- Captivity-grind tone has a structural ceiling — past a certain point the room becomes literal tedium rather than evocative duration.
- A reachable ending is a competitive advantage in the idle genre.
- Matches successful comps (Scritchy Scratchy, Unfair Flips, Buckshot Roulette).

### Explicitly out of scope

- Multiple poker variants in the core loop. Pick one.
- Manual hand-by-hand poker decisions.
- Multi-tier prestige / multiple endings / "you thought you won" rug-pulls.
- Cosmetic-only items.
- Long-tail endless mode / NG+ as primary scope (a small post-credits something is fine if it's cheap to add).

## Mechanics Inventory

Things the design likely needs:

- Bankroll (current run currency)
- Poker Points (meta currency, persists across prestige)
- Run upgrades (bankroll-purchased, run-only, no room item)
- Catalog (PP shop; every item is a room object with permanent stat effects)
- Tables (running poker games in parallel)
- Stakes tiers (gate progression, multiply per-hand earnings)
- Skill stats (driven by catalog items + run upgrades — no separate skill tree)
- Rep / burn meter (rises during a run, pushes toward shoving)
- All-in win rate % (north-star UI element, only improved via PP catalog)
- The shove screen (special UI mode for the terminal hand)
- Job/intro mechanic (very brief mundane opening — probably 2–5 minutes)

## Open Questions

### Core mechanical

- What's the per-shove cap? Probably 85–90%. Combined with the 3-runout gauntlet, this gives an effective endgame win rate of ~60–73%. Lower caps make the endgame more grindy/tense; higher caps make it more achievable. Tune in playtest.
- Number of tables you can run in parallel. Probably caps at ~6–10. Tune to playtime.
- Tilt as a separate mechanic, or just baked into RNG variance?
- Stakes tiers — how many, what's the spread? Possibly takes inspiration from Scritchy Scratchy's tiered table-unlock structure (low / mid / high), but as game variants or stake levels rather than rooms.
- Run-upgrade vs. catalog effect overlap. How much should they overlap? Some effects are catalog-only (shove rate). Some are run-only (anything that should reset). The middle ground — effects available in both — needs design attention so neither system feels redundant.
- Run-upgrade pricing curve. Should run upgrades scale steeply within a run so you can't max them all, forcing in-run prioritization? Probably yes.
- How is the gauntlet revealed? Silent first-time reveal (player loses runout 2 unexpectedly, learns the rules in real time) vs. pre-explained in tutorial. Lean: silent reveal preserves the captivity tone better, but it's a real choice.
- Does each runout have its own staging/escalation? Should runout 2 have a different visual or audio signature than runout 1? Should runout 3 escalate further? Or is the visual of accumulating community cards on the felt enough on its own? Lean: light touch, let the cards do the work.

### Catalog design

- How many catalog items total? This is the bulk of the game's content. Probably 30–60? Needs to feel like "always something to save up for" without bloating.
- Item rarity / pricing curve. How are top-tier items gated? Pure PP cost? Achievement unlocks? Both?
- Item interactions / synergies. Do items combo, or is each independent? Combos are more interesting but exponentially harder to balance.
- Are some items run-only vs. permanent? E.g. consumable single-run boosters vs. permanent room additions. Probably permanent only — keep it clean.

### Tone / framing

- What does the player see? Pure cell only? A window? The phone? Outside world implied through poker NPCs only? Lean: cell-only with the poker client as the world-window.
- Poker NPC depth. Names and chat tendencies are cheap and add a lot of texture. Backstory hints are a slope toward scope creep. Find a tight scope.
- How explicit is the satanic/death framing, if at all? Easy to either go too coy or too on-the-nose. Possibly skip the satanic angle entirely and just keep the frame ambient and unexplained.
- The protagonist. Named? Faced? Heard? Lean: no, no, no.

### Production

- Art scope. Pixel art? Hand-drawn? 3D? The room is the visual centerpiece and needs to support a lot of distinct items being layered into it. Strongly affects budget.
- Audio. Ambient room sound is critical. Shove music in particular does heavy lifting.
- Solo vs. team. Currently scoped solo. Tight but realistic.

## What This Game Is Not

- Not a poker simulator. Real poker skill is irrelevant; the game uses poker as material.
- Not a power fantasy. No yachts, no mansions, no tycoon escalation.
- Not a horror game. No jump scares, no menace. Unease is structural and ambient (if present at all).
- Not a long idle game. Designed to be finished.
- Not Balatro. No deckbuilder elements, no roguelike runs.
- Not Scritchy Scratchy. Adjacent, but with more atmospheric substance and a different mechanical core (poker grind, not card scratching).

## North Star

> Is this a person, in a room, becoming someone through the work?

If yes, the decision serves the game. If no, cut it.
