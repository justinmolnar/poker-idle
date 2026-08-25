> **Legacy (moved 2026-08-25).** Already superseded 2026-08-24: hints were split into story beats (`data/story.lua`) and stateless popups (`data/hints.lua`), scripted in `docs/house-script.md`. The 41-hint list here no longer exists in the game.

# Hint reference (rev 4, 2026-07-15)

> **Superseded (2026-08-24).** The hint list was split into story beats (`data/story.lua`) and stateless popups (`data/hints.lua`); every line now lives in `docs/house-script.md`. Kept for the review notes.


Every tutorial hint currently in the game, in priority order (= list order in
`data/hints.lua`). Copy is quoted verbatim; `{chip}` / `{w:stack}` render as
the live glyphs. Each entry ends with a Notes/revisions slot for review
feedback — jot copy rewrites, trigger tweaks, or "cut this" there.

Two classes:
- **sticky** — forced bubble + pulsing highlight; everything OUTSIDE the
  highlighted widget(s) and the bubble dims (feathered edge that breathes
  with the ring). Up until its done-condition fires or the bubble is
  clicked. One sticky at a time, and the [i] queue is hidden entirely
  while one shows.
- **queue** — an [i] icon in the strip right of the tables sidebar. Hover to
  see the bubble + highlight with the same dim treatment; click the icon to
  dismiss. Never expires once queued; icon hides (without dismissing) while
  its target isn't on screen. A NEW [i] arrives with fanfare: the gold
  AwardGlow pop plus a pulsing ring for ~3 s (arrival sound TODO).

Mechanics:
- THE HOUSE (the captor) is a shape-drawn poster above the SHOVE button
  (GrindView:_drawHouse, anchor "house"; no label — just the gold-roofed
  glyph). Every hint bubble is the House talking: it rises right-aligned
  above the poster with a speech tail down to the roof, and the poster
  stays lit through the dim. (Fallback when no House is on screen: the
  bubble floats beside the first mark.) The "?" help-desk button sits in
  the poster's top-right corner.
- A hint can highlight several widgets at once (`anchor` list in data).
  Copy can be multi-paragraph (`text` list in data).
- Any hint whose done-condition already holds when it would first fire is
  retired silently — that's how veterans and old saves skip it.
- SHOVE gating: until the first-ever run banks `GAMEPLAY.SHOVE_UNLOCK_CHIPS`
  (3) the button renders greyed-out/disabled (its "+N {chip}" badge stays
  live as the progress readout, no tooltip) and the top-bar SHOVE % cell is
  absent. The top-bar chip count (banked meta currency) is hidden until the
  first shove — pre-shove chips live on the SHOVE button badge.
- The HELP DESK (views/HintLogPanel.lua) opens from the "?" on the
  poster: a compact list of hint titles rising from the House. Hovering a title
  replays that hint in-game (real bubble from the House, rings, dim; no
  dismiss footer); titles whose targets aren't on screen render faint.
  Click away or ESC closes. Lists delivered hints only (seen or queued),
  in teaching order. TUTORIAL builds have no top-bar "?" — it survives
  only in prototype builds (how-to-play modal). Note the old glossary is
  currently unreachable in TUTORIAL builds.

---

## Phase 1 — first minutes

**first_table** · sticky · highlights the NL2 add-table button
- Trigger: no tables open, never shoved, 0 hands ever played (fresh save).
- Done: a table is open.
- Says: "Thanks for your participation, open a table."
- Notes/revisions:

**hover_things** · queue · highlights one hoverable surface in each screen region: table 1's $/h readout, the TIED UP cell, the NL2 add-table button, the Sharper Reads card
- Trigger: 2+ hands played.
- Retires unseen if: 15+ hands already played when first checked.
- Says: "Hover anything for details. Stats, buttons, upgrades: everything explains itself."
- Notes/revisions:

**table_stats** · queue · highlights every open table's $/h readout
- Trigger: 5+ hands played.
- Retires unseen if: 20+ hands already played when first checked.
- Says (multi-paragraph):
  - "Hands land in four sizes:"
  - "wins  {w:small} {w:medium} {w:large} {w:stack}"
  - "losses  {l:small} {l:medium} {l:large} {l:stack}"
  - "$/h is the table's average per hand. The gold {w:stack} % is your chance at a {w:stack} per hand."
  - "Hover for the math."
- Notes/revisions:

**help_exists** · queue · highlights THE HOUSE poster
- Trigger: 18+ hands played.
- Retires unseen if: 35+ hands already played when first checked.
- Says: "Visit the help desk to view all previous hints."
- Notes/revisions:

## Phase 2 — the earning loop

**run_upgrades** · sticky · highlights the Sharper Reads sidebar card
- Trigger: no run upgrades owned AND bankroll covers Sharper Reads' next level.
- Done: any run upgrade bought.
- Says: "You can afford an upgrade. They reset every run, and pay for themselves."
- Notes/revisions:

**multi_table** · queue · highlights the NL2 add-table button
- Trigger: exactly 1 table open and bankroll covers another NL2 buy-in.
- Done (silent-retire only): 2+ tables open.
- Says: "Open another table to double the speed you can play hands."
- Notes/revisions:

**tied_up** · queue · highlights the TIED UP cell, the CASH OUT button, AND every open table's "Tied up $X" label
- Trigger: 1+ tables open, any money tied up, and bankroll can't cover an NL2 buy-in.
- Retires unseen if: already shoved.
- Says (multi-paragraph):
  - "Short on cash? Most of it is TIED UP in your tables, still in play."
  - "CASH OUT or close a table to take it back."
- Notes/revisions:

**stake_ladder** · queue · highlights the NL10 add-table button
- Trigger: bankroll covers the NL10 buy-in ($10).
- Retires unseen if: an NL10 table was opened or already shoved.
- Says (multi-paragraph):
  - "NL10 is open. 10x the potential winnings but be warned, the opponents only get harder to beat."
  - "Upgrade to increase your edge."
- Notes/revisions:

## Phase 3 — overload and failure

**focus_overload** · queue · highlights the FOCUS cell AND the Focus sidebar card
- Trigger: focus multiplier below 100% (over capacity).
- Retires unseen if: already shoved.
- Says (multi-paragraph):
  - "You can't focus on this many tables."
  - "Close one, buy the Focus upgrade, or suffer a penalty to ALL tables."
- Notes/revisions:

**quick_reset** · sticky · highlights the Quick reset button (over SHOVE's slot)
- Trigger: quick reset is available (bricked: no playable tables, no buy-in).
- Done: quick reset no longer available (used it, or recovered).
- Says: "Bricked? The house is merciful. Free reset to $2; your {chip} ride along."
- Notes/revisions:

## Phase 4 — gold chips and the shove

**first_chip** · queue · highlights the banked table button's "+N {chip}" badge AND the SHOVE button's "+N {chip}" badge
- Trigger: first {chip} banked this run.
- Retires unseen if: already shoved.
- Says (multi-paragraph):
  - "A {w:stack} win banked your first {chip}."
  - "Once per table type each run (DIVERSIFY); gold trim marks the ones that paid."
- Notes/revisions:

**chip_denied** · queue · highlights the banked table button's "+N {chip}" badge AND the SHOVE button's "+N {chip}" badge
- Trigger: first jackpot on a table whose (stake, type) already paid this run.
- Retires unseen if: already shoved.
- Says: "That table already paid its {chip} this run. Other stakes and types can still payout, this one cannot."
- Notes/revisions:

**shove_ready** · queue · highlights the SHOVE button
- Trigger: 3 {chip} banked this run (`GAMEPLAY.SHOVE_UNLOCK_CHIPS`) — the
  exact moment the SHOVE button enables (first-ever run only; anyone who
  has shoved keeps SHOVE from hand one). Queue on purpose: unlocking must
  not read as pressure to use it.
- Retires unseen if: already shoved.
- Says (multi-paragraph):
  - "SHOVE has unlocked."
  - "It bets everything on one hand and ends the run. Win or lose, your {chip} stay yours to spend."
  - "No rush."
- Notes/revisions:

**shove_pct** · queue · highlights the top-bar SHOVE % cell
- Trigger: shoved at least once AND total money (bankroll + tied) ≥ $10 (first bankroll-tier crossing).
- Retires unseen if: shoved twice already.
- Says (multi-paragraph):
  - "Your SHOVE % has two parts: catalog upgrades set the base, your total money multiplies it."
  - "Hover for the math."
- Notes/revisions:

## Phase 5 — post-shove meta

**catalog_intro** · one-time CALLOUT inside the catalog modal, not a bubble
- Trigger: first post-shove catalog open (TUTORIAL builds). A recessed band
  under the CATALOG header; marked seen on Continue
  (hints_seen["catalog_intro"]). Never shows in the read-only mid-grind catalog.
- Says: "Make your cell a home. Everything here is permanent."
- Notes/revisions:

**two_currencies** · queue · highlights the Sharper Reads sidebar card AND the top-bar CATALOG button
- Trigger: shoved at least once AND no run upgrades owned (the fresh post-shove run).
- Done (silent-retire only): a run upgrade bought.
- Says: "Sidebar upgrades reset each run, items from the catalog don't (view them with the catalog button)."
- Notes/revisions:

---

Not yet built: phase 6 (HU / Zoom / MTT / idle-mode / decks first-contact
hints) — see docs/tutorial-teaching-list.md.
