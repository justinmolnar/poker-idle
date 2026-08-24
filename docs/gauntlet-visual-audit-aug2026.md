# Gauntlet visual audit + overhaul proposal

Date: 2026-08-23. Nothing built. This is the audit and the proposal only.

## What I read first

| Work | Read |
|---|---|
| Chip overhaul | `3b7e737` full message + diff (`views/Chips.lua`, `views/ChipPile.lua`, `data/chips.lua`) |
| Felt steps 1-4 | `715c85a` (`views/FeltLayout.lua`, `views/TablePanel.lua`, `services/SpriteLoader.lua`, `views/CardSprites.lua`) |
| Felt steps 5-6 | working tree: `data/felt_style.lua`, `views/FeltDecor.lua` in full, plus `git diff` on `FeltLayout`, `CardSprites`, `stake_themes`, `main.lua` |
| Gauntlet | `views/ShoveView.lua` (1069 lines) in full, `views/ShoveDebugOverlay.lua`, `states/ShoveState.lua`, `models/Gauntlet.lua`, `models/shove_rate.lua` |

Two notes on the brief: the rate model is at **`models/shove_rate.lua`**, not `data/shove_rate.lua` (there is no such file — correct per the architecture rules, it has logic). And the felt harnesses (`feltdecor_test.lua`, `decor_test.lua`) are gone — `$CLAUDE_JOB_DIR` is unset in this session and the previous job dir has been cleaned. I rebuilt the pattern from scratch and verified it works; see §7.

---

## 1. The gauntlet has ONE size. The gate apparatus does not transfer.

Confirmed, not assumed:

- `main.lua:75` pins `BASE_W, BASE_H = 1600, 900` and `main.lua:88-90` monkey-patches `getDimensions/getWidth/getHeight` to return those constants unconditionally.
- `FontService.layoutScale` = `min(W/1280, H/720)` clamped to ≥ 1 → **always exactly 1.25**.
- `ShoveView:draw` derives every size from `ui_scale` and `love.graphics.getDimensions()`. Both are constant. `recomputeLayout(H, fonts, s)` is called every frame with `H = 900, s = 1.25` forever.

So `recomputeLayout` is a function of nothing. It produces one answer. There are no 32 sizes to degrade across.

**Therefore: no shed ladder, no drop priorities, no `min_*` gates, no per-band decisions.** Porting `felt_style`'s threshold machinery here would be pure cargo-culting — it would add a data file whose every branch is dead. Called out explicitly because the brief asked.

What *does* transfer: the **material vocabulary** (rail, recessed surface, vignette, card shadows, plates instead of holes), the **one-decision-point split** (a layout module that publishes rects, a decor module with zero thresholds), the **data-driven knobs in `data/`**, and the **Theme-token-only colour rule**.

---

## 2. Measured layout

Computed by loading lines 39-94 of `views/ShoveView.lua` verbatim into a headless Lua chunk and calling the real `recomputeLayout` — no transcription of any expression. Font metrics parsed from `assets/fonts/Thin Sans.ttf`: `unitsPerEm 1024`, `hhea asc/desc/gap 2048/-512/128` → **2.625 em per line exactly**, so `sm/md/lg getHeight()` = **21 / 42 / 63 px**. (This confirms `FontService.INK_OF_LINE = 1.25/2.625` from the face itself.)

```
ui_scale 1.25   CARD 110x154   gap 15   POT_BAND_H 110 (never scaled)

  Y_BANNER           44
  Y_STATS           117
  Y_POT             169
  Y_DEALER_HOLE     289
  Y_DEALER_LABEL    451
  Y_BOARD           473
  Y_PLAYER_LABEL    635
  Y_PLAYER_HOLE     657
  Y_CHIPS           829     chip_h 52 -> content ends at 881 of 900

  felt band   y 249..851   602px tall (67% of 900), 1600px wide (100%)
  pot band    y 169..279   110px tall (12% of 900)
  board pack  5 cards 610px (38% of 1600) · 6 cards 735px · 7 cards 860px (54%)
```

### 2.1 Both hand-label pills overlap cards by 26px

`drawLabelPill` builds `pill_h = fonts.md:getHeight() + 2*pad_y` = **42 + 12 = 54px**. The Y-chain allots **22px** between a label row and the next card row.

```
dealer pill  445..499   board card top    473   ->  26px overlap
player pill  629..683   player hole top   657   ->  26px overlap
```

Pills are drawn **after** the board cards and hole cards, so they paint over the top 26px of the middle board cards and the top 26px of both player hole cards. The pill is ~208px wide centred, so on a 610px 5-card pack it covers the top strip of slots 3 and 4 — including any best-5 highlight stroke there.

This is not a taste call. It is a 54px box in a 22px slot.

### 2.2 Vertical centring is off by 26px

`recomputeLayout` estimates `stack_h = 811`, but the chain it then builds spans **837px**. Two undercounts: the banner term omits its trailing `gap` (10px), and `chips_h` is hardcoded `18 + 36 = 54` while the real bottom is `18 + chip_h(52) = 70` (16px). Result: **top margin 44, bottom margin 19**. The stack sits 13px above centre.

### 2.3 `POT_BAND_H` is the only unscaled constant in the layout

Everything else multiplies by `s`. `POT_BAND_H = 110` does not. At the fixed base res that's harmless today, but it is the one number that would break if the base res ever moved.

### 2.4 The pot band is 110px holding a 69px pile and no text

`Chips.setScale(1.25)` → `CHIP_RADIUS = 22`, `CHIP_DIAMETER = 44`, `STACK_OFFSET_Y = -5`, `MAX_PER_COLUMN = 6`, `COL_GAP = 6`. A full column is `44 + 5*5 = 69px` tall. `ShoveView` passes only `{align="center"}` — no `max_w`, so unbounded width, one row: 30 chips of one denomination is 5 columns, `5*44 + 4*6 = 244px` wide.

So the pot band is **110px of a 900px screen holding a 69px pile, one label ("YOUR STACK", buildup only), and no dollar figure at all.**

The comment on `ShoveView.lua:903` says *"pot $ + chip stack + base × mult"* and the header on `_drawShoveStatus` says *"Keeps the pot stack + rate breakdown visible"*. **There is no `$` printed anywhere in `ShoveView`.** Stale comment describing code that does not exist — the exact trap the brief flagged.

---

## 3. The stats line is arithmetically false in Act 2+

`_drawShoveStatus` (and its near-duplicate in `_drawBuildup`) prints:

```
BASE <rates.catalog>%   ×   MULT <rates.mult>   =   SHOVE <rates.r1>%
```

`models/shove_rate.lua:95` computes `raw1 = (catalog + deck) * mult`.

`deck` is the master deck's `shove_base_per_deck_level` contribution. **It is in the product but not in the printed equation.** The moment the player owns The Master, the screen shows a multiplication whose two operands do not produce the stated result — and the missing term is precisely the one that decides whether R2 and R3 are winnable at all (`r2 = deck × mult/2`, `r3 = (deck/2) × (mult/2)`; with `deck = 0` both are exactly zero).

Related: the grind top bar prints `raw_r1` (uncapped — can read 220%), while both shove-screen readouts print `r1`, clamped to 1.0. A player at 220% presses SHOVE and watches their number drop to 100% with no explanation.

### 3.1 The two stats blocks are copy-pasted

`_drawBuildup:608-630` and `_drawShoveStatus:773-793` are the same 20 lines with `mult_now`/`win_pct` swapped for `rates.mult`/`rates.r1`. Two places decide the same thing. This is the natural seam for the plate work in §5.3.

---

## 4. Material: what the gauntlet is made of vs. what the felt is now made of

`ShoveView:draw` lines 828-870 build the entire environment from:

- 3 flat rectangles for the felt band (`0.045, 0.075, 0.060` at alpha 0.25 / 1.00 / 0.25)
- 2 one-pixel rules for the "rim"
- 6 concentric rounded rects with alpha `0.06 * (1 - i/6)` for the "spotlight"

Against the felt, which now has: an authored per-stake **rail** with a recessed inner edge, a 64×64 **vignette mask texture** stretched per rect, a **comm plate** so empty slots read as places, **card drop shadows**, and **seat plates**.

Concrete gaps, all of which the felt already solved and shipped:

| Felt has | Gauntlet has | Note |
|---|---|---|
| `FeltDecor.drawMask` elliptical vignette | 6 stacked rounded rects | The mask is already built at boot (`FeltDecor.configure` in `main.lua`) and `drawMask(x,y,w,h,color,alpha)` is public. The gauntlet can call it today. |
| `drawRail` + recessed surface, per-stake material | two 1px rules | The gauntlet has no stake, but it has an **act** — and the rail is the obvious place to carry it. |
| `drawCommPlate` — empty slots read as places | `Theme.bg.sunken` rects, which in the shove palette is **`{0, 0, 0}` pure black** | Empty board slots are literal black holes cut in the felt. This is verbatim the problem `comm_plate` was added to fix. |
| `CardSprites.shadow(x,y,w,h,alpha,off)` | never called | Cards are 110px wide, far above the felt's `min_card_w = 24`. Free. |
| `Theme.setColor` only | **3 literal `love.graphics.setColor` calls** (`ShoveView.lua:844, 846, 848`) | Only 4 files in `views/` + `states/` still do this; `ShoveView` is one of them. |

### 4.1 Card art

Good news first: the filtering trap is **already fixed** for the gauntlet. `ShoveView` → `CardSprites.sprite` → `SpriteRenderer.draw` → `atlas:getSpriteFor(name, width)`. `SpriteLoader:_conditionCard` applies `setFilter("linear", "nearest")` to every card, and card backs get the 4-level mip chain whose top level is **112×160** — `SpriteLoader.lua:52-59` names the shove gauntlet explicitly as the reason. Backs at 110px come off the 112px level: 0.98× minification, essentially 1:1.

But the fronts do not land as well:

- Fronts ship **56×80**. The gauntlet draws them at **110×154**.
- That is **1.964× horizontally, 1.925× vertically** — magnification, so `"nearest"` mag filter applies. A non-integer nearest upscale gives uneven pixel runs: some source pixels become 2px wide, some 1px, in an irregular pattern that shifts across the card.
- Worse, the two axes disagree. `ShoveView` derives height as `CARD_W * 3.5 / 2.5` = **1.4**, but the sprite's real aspect is `80/56` = **1.4286**. `FeltLayout.lua:24` uses `CARD_ASPECT = 56/80` correctly. **The gauntlet squashes every card 2% vertically relative to the felt.**

There is a clean fix sitting right there: **draw at 112×160**. That is exactly 2× the front sprite (perfect pixel doubling, nearest) and exactly 1:1 on the back chain's top level. Seven cards at 112 with a 15px gap is 874px of 1600 (55%) — it fits. It is a 2px change to `CARD_BASE_W` plus using the real aspect.

---

## 5. The cheat cards cover the equation

A visual mechanic, not a tutorial. The shove readout becomes physical: the dealer's
cheat cards land ON the terms of the equation and bury them.

### 5.1 The model

Every term is live and normal until a card covers it.

```
r1 = cat  x mult          both terms live
r2 = 0    x mult          card 6 covered the catalog base
r3 = deck x 0             card 7 covered the mult
```

- R1 plays on the catalog base.
- **Card 6 lands on the BASE plate.** The catalog base is buried, so R2 runs on 0 unless
  the master deck has filled that slot.
- R2 plays on the deck base.
- **Card 7 lands on the MULT plate.** The mult is buried, so R3 runs on 0.
- Underflow puts a number on the MULT plate the card cannot cover.

No state overrides, no halvings. A covered term is zero for the runouts after it.

### 5.2 One row of seven: the table, then the stats panel

All seven board positions sit in a single line, read as two groups.

**Left is the table.** The five community cards, with the hole cards centred
under them. Everything belonging to the table centres on the board rather than
on the screen: banner, pot pile, both hole rows, the result chips. A
screen-centred table would sit half under the panel.

**Right is the stats panel**, occupying positions 6 and 7 -- exactly where the
cheat cards land. Until they do, it is the shove equation:

```
  [1] [2] [3] [4] [5]        BASE 25%  x  MULT 4.00
        [dealer hole]                = 100%
        [player hole]                 ALL-IN
```

Measured at 112x160 cards, 15px card gap, 48px section gap, 36px op gap:

```
row 928px, x 336..1264, screen-centred
  board  1 336   2 463   3 590   4 717   5 844        (ends 956)
  panel  6 1004  7 1152                               (ends 1264)
  table centre 646        panel centre 1134
  hole cards x 526..765   total block y 585..690
```

Rules this design has to keep:

- **No slot, no plate, no outline under positions 6 and 7.** Positions 1-5 get a
  recessed slot; 6 and 7 get nothing. A card-shaped hole on the right would give
  the structure away before the first cheat is dealt.
- **The equation frame stays, the values get buried.** The multiplication sign
  sits in the gap between the two columns and never moves. The cheat cards cover
  BASE and MULT; the total underneath rolls to zero. That is the beat.
- **The total sits below the card positions**, so no cheat card can bury it, in
  the band the hole cards no longer reach now the table is centred left.
- **Text only**, worst cases checked: the Act 3 underflow puts `MULT 999` in a
  112px column (decimals shrink with magnitude) and `= 29970%` in the 260px
  panel.
- **Cards deal upright**, like every other community card. An earlier draft laid
  them sideways across a separate stats line above the table; one row makes that
  unnecessary and removes the banner and pot-band overlaps it needed.
- **There is no separate SHOVE % headline.** The panel carries the total, and a
  second copy above the table would be the same number twice.

### 5.4 Two constraints

1. **No pre-spoil.** Nothing on screen may indicate a card is coming: no slot, no empty
   sixth/seventh position in the board row, no "R2 / R3" labels. The line reads as stats
   until card 6 lands unannounced.
2. **`FEATURES.DEMO_CUT` never deals cards 6 or 7** (`ShoveView.lua:355`) and hard-gates
   `r2 = r3 = 0` (`shove_rate.lua:107`). The readout must be inert in that build. There is
   no `ShoveView_legacy`, so the mirror trap does not apply; `DEMO_CUT` is the only branch.

## 6. Build plan

**Status 2026-08-24: Steps 1-4 built (rebuilt after an external revert). Step 5
not started.** Everything below is
verified headlessly only (see §7) -- nothing has been seen rendered. The two
things needing eyes are in §8.


A visual overhaul, same class as the chip and felt passes. Ordered so each step is
independently reviewable and nothing later depends on an unapproved earlier call.

### Step 1 — Defects in what is already there

No new ornament. Everything here is a fix to existing render code.

- [x] **Label pills.** `pill_h` is 54px (`fonts.md:getHeight() + 2*pad_y`) in a 22px band,
      so both pills paint over 26px of card. **Move them beside the board** rather than
      growing the band: the board is 620px centred, leaving 490px free each side and the
      pills are ~208px wide. Kills the overlap by deletion and frees 108px of vertical,
      which is what makes the Step 4 budget fit.
- [x] **Centring.** `stack_h` undercounts by 26px (banner term drops its trailing `gap`;
      `chips_h` hardcodes `18+36` against a real `18+52`). Top margin 44, bottom 19.
- [x] **Card size.** `CARD_BASE_W 88 -> 112`, height from the sprite's `80/56` not
      `3.5/2.5`. Gives exact 2x nearest on the 56x80 fronts and exact 1:1 on the back
      chain's 112x160 top level, and ends the 2% vertical squash vs. the felt.
- [x] **Theme tokens.** Three literal `love.graphics.setColor` calls at
      `ShoveView.lua:844/846/848`.
- [x] **Stats line.** `BASE x MULT = SHOVE` omits the `deck` term that is in the product
      (§3). Fix now; it is replaced wholesale in Step 4 but should not ship wrong meanwhile.
- [x] **`raw_r1`.** The grind top bar shows uncapped (can read 220%); the shove screen
      shows `r1` clamped to 100%. Match them.
- [x] **Stale comments.** `ShoveView.lua:903` and the `_drawShoveStatus` header both
      promise a pot `$` figure that is not drawn anywhere.

**Files:** `views/ShoveView.lua` only.

### Step 2 — The split

- [x] New `views/ShoveDecor.lua` — draws what it is handed, returns early on nil, contains
      zero decisions. Mirrors `views/FeltDecor.lua`.
- [x] New `data/shove_style.lua` — tables only, no functions, no requires. Mirrors
      `data/felt_style.lua`. **Dimensions and colours, no thresholds:** the gauntlet has
      one size (§1), so gates would be dead branches.
- [x] `ShoveView` computes and publishes rects; fold the duplicated stats block
      (`_drawBuildup:608-630` / `_drawShoveStatus:773-793`) into one publisher.
- [x] `ShoveDecor.configure(fonts)` wired in `main.lua` at boot and on resize, same as
      `FeltDecor`.

**No visual change** -- proven: with every ornament added afterwards disabled,
the backdrop op stream is byte-identical to the capture taken before the
extraction.

### Step 3 — Material

- [x] **Vignette.** Replace the 6 concentric rounded rects with `FeltDecor.drawMask` over
      the felt band. Already built at boot, already public, one batched draw.
- [x] **Rail + recessed surface.** The felt band is currently 3 flat rects and two 1px
      rules. Give it a ring with the surface inset inside it, the way `FeltLayout` insets
      the band solve.
- [x] **Card slots, not holes.** Empty board slots draw `Theme.bg.sunken`, which is
      `{0,0,0}` in the shove palette — literal black holes. Recessed plates instead, the
      same fix `comm_plate` was added for.
- [x] **Card shadows.** `CardSprites.shadow(x,y,w,h,alpha,off)` exists and is never called
      here. 11 card positions, all far above the felt's `min_card_w`.

**Files:** `views/ShoveDecor.lua`, `data/shove_style.lua`, `views/ShoveView.lua`.

### Step 4 — The equation and the cheat burial

The feature. Depends on Steps 2-3.

- [x] Split the readout into separately-positioned runs (`BASE`, `MULT`, `ALL-IN`) with
      BASE and MULT anchors >= 180px apart. `RollingValue` on all three. **No backing
      graphic of any kind** (§5.2).
- [x] Fix the board row at 7 slots, split 5 + 2; delete `packOriginFor`, `visiblePackSize`, `board_x`,
      `board_x_target` and the re-centering lerp in `:update`.
- [x] Retarget card 6 to the BASE run and card 7 to the MULT run, landscape, centred on
      the text. The timeline already opens a `RUNOUT_PAUSE + CHEAT_PAUSE` window (3.0s) at
      `ShoveView.lua:356` and `:365` for each.
- [x] Buried state: the covered run reads 0 with the card resting on it; ALL-IN rolls to
      match.
- [x] Underflow: MULT carries a number the card cannot cover.
- [x] Reveal protection and `DEMO_CUT` inertness per §5.4.

**Files:** `views/ShoveView.lua`, `views/ShoveDecor.lua`, `data/shove_style.lua`.

**Verified budget** at 112x160 cards with the hand labels moved beside the board:
content 823 of 900, margins 38/39. Board 620px centred leaves 490px free each side; the
label pills are ~208px wide.

### Step 5 — Act identity (optional)

- [ ] The rail carries the act the way `stake_themes.rail_color` carries the stake. Keyed
      on `shove_r1_won` / `shove_r2_won`. Gold stays reserved for {chip}, same call the
      felt rail palette made.

### Not in this plan

- **No gates, shed ladders, or drop priorities.** One size (§1); every branch would be dead.
- **No betting arc or table silhouette.** Cut from the felt for having no silhouette to
  belong to; the gauntlet band is more rectangular still.
- **No `fonts.xs`.** Resolves to the same 8px as `sm`.
- **No new shaders.** `FeltDecor` chose a texture over a shader so the love.js build cannot
  fail to compile it; same reasoning here.
- **No popups, hints, or explanatory copy.** Second pass.

### What Step 3 actually did to the lighting

The 6 concentric rounded rects are superseded, not deleted: `spotlight.enabled`
is false and the block stays so the harness can put the old lighting back and
diff. The replacement is two masks -- FeltDecor's existing ramp stretched over
the whole viewport for the room vignette, and a second ramp built in
`ShoveDecor.configure` that runs the opposite way (opaque centre, transparent
edge) for the light over the card rows. FeltDecor's mask is authored to darken
edges and cannot stand in for a light, which is why there are two.

## 7. Verification plan

Harnesses in the scratchpad, not the repo. Lua 5.4 on PATH. **Built and passing:**

| Harness | Guards |
|---|---|
| `shove_layout_harness.lua` | Loads the real constant block + `recomputeLayout` verbatim. Card metrics (exact 56x80 multiple, aspect == sprite, back within a mip level), label pills clear every card rect at the worst-case string, margins equal, stack unclipped. |
| `love_stub.lua` | Records every graphics op instead of drawing; tracks transform depth, line width, blend, shader, canvas, font. Enough image support that mask-building paths actually execute. |
| `backdrop_golden.lua` | Captured the inline backdrop's op stream **before** the extraction by loading the block verbatim. With every new ornament disabled, `ShoveDecor` reproduces it byte-identically. |
| `stats_model.lua` | The readout agrees with the cheat model at every stage across Act 1 / Act 2 / underflowed: `r1 = cat x mult`, `r2 = 0 x mult` (and 0 outright with no master deck), `r3 = deck x 0`, and mult surviving card 7 once underflowed. Also asserts BASE and MULT anchors stay >= 180px apart so one cheat card cannot clip the other run, and that the cheat draw restores graphics state. |

`luac -p` passes on every touched file. Original plan, for reference:

1. **Golden regression** — snapshot every draw call (op, args, colour, transform) from a stubbed `love` through a full timeline replay: buildup → R1 → cheat → R2 → cheat → R3, both `DEMO_CUT` states. With every new ornament disabled the trace must be **byte-identical** to the pre-change snapshot. Captured before touching anything.
2. **Layout invariants** — no ornament rect escapes the felt band; the label pill never intersects a card rect (guards §2.1 permanently); top and bottom margins equal.
3. **Draw hygiene** — the stub asserts transform depth, colour, line width, blend mode, shader, canvas and font are restored across every new draw function.
4. **Card metrics** — front draw size is an exact integer multiple of 56×80; back draw width matches a chain level within 1.0×; drawn aspect equals `80/56`.
5. **Rate/plate agreement** — for a grid of (catalog, deck, mult), the displayed `BASE × MULT` equals the displayed ALL-IN, and the post-cheat plate values equal `r2` and `r3` from `ShoveRate.compute`. This is the guard that makes §3 unable to regress.
6. **Palette guard** — no gauntlet rail or plate colour comes within a distance threshold of `Theme.currency.chip` gold, mirroring the felt's rail-palette test.
7. **Reveal guard** — before `chip_visible[1]`, no draw call references cheat geometry; under `DEMO_CUT`, none ever does.
8. `luac -p` on every touched file.

## 8. What I need you to look at

I cannot see the result. When Step 1 lands, the two things worth your eyes:

- Whether the 112px cards read crisper than the 110px ones, side by side with a grind table open behind them.
- Whether the label pills, once they stop overlapping, still read at all where they end up — moving them may be better than resizing the band.

Per §5.2, card 7 is seen twice in the whole game. Budget the polish accordingly: this beat gets one chance to read.
