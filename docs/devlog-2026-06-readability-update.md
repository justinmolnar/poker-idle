# Update: Readability and Feedback Pass

THANK YOU to everyone who played, commented, rated, or even just looked at my game. The response to this first prototype blew me away. 6,000+ of you have played it, leaving me tons of ratings, collections, and comments. For a rough prototype I put out asking for feedback, that's more than I hoped for, and nearly every comment pointed at the same handful of rough edges.

Here are some of the changes I've made to address feedback in this new version:

### "I lost in 5 seconds and had no idea what to do"
The most common note by far. So:
- This has been addressed with clearer tooltips, some (prototype) icons to make stuff easier to read, and a "How to play" page that opens on new game, as well as by the ? button in the top right.

### "What even is PP? How do I earn it?"
- PP is now the **Gold Chip**. A currency with its own icon shown everywhere (top bar, catalog, prestige, payouts) instead of an unknown acronym.
- How you get these, where you get them, what they do and all that should hopefully be MUCH clearer now in-game with the better tooltips and how to play screen.

### "The upgrades don't tell me what they do" / "didn't know what Focus did for 15 minutes"
- Catalog descriptions rewritten in plain language, with icons and numbers where applicable to show exactly what will happen when purchased. I also moved the +x SHOVE % part to its own dedicated space.
- The right-hand upgrade rail now has hover tooltips. Every upgrade gets a plain "what it does" line, and Sharper Reads / Pot Control show a per-stake "next level" graph of what your next purchase moves.

### "A quick reset to $2 button would be nice"
- Added. When you're genuinely bricked (no tables, can't afford a buy-in), a **Quick Reset** appears over the Shove button which banks your Chips and resets you to $2.
- I'm still working on figuring out how to avoid bricking players in the first place so it isn't needed, I have a few ideas but for now that should ease the annoyance of the early game variance a bit.

### "The esc menu crashes" / couldn't restart
- ESC now opens just the Settings menu. No more stacked confirm dialog firing on top of it. "Delete save" is now **Start new game** with a clear confirmation, and Quit is disabled on the web build (the likely crash culprit).

### MTT: "the 20× tournament resets after 8 wins and never pays off"
- Tournament wins now land with a proper **TOURNAMENT WON** moment with more fanfare, instead of paying out silently and rolling straight back to hand one.
- The payout ladder is bigger and shows gradual progress pips as you climb, and hovering it explains the whole thing: your per-hand win rate, the 6/7/8 win ladder (3x / 6x / 20x), the Chip you bank on a full sweep, and the net EV.
- Per-hand win celebrations ramp up in size as you climb the ladder.

### Reading the table
- Formatting vastly improved across the tables.
- Showdowns are easier to read. The cards that didn't make the winning hand dim out, the winning five grow and pop, and the winning hand is displayed in text. So you can tell who won and with what at a glance.

### Win and loss tiers are now visual
- The win/loss tiers now show as chip-stack icons instead of words, everywhere they appear.

### More of the math is on screen
- Highest win tier % sits right next to the bb/h readout on the felt.
- Table buttons show bb/h and full EV breakdown on hover, the same detail a live table gives you.
- A gold pulse fires over the add-table button the moment you bank a Chip, and a gold "banked" trim marks every stake/type you've already cashed a Chip from this run.

### Feel and polish
- The Focus % and the tables X / Y counter now roll smoothly and pop when they change, and Focus is color-coded green/amber/red so the penalty state is more obvious.
- The auto-clicker cursors got some polish: click ripples and a brief pause on each click so you can actually see it land.

### Balance and bug fixes
- No more dead upgrade levels. Sharper Reads, Pot Control, and Focus could be leveled past the point where they did anything in the prototype's stake range. You can no longer pour money into levels that do nothing.
- Fixed a tournament payout that could break or silently pay out almost nothing.
- Fixed an exploit where reloading re-paid an already-finished tournament.
- Fixed a case where reloading right after a tournament could instantly "win" your next hand.

Again, I can't thank you enough for playing and all the feedback I've gotten. Hopefully this makes the early (and entire) game a bit less frustrating and confusing so more people can get into it.

---

## HTML (paste into the itch devlog editor)

```html
<h2>Update: Readability and Feedback Pass</h2>
<p><strong>tl;dr:</strong> Clearer onboarding and instructions. Many UI, readability, and transparency changes including tooltips, visible math, etc so players can tell what's happening and what to do easier. Quick reset button and bugfixes/polish.</p>
<p>THANK YOU to everyone who played, commented, rated, or even just looked at my game. The response to this first prototype blew me away. 6,000+ of you have played it, leaving me tons of ratings, collections, and comments. For a rough prototype I put out asking for feedback, that's more than I hoped for, and nearly every comment pointed at the same handful of rough edges.</p>
<p>Here are some of the changes I've made to address feedback in this new version:</p>

<h3>"I lost in 5 seconds and had no idea what to do"</h3>
<p>The most common note by far. So:</p>
<ul><li>This has been addressed with clearer tooltips, some (prototype) icons to make stuff easier to read, and a "How to play" page that opens on new game, as well as by the ? button in the top right.</li></ul>

<h3>"What even is PP? How do I earn it?"</h3>
<ul><li>PP is now the <strong>Gold Chip</strong>. A currency with its own icon shown everywhere (top bar, catalog, prestige, payouts) instead of an unknown acronym.</li><li>How you get these, where you get them, what they do and all that should hopefully be MUCH clearer now in-game with the better tooltips and how to play screen.</li></ul>

<h3>"The upgrades don't tell me what they do" / "didn't know what Focus did for 15 minutes"</h3>
<ul><li>Catalog descriptions rewritten in plain language, with icons and numbers where applicable to show exactly what will happen when purchased. I also moved the +x SHOVE % part to its own dedicated space.</li><li>The right-hand upgrade rail now has hover tooltips. Every upgrade gets a plain "what it does" line, and Sharper Reads / Pot Control show a per-stake "next level" graph of what your next purchase moves.</li></ul>

<h3>"A quick reset to $2 button would be nice"</h3>
<ul><li>Added. When you're genuinely bricked (no tables, can't afford a buy-in), a <strong>Quick Reset</strong> appears over the Shove button which banks your Chips and resets you to $2.</li><li>I'm still working on figuring out how to avoid bricking players in the first place so it isn't needed, I have a few ideas but for now that should ease the annoyance of the early game variance a bit.</li></ul>

<h3>"The esc menu crashes" / couldn't restart</h3>
<ul><li>ESC now opens just the Settings menu. No more stacked confirm dialog firing on top of it. "Delete save" is now <strong>Start new game</strong> with a clear confirmation, and Quit is disabled on the web build (the likely crash culprit).</li></ul>

<h3>MTT: "the 20× tournament resets after 8 wins and never pays off"</h3>
<ul><li>Tournament wins now land with a proper <strong>TOURNAMENT WON</strong> moment with more fanfare, instead of paying out silently and rolling straight back to hand one.</li><li>The payout ladder is bigger and shows gradual progress pips as you climb, and hovering it explains the whole thing: your per-hand win rate, the 6/7/8 win ladder (3x / 6x / 20x), the Chip you bank on a full sweep, and the net EV.</li><li>Per-hand win celebrations ramp up in size as you climb the ladder.</li></ul>

<h3>Reading the table</h3>
<ul><li>Formatting vastly improved across the tables.</li><li>Showdowns are easier to read. The cards that didn't make the winning hand dim out, the winning five grow and pop, and the winning hand is displayed in text. So you can tell who won and with what at a glance.</li></ul>

<h3>Win and loss tiers are now visual</h3>
<ul><li>The win/loss tiers now show as chip-stack icons instead of words, everywhere they appear.</li></ul>

<h3>More of the math is on screen</h3>
<ul><li>Highest win tier % sits right next to the bb/h readout on the felt.</li><li>Table buttons show bb/h and full EV breakdown on hover, the same detail a live table gives you.</li><li>A gold pulse fires over the add-table button the moment you bank a Chip, and a gold "banked" trim marks every stake/type you've already cashed a Chip from this run.</li></ul>

<h3>Feel and polish</h3>
<ul><li>The Focus % and the tables X / Y counter now roll smoothly and pop when they change, and Focus is color-coded green/amber/red so the penalty state is more obvious.</li><li>The auto-clicker cursors got some polish: click ripples and a brief pause on each click so you can actually see it land.</li></ul>

<h3>Balance and bug fixes</h3>
<ul><li>No more dead upgrade levels. Sharper Reads, Pot Control, and Focus could be leveled past the point where they did anything in the prototype's stake range. You can no longer pour money into levels that do nothing.</li><li>Fixed a tournament payout that could break or silently pay out almost nothing.</li><li>Fixed an exploit where reloading re-paid an already-finished tournament.</li><li>Fixed a case where reloading right after a tournament could instantly "win" your next hand.</li></ul>

<p>Again, I can't thank you enough for playing and all the feedback I've gotten. Hopefully this makes the early (and entire) game a bit less frustrating and confusing so more people can get into it.</p>
```
