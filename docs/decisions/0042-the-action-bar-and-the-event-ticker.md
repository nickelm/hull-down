# 0042 — The action bar and the event ticker

## Context

By iteration 2's close the game had every mechanic on screen but two gaps in how the player meets
them. Orders were split across two input languages: move and fire were clicks on the board, but
turret traverse, overwatch and centre-on-unit were keyboard-only, discoverable solely by reading the
keybind legend. And outcomes had no timeline: the account of an action — a contact spotted, a round
fired, a plate holed — reached the screen as markers appearing and a single after-the-fact summary
in the top-left status block, which is a developer's readout, not feedback. The status line also
overwrote itself, so a turn with three notable things in it kept only the last.

Meanwhile `ActionPlayer` treated every shot event as an instant. A whole fire action resolved on
screen in one frame: no beat between the round leaving the barrel and the answer, nothing for a
summary to be *in sync with*. Four pacing keys (`shot_flight_seconds`, `shot_impact_seconds`,
`destroyed_seconds`, `spot_seconds`) had sat authored-but-unread in `data/rules.json` since the
combat batch.

Overwatch specifically had an aiming problem. The O key lays the watch down the bearing to the
cursor — fine for a hand already on the keyboard, meaningless as a button, because a button click
carries no bearing.

## Decision

Three additions, all in `game/`, none touching a rule.

**A bottom-centre action bar** (`ActionBar`) carries the orders that were keyboard-only: turret
left, turret right, overwatch. Move and fire deliberately stay off it — the movement overlay and
the hover forecast are their affordance, and a "move" button that arms a click adds a step to the
game's most common order. Each button's enabled state restates the legality ladder of the
corresponding action (`TurretAction.legality`, `Overwatch.legality`) from state the card already
reads; if the mirror ever drifts, the click still gets the resolver's answer, so drift is cosmetic.
A hint line above the buttons says what the next click will do, which is the one piece of mode a
click-driven scheme cannot show any other way. The corner button row gains **Centre** (the F key's
action), completing prev / next / centre / end-turn.

**Overwatch from the bar is a two-step order.** The button arms an aiming mode owned by
`PlayerController` — the bar only displays it — and the next click on the board is the bearing,
consuming the click entirely: not a move, not a selection, not a shot. The mode is one click deep by
construction and disarms on selection change, end of turn, or pressing the button again. The O key
keeps its one-step semantics.

**An event ticker** (`EventLog`) above the bar narrates the replay. `ActionPlayer` gains an
`event_reached` signal — emitted once per event, in stream order, at the moment its animation
begins, on the skip and instant paths too — and the controller translates events to English there
(`sim/` still carries none, 0022). The stream arriving at that signal has already passed
`ViewState.filter`, so the ticker structurally cannot say more than the board shows; the narration
needed no visibility logic of its own beyond choosing not to announce the player's own moves.
Refusals and order confirmations move from the `80_order` status line into the same ticker. Lines
hold a few seconds, fade, and go: anything worth keeping lives in a panel — the card, the roster —
and a line here is a nudge to look at the board, not a record.

**Shot events get their beats** from the four authored keys. FIRE holds `shot_flight_seconds`, HIT
and MISS hold `shot_impact_seconds`, DESTROYED holds `destroyed_seconds`, and a SPOT's placement —
still instant, 0034 — is followed by `spot_seconds` of hold so a reveal registers before the next
leg of a move drags the eye away. Pacing only: skip and instant collapse them like every other
duration, and nothing about an outcome changes because 0022 resolved it all before playback began.

## Consequences

The three-orders-per-unit loop — move, shoot, watch — is now operable entirely by mouse, and the
bar doubles as a capability readout: a greyed overwatch button *is* the "no ammunition" refusal,
shown before the click instead of after it. The cost is a mirror of the legality conditions in
`game/` that can drift from the resolver's ladder; the failure mode is a button that looks wrong,
never an order that resolves wrong.

The fire summary (`_shot_report`) is gone rather than duplicated: the ticker narrates the same
stream the summary was assembled from, in the same words, on the beats the rounds land. A player
who skips the replay still gets every line, because `event_reached` fires on the seek path.

The ticker gives fog of war a voice it did not have — "gunfire heard" now appears as text in the
beat the ripple lands, and "contact — enemy spotted" lands mid-move on the step that earned it
(0025). Both were previously markers a player could miss while watching their own tank.

`Hud` now owns four anchored surfaces plus the ticker strip, all fed by the one resize connection
and font-scale rule from 0023. The bottom-centre column (bar, ticker above it) joins the corner
map: status top-left, card top-right, roster centre-left, legend bottom-left, turn controls
bottom-right.
