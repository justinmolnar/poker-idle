# Game type identity redesign

Design brief from the Aug 26 brainstorm. Nothing here is built. This is the
agreed direction and the chunk order; numbers are illustrative, the sim picks
the real ones.

## The problem

HU dominates every axis at once. All four game types pay out on the same
scalar ($/hand), so one of them is always strictly best on it, and it's HU:

- HU's dist_shifts push both dists toward large/jackpot, so its avg pot is
  ~35bb vs 6-max's ~13bb. Every +1% win chance is worth ~0.6bb/hand at HU vs
  ~0.2bb at 6-max. WC upgrades are 3x more valuable at HU.
- HU also runs pace 1.0 vs 6-max's 0.5. Another 1.7x on top, multiplicative.

Naked HU is nearly breakeven (~+0.1bb/hand vs 6-max's ~+3.7). The moment any
WC items are owned, HU pulls ahead and never looks back. Zoom can't compete
because its small-pot skew makes WC leverage work against it. Tuning
pace/dists just changes which mode wins the same race. The fix is making the
modes the best source of *different things*.

## The seats rule (pot bands per game type)

`data/pot_tiers.lua` is currently global: a jackpot is 80-120bb at every
table regardless of mode. The new rule is diegetic:

**Max pot = seats x stacks.** Win-side bands scale with opponent count.

- HU: one opponent, one stack to win. 80-120 stays. Honest.
- 6-max / zoom: five opponents. Family-pot ceiling ~500-600bb. Tiers scale
  up accordingly.
- Loss side does NOT scale. You can only ever lose your own stack (~100-120bb
  cap everywhere). 6-max gets a fat upside tail with today's downside. True
  to real poker: the multiway cooler is a win-side event.
- MTT is exempt: chip_stack_table has real chip flow, tournament chips aren't
  dollars, its economy is data/mtt_payouts.lua.

Consequence: "jackpot" stops meaning "biggest pot" and starts meaning "the
chip event". Stacks/chips key off *hitting* the jackpot tier, not its dollar
size. HU stays jackpot-frequent (best chip engine) but its jackpot is only
one stack, so those hits don't dominate money. 6-max competes on money
through scaled medium/large tiers that never print chips. No new gtype-keyed
rules needed.

## The party comp

- **6-max: the tank.** Dramatically slower (pace below today's 0.5). Big
  bands. Playing for the rare 600bb cooler; drips between them. Low APM,
  the table you leave running. Buffs are worth the most here because its
  bands are biggest, so supports naturally want to target it.
- **HU: burst DPS.** Fast, frequent stack-sized pots both ways, best
  Stack/chip rate in the game. Low ceiling (one opponent). Money fine but
  not the runaway. Must not win every axis at once like it does today;
  doesn't need to be punished either.
- **Zoom: sustained DPS.** Pace up (~2x, more cinematic-skips) so it
  viscerally zooms. Overwhelmingly small pots with the same big band
  ceiling as 6-max at rounding-error weight: constant drip, once-a-session
  absurd spike. Hands are hands and we want hands: it feeds every per-hand
  trigger and total_hands unlock.
- **MTT (8-max KO): the support.** Zero APM (auto_deal). Its procs land on
  OTHER tables, so it's permanently exempt from the "which mode pays best"
  race by construction. See below.
- Cursors: the pet class. The APM budget is the party size: a mixed loadout
  (e.g. 3 slow 6-max + 3 zoom) is physically playable where 6 fast tables
  are not, and per-trigger items make the table mix a build.

## The engine: cascades

Item class: **on jackpot** (any table, mode-agnostic; no gtype key), every
zoom table resolves its current hand instantly, paying out in full with
whatever it was going to roll.

- Resolve, don't award: forced resolutions roll normally. It's a time
  compressor, not a money printer. Its EV cost is exactly "zoom's EV,
  faster".
- Forced resolves count as hands for total_hands_at_gtype and per-N-hands
  triggers. That's the point.
- Infinite cascades are allowed and WANTED. No recursion rule: the throttle
  is physical. A forced resolve only fires tables with a live hand; right
  after a cascade every zoom table sits empty, so a chained jackpot whiffs
  unless cursors re-deal fast enough. Cascade depth is gated by the cursor
  economy, an upgrade path we already sell. Early game: one sweep. Endgame:
  rolling thunder.
- Generosity principle throughout: everything pays, nothing is voided. The
  player should feel smart and rewarded, never "no fuck you these don't pay
  out". Tuning handles balance.

## MTT: the support class

The KO tourney's output is buffs cast on other tables, not income. KOs
arrive on a schedule (the planner pre-rolls busts), so they're the reliable
trigger channel next to jackpot's RNG spikes. Turbo KOs land every ~15-30s;
a 30s buff per KO holds near-constant uptime, two tourneys overlap into full
uptime. Buff uptime is a build stat tuned with felt space.

Item archetypes:

- On KO: 30s raised win% somewhere (the aura)
- On KO: bump another table's next pot a tier (the enchant; pairs with
  6-max's giant bands)
- On KO: 30% chance to reclaim a table's buy-in (the healer)
- On tournament win: +1% win chance this run (the ratchet; rate-limited by
  tourney length + buy-in, no cap needed)
- Escalation pass (drama): KO value scales with seats remaining, final HU
  worth the most.

## Heaters and tilts

The status layer, named in poker's own words. Heater = timed positive
status; tilt = timed negative status ("not cashing at a tourney tilts the
adjacent tables to play worse for 5s").

- One named status each way, one visual treatment each (shader registry),
  every source reads the same instantly.
- Diegetic tilt sources: tourney miss; losing a jackpot-tier cooler (the
  most tilting thing in poker; a real cost for the tank slot).
- Counter-item family: the mental game (tilt resistance/cleanse gear).
- Conversion builds (corrupted): items that feed on tilt ("tilted tables
  play 50% faster", "when tilt ends: 10s heater"). Rage builds.
- Stacking rule (refresh vs stack) is a decision to make once, at build
  time.

## Proc-first catalog philosophy

Stats are the boring baseline; conversions are the content. "+6% win chance"
is a number getting bigger; "on jackpot: cursors +300% for 10s" is the same
average power delivered as a moment. The design space is a matrix: triggers
(jackpot, KO, tournament win, every Nth hand, cooler, Stack banked, cascade
depth) x effects (cursor speed, pace, tier bump, resolve-now, heater,
buy-in reclaim, chip mult) x durations.

- Demo/early items stay flat and legible; mid/late items go proc-shaped.
  The catalog phases already support this arc.
- The item ghost system is the delivery mechanism: every proc pops its
  sprite over the table it touched.

## Formations (spatial layer)

Procs and statuses gain range; the table grid becomes a board. Adjacency IS
the targeting rule: aim a buff by where you seat things. Negative auras plug
into corruption as a spatial drawback you play around with placement
(quarantine the cursed tourney, leave an empty slot as a spacer). Density
becomes a stat: radius effects reward smaller/more tables packed in range.

Requires slot-based seating: tables live in fixed slots, positions persist,
closing one leaves a hole, drag-to-rearrange, aura radius rings on hover.
Biggest single piece of engineering in the plan. Bonus: a slot pool
structurally kills the index-shift bug class (a table's slot is its
identity; nothing reflows on close).

## Chunk order

Decided: the formation SCAFFOLDING goes first, inert, so nothing gets
balanced twice. The rebalance to fear is tuning statuses as global auras and
re-scoping them to ranges later; scaffolding-first means heaters/tilts ship
ranged from day one and get balanced exactly once. Chunk 1's numbers don't
care about geometry at all. Each chunk leaves a complete game.

0. **Formation scaffolding (inert).** Slot pool, drag-to-rearrange, save
   migration (positions backfill from list order; do it while the itch
   audience is smallest), empty-slot rendering, add-table picks a slot. No
   auras, no ranges. Player-visible as pure QoL: "you can rearrange your
   tables now". Design decisions inside: grid dimensions, does slot count
   scale with progression, the buy-a-table flow when you pick a seat.
1. **Identities (data + sim).** Per-gtype bands (seats rule; one seam where
   Table.lua reads PotTiers[tier]), pace split, dist/WC re-tunes so HU
   stops sweeping every axis. Sim FIRST: extend the pacing sim to print
   $/hr, chip rate, and variance per gtype side by side, including MTT EV
   from mtt_finish_dist x payouts. Fully revertible.
2. **First engine item.** Generic on-jackpot trigger plumbing + the zoom
   cascade item, authored global (geometry-proof). Deliberately small:
   proves proc items are fun before building the vocabulary.
3. **Heaters/tilts + MTT support, ranged from birth.** Status framework,
   visuals, KO/tourney proc items.
4. **Catalog proc cadence (ongoing).** Work the matrix a few items at a
   time; convert flat items that deserve it; tilt-feeders in the corrupted
   pool; unlock thresholds tuned toward mode-mixing.

Expectation: never literally one rebalance. Chunk 2 raises zoom's effective
hands/hour, chunk 3's heaters raise effective WC; each chunk nudges what it
touches. The sequencing eliminates the only redo-class rebalance.

Open: where the demo release falls. Chunk 1 is arguably demo-improving (the
demo currently teaches "HU is the only answer"); chunks 3-4 smell like
post-demo content.
