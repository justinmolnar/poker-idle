# Poker Idle — MVP Plan

Good question to be asking now — before you've built anything is exactly when MVP scoping is most useful.

For this project specifically, you have an unusual advantage: the core loop is mechanically simple but tonally distinctive. That means the MVP needs to prove the **feel** more than the mechanics. A standard idle game MVP would be "show numbers go up." Yours needs to be "show that being in the room while numbers go up feels like the thing we want it to feel like."

## What the MVP Needs to Prove

In rough order of importance:

1. **The grind feels good.** Numbers ticking up at poker tables, bankroll growing, stake climbing. If this isn't satisfying, nothing else matters. This is the most validated mechanic in the entire idle genre, but you still need to confirm yours has the right curve and pacing.
2. **The catalog-as-room loop feels good.** Earning PP, spending it, watching the room change, feeling stronger next run. This is the part that makes your game yours. If the room filling up doesn't land emotionally, the whole captivity-grind frame fails.
3. **The shove is dramatic.** When the player attempts the gauntlet, does it feel like an event? Or does it feel like clicking a button? This is genuinely hard to nail and worth testing early.
4. **The cheating dealer reveal lands.** The first time the player wins runout 1 and watches a 6th card slide in, do they go "wait, what?" or do they feel cheated by the game design rather than the diegetic dealer? This is the riskiest narrative beat in the whole game.
5. **The captivity tone holds across multiple sessions.** Does sitting in this room for 30 minutes feel evocative, or just boring? This one you can't fully prove in an MVP — needs longer-form playtesting — but you can get an early read.

### Things you don't need to prove in MVP, even though they're in the design

- Multi-tabling depth
- Stakes progression curves at the high end
- Run-upgrade vs catalog balance
- Final shove cap tuning
- Total game length

These are tuning problems, not validation problems. You'll iterate on them once the core works.

## What the Smallest Thing That Proves These Is

A single contained vertical slice that takes a player from "open game" to "win or lose your first gauntlet attempt" in 20–30 minutes of play. Not 5–7 hours compressed; 20–30 minutes that's representative of every system the full game would have, just with way fewer items, fewer stakes, and tuned to fail the gauntlet at the end (because the gauntlet should not be winnable in 20–30 minutes).

### What's in the MVP

- **One room.** Empty at start. Visible "shelf" or "floor space" where catalog items will appear. Pixel art / simple 2D. Doesn't need to be polished, but the visual style needs to be locked in — this is one of the things you're testing.
- **One poker table.** No multi-tabling. Just one NLHE table running auto-play, hands resolving via stats vs. RNG. Numbers ticking up.
- **Three stakes tiers.** NL2, NL10, NL50 or similar. Enough to show the progression feels good without building the whole curve.
- **Five-to-eight catalog items.** Mundane objects with arbitrary effects. Teddy bear, plant, lamp, mug, mousepad, second monitor. Each adds to the room visually and provides a stat bonus. Mix of effect types (earnings, speed, shove rate).
- **One bankroll-spend run upgrade.** Just one — to prove the two-track concept works. "Energy drink: +20% earnings this run, $X cost."
- **The shove button, always available.** Player can attempt the gauntlet at any time. Win rate is visible at the top of the screen. Most early attempts will be at 5–15%.
- **The full gauntlet sequence.** All three runouts, with the cheat reveal on runout 2. This is the most important piece to nail because it's the riskiest. You want playtesters' faces when they see the second card.
- **Prestige loop.** Lose the gauntlet, see PP awarded, spend it on a catalog item, watch the room change, start over.
- **A capped "win condition"** — maybe at 30% per-shove rate, the gauntlet becomes mathematically winnable (~3% clear rate at that level, but possible). Most playtesters won't reach this in their MVP session, which is fine. The point is the loop feels good, not that they finish.

### What's deliberately not in the MVP

- Multi-tabling
- Multiple poker variants
- Tilt mechanics
- Rep/burn mechanic (this can be approximated with simpler diminishing returns)
- Tournaments / SNGs / mixed games
- The mundane-job opening (cut for MVP, just start with poker)
- Audio polish (placeholder is fine)
- More than 5–8 catalog items
- Settings, save systems, polish features

## Estimated MVP build time

For a solo dev who knows their tools: **3–6 weeks** of focused work, probably closer to 6 if you're learning anything new along the way. Most of the time isn't programming — it's:

- Tuning the grind curve so 20 minutes of play feels meaningful
- Iterating on the gauntlet staging until the cheat reveal lands
- Pixel art for the room and 5–8 items
- Getting the shove screen UI different enough from the grind UI to feel like a genre shift

The gauntlet specifically deserves disproportionate attention — probably 30% of MVP dev time on what's mechanically a 30-second sequence. It's the moment that defines the game's character.

## How to Test It

Once you have the MVP, the test is:

- Hand it to **5–10 people for 20–30 minutes each.** Don't tell them about the cheating dealer. Watch their face when it happens.
- Watch what they do **after the first gauntlet loss.** Do they immediately want to grind back and try again, or do they put it down? The pull-back is the most important signal — it tells you whether the prestige loop is working.
- Ask them what they think the game is about. If they say "poker idle game," you've failed at conveying the tone. If they say something like "trying to escape" or "the room hates me" or even just "weird" — you've got it.

You'll know the MVP is successful when at least half your testers ask "wait, when's this coming out?" without prompting.

## One Pre-MVP Step Worth Considering

Before the full MVP, even — make a **prototype of just the shove sequence.** Not the grind, not the catalog, not the room. Just a screen where you can punch in a per-shove win rate, click "shove," and watch the gauntlet play out cinematically with the cheat reveal.

This is maybe **3–5 days of work** and it tests the single highest-risk mechanical/narrative beat in the game in isolation. If the gauntlet doesn't feel right at this stage, every MVP decision after it is built on sand. If it does feel right, you have a centerpiece that all other systems can be designed to support.

I'd genuinely consider this a separate step before MVP: prototype the shove, get the cheat reveal landing, then build the grind and catalog around it.

## What Comes After MVP

Once the vertical slice validates, the order to build the rest in:

1. **Expand the catalog to 30–50 items.** Most underrated thing in the genre — variety is what carries playtime.
2. **Add multi-tabling.** Probably the highest-impact mechanical addition for player engagement.
3. **Tune the full stake curve.** This is mostly a math/spreadsheet exercise once the loop works.
4. **The mundane-job opening.** Last because it's narrative flavor that depends on the rest of the game's tone being established.
5. **Audio.** Late, but critical when you do it. The shove music in particular needs serious thought.
6. **Polish, settings, save system, accessibility.** Pre-launch work.
