# Room & Catalog Brainstorm (2026-07-16)

Two things in one doc:
1. **The asset inventory** — everything in `assets/sprites/isometric/`, condensed,
   so nobody has to re-scan the tree again.
2. **The item list** — a large brainstorm of catalog items mapped to real sprites.
   Everything currently in data/catalog.lua is placeholder; this ignores it.

Costs, numbers, and exact wording are all deliberately absent — this is about
WHAT each item does and WHEN you feel it.

---

## Part 1 — Asset inventory

Scanned 1,095 PNGs → **218 distinct objects** in 27 top-level folders.
(Animation frames, color/state variants collapsed. Two housekeeping notes:
folder `Living Roon` is misspelled in the tree; a stray `Fridge.png` is
misfiled inside `Japanese_Room/Japanese_Closet_Drawers/`.)

| Folder | Objects | Contents |
|---|---|---|
| Bathroom | 23 | Bath (9fr anim), bath carpet/window, Duck, hanger, towels (3 colors, hanging), shelves, Mirror, shower set (bin/floor/tap/tray), soaps (3 colors), tissues, toilet paper, WC (anim), WC furniture + drawers, WC tap (anim) |
| Bedroom | 3 | Bed (7 styles A–G), night table (+2 drawer states), pillow |
| Books | 7 | Big/small books (9 colors), pile, titled books, notebooks, ring binders (6 colors) |
| Carpets | 1 | Carpet (5 designs) |
| Cat_Ani | 1 | Cat (15-frame + 5-frame animation sets) |
| Chairs | 4 | Basic office chair, chair 2 (4 tiles), Gaming Chair (4 angles), office main chair |
| Cleaning_Robot_Ani | 1 | Cleaning robot |
| Computer | 11 | Bended screen (18fr anim), MacBook (open/closed + 11fr), new/old iMac, keyboards (new/old), old PC, PC tower (9fr), rotation screen (3), vertical screen, Wacom tablet |
| Consoles | 20 | Atari, Dreamcast, Gameboy (+Advance), Gamecube, NES, N64, Switch, PS1–PS5, PSP, Genesis, SNES, Wii, Xbox/360/X |
| Desks | 3 | Desk 1 (2 tiles), office main table (+3 drawers), office normal table (+3 drawers) |
| Doors | 2 | Door (7 colors), office glass door (4fr anim) |
| Floor_Wall_Tiles_32/64/128 | 13 tile types | Floors + L/R walls in ~40 colorways each; bath floor/wall designs at 64/128 |
| Japanese_Room | 22 | Bonsai, candle, carton box, clothes case, tatami floor, tea set (cup/base/dish/tea), canvas (2), closet (+drawer set), sliding door (10fr ×2), lamp, plant, seat, shelf, table, tori gate, vase, wall set (L/R/top/window) |
| Kitchen | 44 | Dishwasher (11fr), fridge (+door sets, red variant), oven (+door), sink (3fr), toaster (5fr + toast), washing machine, stoves, kitchen furniture (7 colorways × 7 pieces), counter (+3 drawers), table/stool/shelf/rack/rug/tiles/window/painting, tableware (dish/fork/spoon/glasses/mugs/pot/pan/teapot/kettle/cutting board/knife), consumables (cereal/cola/soda/wine/sugar/bottle/box), cleaning (soaps/scourer/rag/basket/trash bin) |
| Lamp | 1 | Desk lamp (2 tiles) |
| LavaLamp_Ani | 1 | Lava lamp (24fr + off state) |
| Living Roon | 7 | Air conditioner, book, shelving ×2 (+drawer set), small table, Speaker, table |
| Microwave | 1 | Microwave (4 variants) |
| Office | 40 | Animated machines: Clock (12fr), copy machines dark/white (18/13fr), Document Shredder (9fr), Printer (11fr), Projector (4fr) + screen (7fr), Water Dispenser (8fr). Furniture: metallic closet (+3 drawers), wood closet (+2 doors), drawing table, kitchen table, partition, glass wall, racks, projector stand. Wall: boards (empty/full), corkboards, Blueprint, Diploma, picture frame, photos, TV-off. Desk props: Calculator, pencil holder, ruler, Telephone, Headset, papers (6), rolled papers, Sticky Notes (6 + 4 colors). Misc: AC, boxes, Fire Extinguisher, Medical Kit (open/closed), rumba robot, whiteboard eraser, trash bins |
| Plants | 3 | Cactus (2), plant (4 sizes), sunflower |
| Poster | 1 | Poster (10 designs incl. Fire, Map, Medical) |
| Present | 1 | Present (~11 designs/colors) |
| Sofa | 2 | Sofa (4 tiles), pillow |
| Televisions_TV | 2 | Big TV (2 anim sets + off state), TV+DVD (48fr) |
| Windows | 4 | Window 7/8/11 (variants), Japanese window |

---

## Part 2 — What "feelable" means here

Design stance: **the purchase is the only verb.** No item adds a new in-run
UI element — no charge buttons, no "flush" prompts, no toggles to babysit.
Every decision lives in the catalog (what you own = what rules you play
under); in play, items fire THEMSELVES, visibly. Every item must pass at
least one of:

1. **It has a moment** — it fires on its own and you see it: a loss gets
   eaten, toast pops, the clock chimes, the robot rolls out.
2. **It bends a rule you've personally hit** — once-per-run {chip}, focus
   cap, tied-up cash, busts, the all-or-nothing shove, upgrades resetting.
3. **It removes a chore** — visible automation you'd otherwise do by hand.
4. **It shows you hidden math** — info surfaces, no interaction needed.

Tags: `[event]` fires on a trigger · `[rule]` always-on rule bend ·
`[auto]` automation · `[info]` reveals math · `[ritual]` run-start/run-end/
calendar beat · `[collect]` set piece · `[cosmetic]` no mechanics ·
`[shove]` shove-relevant. Era: **A1** pre-first-clear · **A2** deck era ·
**A3** anti-chip era.

Most `[event]` items are "once per run" or "first X per run" — one boolean
in run state, no UI, and the once-ness is itself the drama.

---

## Part 3 — THE LIST

### The Battlestation (Desks, Computer, Chairs, Lamp, Books)

- **Second Monitor** · `Computer/Vertical_Screen` · [rule] A1 — +2 table cap
  (hard cap, not focus). A monitor physically appears on the desk; the grid
  visibly grows. Tier line: Old PC → iMac → **Ultrawide** (`Bended_Screen`).
- **The Rig** · `Computer/PcTower` · [info] A1 — every table shows live
  per-hand win % beside $/h; tooltips get the full breakdown.
- **Gaming Chair** · `Chairs/Gaming Chair` · [rule] A1 — focus overload
  penalty halved. Felt the moment you cross the cap and FOCUS reads 85%
  instead of 70%.
- **Desk Lamp** · `Lamp/Lamp_8` · [auto] A1 — the spotlight finds your best
  table on its own: your highest-$/h table is exempt from the focus
  penalty. The lamp visibly swivels when the leader changes.
- **Study Shelf** · `Books/*` · [event] A1 — after any {l:large}+ loss, that
  table's next hand is a guaranteed win ("reviewed the hand"). Revenge,
  automatic; the comeback hand glows.
- **The Calculator** · `Office/Calculator` · [info] A1 — adds "hands to
  break-even" and exact EV math to every tooltip. Cheap, and changes how
  spreadsheet-brains read the whole game.

### Office Machines (the powerhouse shelf)

- **Wall Clock** · `Office/Clock_Ani` · [event] A1 — every 60 real seconds
  the clock chimes and your next-dealt hand is a forced WIN (tier still
  rolls). No button: a metronome of free wins you learn to ride.
- **Copy Machine** · `Office/Copy_Machine_White` · [event][rule] A2 — the
  first DENIED {chip} each run isn't denied: the machine whirs and prints
  a copy — the bounty banks again. Hooks the existing denied-stack event;
  zero new UI, breaks THE rule once. Dark variant (A3): first two.
- **Document Shredder** · `Office/Document_Shredder_Ani` · [ritual][shove]
  A2 — at shove, your single worst loss of the run is retroactively
  shredded and refunded (paper strips in the prestige summary).
- **Medical Kit** · `Office/Medical_Kit` · [event] A1 — each table's first
  bust per run self-revives, free, instantly. Bandage slap, back in.
- **Water Dispenser** · `Office/Water_Dispenser_Ani` · [info] A2 — office
  gossip: hover any opponent to see their win chance and style. The hidden
  half of the table math, revealed.
- **The Printer** · `Office/Printer_Ani` · [auto] A1 — physically prints
  small bills: pays the big blind of your highest open table into bankroll
  every 10s, with animation and sound. Income you can watch.
- **Projector + Screen** · `Office/Projector_Ani` + screen · [auto] A2 —
  auto-projects your best table onto the room wall, big; the projected
  table earns a bonus. The room shows the session's protagonist.
- **Headset** · `Office/Headset` · [info] A2 — live reads: fold-outs and
  showdown losses telegraph a beat early. You see it coming.
- **Fire Extinguisher** · `Office/Fire_Extinguisher` · [event] A2 — break
  glass, automatically: the first time a run hits $0 bankroll with money
  still on tables, everything cashes out at once. The system pulls its own
  alarm. Core kit for A3's controlled bleeding.
- **Blueprint** · `Office/Blueprint` · [info][shove] **A3** — the House's
  schematics: the shove tooltip reveals R2 and R3. The player finally sees
  the rig, itemized.
- **Diploma** · `Office/Diploma` · [event] A1 — certified: your first hand
  at each stake every run is an auto-win. An arrival ceremony at every
  rung of the ladder.
- **Rumba** · `Office/Rumba_Robot` / `Cleaning_Robot_Ani` · [auto] A2 —
  any table bust for 60+ seconds is auto-cashed-out and reopened at your
  best $/h stake. The robot visibly patrols. Kills table-babysitting.
- **Tilt Bin** · `Office/Trash` (empty/full sprites) · [event] A1 — every
  {l:large}+ drops a crumpled page in the bin. When it's full (5), it
  empties itself and ignites a guaranteed heater on your coldest table.
  Losses visibly accumulating into fuel.

### Kitchen (processes & appetites)

- **The Fridge** · `Kitchen/Fridge` · [event] A1 — the cooler: the first
  {l:stack} each run is voided — sucked into the fridge with a frost
  effect. The worst beat of the run, eaten. Red fridge (A2): two.
- **The Toaster** · `Kitchen/Toaster_Ani` · [event] A1 — introduces
  **heaters**: 5 straight wins on a table = toast pops, table is ON A
  HEATER: wins +1 tier until a loss. The streak system's anchor.
- **The Microwave** · `Microwave/Microwave_5` · [event] A2 — reheat: the
  first heater that breaks each run automatically re-ignites.
- **Air Conditioning** · `Living Roon/AirCC` + `Office/AC` · [rule] A2 —
  climate control: one loss doesn't break a heater (grace).
- **Sugar** · `Kitchen/Sugar` · [rule] A2 — heaters ignite at 4 wins.
- **The Dishwasher** · `Kitchen/DishWasher` · [ritual][shove] A2 — clean
  slate: at shove, 10% of the run's total losses return as next run's
  starting bankroll. Quiet A3 cornerstone: the bleed partially recycles.
- **Washing Machine** · `Kitchen/Washing_Machine_Ani` · [event] A1 — spin
  cycle: a table that loses 5 in a row auto-rerolls all its opponents and
  wipes its history bars. Cold tables clean themselves.
- **The Sink** · `Kitchen/Sink_Ani` · [event] A1 — drain recovery: busted
  tables refund 25% of the buy-in as it audibly goes down the drain.
- **The Oven** · `Kitchen/Oven` · [rule] A2 — slow roast: an undealt table
  builds heat, +1 pot tier potential per 30s idle (max +2). Rewards
  rotation play; deliberate anti-synergy with cursors.
- **Morning Brew** · `Kitchen/Ketel_7` + `Mug` · [ritual] A1 — the first
  30 hands of every run play at +25% pace. The mug steams while it lasts.
- **Wine** · `Kitchen/Wine` · [ritual][shove] A2 — the toast: if the run
  lasted 200+ hands, shove banking pays +20% {chip}. The long game,
  rewarded at the moment of leaving it.
- **Breakfast** · `Kitchen/Cereals` · [ritual] A1 — the first run of each
  real day starts with a free heater on table 1. A reason for tomorrow.
- **Dogs Playing Poker** · `Kitchen/Painting` · [event] A1 — the classic:
  the first {chip} bounty each run pays +1. The painting winks. Everyone's
  first purchase.

### Bathroom (tilt management — everything fires itself)

- **The Bathtub** · `Bathroom/Bath_Ani` · [event] A1 — soak: once per run,
  when 3+ tables are on loss streaks simultaneously, the bath fills and
  every streak clears; no {l:large}+ anywhere for 10 hands. The session
  reset, triggered by exactly the moment you'd want it.
- **The Shower** · `Bathroom/Shower_*` set · [rule] A2 — fresh start: quick
  reset now KEEPS your run upgrades. The rescue becomes a strategy.
- **The Mirror** · `Bathroom/Mirror` · [rule][shove] A2 — run it twice:
  runout 1 of the shove deals two boards, best result stands. The single
  biggest shove purchase.
- **The Toilet** · `Bathroom/WC_Ani` · [event] A1 — auto-flush: after any
  {l:stack}, that table flushes itself — opponents rerolled, no {l:large}+
  there for 5 hands. The most honest poker mechanic ever shipped.
- **Bad Beat Tissues** · `Bathroom/Tissues` · [event] A1 — after any
  {l:stack}, all tables +25% pace for 20 hands. Grief-grinding, automatic.
- **Rubber Duck** · `Bathroom/Duck` · [event] A1 — the run's very first
  loss is a squeak: voided, no money moves. A tiny kindness every run.
- **Soap Collection** · `Bathroom/Soap` (3 colors) · [collect] A1 — each
  soap owned = +1 extra trigger per run on bathroom items (tub/toilet/duck
  fire one more time).
- **Towel Rack** · `Bathroom/Towel` (3) · [collect] A2 — each towel extends
  bathroom protections by +5 hands.

### Zen Corner (Japanese room — composure)

- **Zen Corner** · `Japanese_Room/Japanese_Seat` + `Bonsai` + `Candle` ·
  [rule] A2 — acclimation: hold steady over the focus cap (no table
  changes for 60s) and FOCUS % slowly regenerates up to half the penalty.
  You watch the number breathe back.
- **The Bonsai** · `Japanese_Room/Bonsai` · [ritual] A2 — grows one stage
  per shove survived; each stage adds a little to every run's starting
  bankroll. The only object in the room that remembers every run.
- **Tori Gate** · `Japanese_Room/Japanese_Tori_Gate` · [rule] A2 — deck
  shrine: active deck earns +50% XP. The deck era's centerpiece.
- **Candle Vigil** · `Japanese_Room/Candle` · [event] A2 — when a table
  hits a 3-loss streak the candle lights itself; the next hand there is a
  guaranteed win, and the candle snuffs. Once per streak.

### Living Room & Rec (idle and indulgence)

- **The Sofa** · `Sofa/Sofa_3` · [auto] A2 — couch mode: after 30s without
  a manual click, cursors work 50% faster. The true-idle player's buy.
- **The Big TV** · `Televisions_TV/BigTv_Ani` · [rule] A1 — always on:
  +2 focus capacity, all tables -10% $/h. You accept the tradeoff at
  purchase; the screen glows forever after. Owning it IS the toggle.
- **The Speaker** · `Living Roon/Speaker_6` · [rule] A2 — pump-up playlist:
  +15% pace everywhere, and the House's hint bubbles are muted — it can't
  talk over your music. Half buff, half lore joke.
- **TV + DVD** · `Televisions_TV/Tv_DVD_Ani` · [ritual] A2 — training
  tapes: after each shove, deck XP proportional to {chip} banked.
- **The Console Shelf** · `Consoles/*` (20 objects) · [collect][ritual]
  A1→A3 — warm-up round: each run's first N hands get +1 win tier, where
  N = consoles owned. Twenty consoles, one gloriously cluttered shelf.
  THE long-tail collection sink.
- **The Cat** · `Cat_Ani` · [event] A1 — wanders the room, naps near a
  table; that table's {w:stack} odds double while it sleeps. It moves when
  it pleases. You cannot control the cat. That's the item.
- **The Present** · `Present/*` · [ritual] A1 — comped: every run starts
  with a gift auto-unwrapping by the door — a random free run-upgrade
  level or a small bankroll bump. Run-start confetti.
- **Grow Op** · `Plants/*` · [ritual] A2 — each plant grows through visible
  stages as the run's hand count climbs; every fully-grown plant pays
  +N {chip} at shove. Long runs, made visible in the room. Stacks.
- **Regulars' Door** · `Doors/Office_Glass_Door_Ani` · [rule] A2 — the
  glass door turns anonymous opponents into persistent named RIVALS with
  tracked records. Beat one 10 times: they retire through the door
  animation, pay a {chip}, and someone tougher walks in.
- **Private Game** · `Doors/Door` (7 colors) · [event][rule] A3 — once per
  run a special entry appears in the EXISTING add-table list: the Private
  Game. Double buy-in, rival lineup, 2× {chip} bounty. No new UI — it's
  just a table card that shows up. Door color chooses its game type.

### Walls & Decor (feats, memory, identity)

- **The Corkboard** · `Office/Corkboard` · [ritual] A2 — pins three visible
  challenges per run ("bank 4 combos", "win a tournament", "never rebuy");
  each completed pin = +1 {chip} at shove. Evaluated automatically — the
  hint-rules condition registry already does this kind of predicate work.
- **Poster Wall** · `Poster/*` (10 designs) · [collect] A1→A3 — each poster
  commemorates a real feat (first clear, first NL10K table, first denied-
  then-copied bounty...) and grants one tiny themed perk. The wall fills
  as the save matures.
- **Family Photos** · `Office/Photos` + `Picture_Frame` · [ritual] A2 —
  frames display real stats from your best-ever run; every run starts with
  a bonus tied to that record. Your history, load-bearing.
- **The Whiteboard** · `Office/Board` (empty/full sprites) · [info] A2 —
  the session plan: a live checklist of which (stake, type) combos still
  owe their {chip} this run. The DIVERSIFY loop's missing UI, as wall art.
- **Cosmetics** · `Floor_Wall_Tiles_*`, `Carpets`, bed styles, door colors,
  kitchen colorways, mugs, towels, vases, canvases, tableware · [cosmetic]
  — no mechanics, sold for **$ (not {chip})**: the first real money sink,
  and why the room looks like YOURS by act 3. ~200 recolors already in the
  tree; free content.

### The House Shelf (shove & endgame, cross-referenced)

The shove/endgame arc, in rough order: Wine → Dishwasher → Shredder →
Mirror (run it twice) → **Insurance Policy** (`Office/Paper` +
`Rolled_Papers` · [rule][shove] A2 — a failed shove returns 10% of
committed bankroll to the next run) → Blueprint (A3: see R2/R3) →
Private Game (A3).

---

## Part 4 — Quarantine: the offline shelf (MAYBE, dedicated)

Offline progression is its own decision, not an item design — parked here
as one coherent optional package, all through the Bedroom:

- **The Bed** · `Bedroom/Bed` A–G · sleep mode: tables simulate up to N
  hours while away at reduced rate; the seven bed styles are the literal
  upgrade track (visibly nicer each tier).
- **The Laptop** · `Computer/MacBook` · one designated table keeps dealing
  while the game is closed; sits open and playing in the room.
- **Night Table** · `Bedroom/Night_Table` · offline time also accrues
  active-deck XP.
- **Rise & Grind** · `Bedroom/Pillow_9` · return after 6h+ away: first 50
  hands golden (+1 win tier). (Really a login ritual, not offline
  earnings — could graduate to the main list.)

## Part 5 — Parking lot: good ideas that DEMAND new UI verbs

Each of these needs exactly one new in-run interaction to exist. Parked
until/unless a verb is worth buying:

- **Sticky Notes** — player-authored per-table auto-rules ("cash out at
  $50", "close after {chip}"). Needs a rule-picker UI. The strongest idea
  here; maybe the ONE verb worth adding someday.
- **The Vault** (`Office_Metallic_Closet`) — deposit bankroll that survives
  a failed shove but doesn't count for the multiplier. Needs deposit UI.
  (The no-UI cousin is Insurance Policy, already in the list.)
- **The Telephone** — incoming House contracts (accept/decline). Contracts
  are a whole-game system with their own UI; the phone is its body when
  that happens.
- **Marked Deck** — peek runout 1's result before committing the shove.
  Needs a pre-shove decision moment.
- **Shred-an-upgrade** (A3) — feeding owned catalog items to the shredder
  to engineer losses (the anti-chip idea). Needs a "select upgrade" UI;
  belongs to the act-3 design pass.
- **Room rearranging as a player feature** (`WacomTablet`) — the room
  editor itself, unlocked. It's UI by definition.

## Part 6 — Shared micro-systems (build once, spend everywhere)

1. **Once-per-run trigger flags** — Fridge, Duck, Bathtub, Copy Machine,
   Microwave, Fire Extinguisher, Diploma (per stake), Medical Kit (per
   table). One run-state set, mirrors `stakes_won_this_run`.
2. **Heater/streak tracker** — per-table win/loss streak state + a small
   glow UI: Toaster, Microwave, AC, Sugar, Breakfast, Tilt Bin, Candle,
   Bathtub, Washing Machine, Console warm-up.
3. **Event hooks** — most [event] items hang off events that already exist
   in the resolution loop (tier outcomes, busts, denied bounties, bankroll
   thresholds).
4. **Rivals/regulars** — persistent named opponents + per-name records:
   Glass Door, Headset, Water Dispenser, Private Game.
5. **Room actors** — things that move on their own (Cat, Rumba): cosmetic
   pathing + one gameplay touchpoint each.
6. **Growth-over-time visuals** — Plants, Bonsai: stage index from
   hands-played / shove-count, sprite swap. Pure data.
7. **Feat pins** — Corkboard, Poster Wall, Photos: condition-checked
   predicates; the hint-rules UnlockRegistry pattern already does this.
8. **Info overlays** — Rig, Calculator, Water Dispenser, Headset,
   Whiteboard, Blueprint: read-only surfaces on existing draws.

## Part 7 — Notes

- Design stance (the big one from review): **no new in-run verbs.** All
  agency is purchase-time; in play, everything fires itself with a visible
  moment. The catalog is the game's only button.
- ~50 mechanical items: [event] 19 · [rule] 13 · [ritual] 11 · [auto] 5 ·
  [info] 6 · [collect] 4 — zero bare stat sticks, zero new UI surfaces.
- The room reads as a machine you've assembled: the clock chimes, toast
  pops, the bin fills, the cat naps, the robot patrols — all broadcasting
  game state without being controls.
- Nothing is costed or balanced; era tags are gut placement. Cut freely —
  this is a menu, not a commitment.

