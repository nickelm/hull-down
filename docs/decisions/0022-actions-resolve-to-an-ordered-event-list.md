# 0022 — Actions resolve to an ordered event list

Establishes `sim/actions/` and moves the move pipeline out of `game/`. Implements the resolution
half of [0003](0003-side-alternating-turns.md); the movement budget half is
[0014](0014-movement-in-two-action-points.md).

## Context

There was no such thing as an action. A move was three statements in a click handler
(`PlayerController._on_click`): ask the pathfinder for a route, call `UnitState.apply(path)`, call
`TankView.play(path)`. Legality was four `if` statements above them, each paired with the English
string it printed. Nothing in `sim/` knew that a unit had moved, only that its fields were different
from before.

Three things follow from that, and the third is the reason this record exists.

**The simulation was downstream of an animation.** `mark_activated` — a simulation state
transition — was called from `_on_move_finished`, which is emitted by `TankView` when its
interpolation reaches the last leg. A unit became "done for the turn" because a lerp finished. That
is also unsound in an order nothing prevented: no key and no HUD button was gated during playback,
so pressing End Turn mid-drive ran `begin_turn()` on the unit still animating, and the completion
handler then evaluated `can_act()` against a refilled unit and marked the wrong thing.

**Legality was not reusable.** The AI in iteration 2 has to ask the same questions the click handler
asks, and it cannot, because the answers were interleaved with `hud.set_line` calls.

**There was nowhere to put an interruption.** Overwatch, reveals and reaction fire all resolve at
*points along a path* — the defender's shot happens when the mover reaches a particular tile, not
before it sets off and not after it arrives. A pipeline whose only representation of a move is "the
unit is now over there, with this much less fuel" has no place to hang that. The path is a plan, not
an account of what happened, and the difference between those two is exactly what iteration 2 needs.

## Decision

**An action resolves, in `sim/`, to an ordered list of events. The simulation applies the whole
action instantly and completely. The presentation layer replays the list.**

`ActionEvent` is one concrete `RefCounted` with a `kind` discriminant — `BEGIN`, `TURN`, `STEP`,
`ACTIVATED`, `END` — and a fixed field set (`unit`, `tile`, `facing`, `cost`, `mp_left`, `flags`)
where every field means the same thing in every kind. Not a class hierarchy, because iteration 2
interleaves *other units'* reactions into the same ordered stream and a heterogeneous stream forces
every consumer into an `is`-chain; `match ev.kind` is one dispatch table. Not a struct-of-arrays
either — the `Packed*Array` rule is a bulk-data rule about 640k-cell fields, and an action's event
list is tens of entries produced once per order.

`BEGIN` and `END` carry the start and final pose. They are what makes an interleaved stream
unambiguous about whose sub-sequence is being watched, and they are enough on their own to apply an
action without understanding any of the kinds between them.

The layer splits in two:

- **`MoveAction`** is the rules of one action, all static. `legality` returns a `Status` enum and
  allocates nothing. `plan` is pure — it builds the full event stream without touching `MatchState`.
  `commit` walks the events and applies them.
- **`ActionResolver`** is the sequencer, and the only object that sees every unit. It owns the
  per-movement-class pathfinders and derives the occupancy overlay from `MatchState`. `plan_move` is
  pure; `resolve_move` is plan-then-commit.

`commit` **replays the event list** rather than applying the path wholesale. That makes "the event
stream is the authoritative account of what happened" a property a test can check rather than a
comment, and it is the shape an interruption needs: an event that stops the unit at tile six is
handled by the remaining events not being applied, with no special case anywhere.

**The plan/resolve split is a determinism boundary.** [0005](0005-deterministic-seeded-simulation.md)
says the combat stream advances per *resolved action*. That sentence is only enforceable if exactly
one function constitutes resolving an action. `resolve_move` is it — it is the only mutator and the
only thing that will ever draw from `Rng.stream(seed, COMBAT)`. `plan_move` is pure and non-random,
so the hover preview may call it on every mouse move and an iteration-2 AI may call it a thousand
times while scoring, with no consequence for the roll a subsequent shot makes.

**Legality is an enum, never a string.** `sim/` carries no English. The refusal messages move to the
controller.

**The presentation layer's guarantee is structural, not conventional.** `ActionPlayer` is
constructed without a reference to `MatchState`, `UnitState` or `ActionResolver` — it holds nothing
it could write through. Event durations are derived from event data (a turn's duration from
`Grid.turn_steps`, a step's from the distance between tile centres), never measured. 1x, 3x and
instant are the same `_apply(event, t)` code path consuming a scaled `delta`; instant simply applies
every remaining event at `t = 1.0`. Playback ends by snapping the view to the pose the *simulation*
reports, not to wherever interpolation arrived, so a skipped or interrupted replay cannot
desynchronise the two.

`UnitState.apply(path)` is deleted. Two ways to move a unit is how they drift.

## Consequences

- A unit is marked activated inside `resolve_move`, before any view exists, and a headless test with
  no `TankView` in it pins that.
- Every control is gated for the duration of a replay, which closes the End-Turn-mid-animation hole.
  Skip is always available, so gating costs the player nothing.
- The speed toggle is trivial and provably cannot change an outcome. Iteration 2's fast enemy turn is
  the same mechanism at `instant`.
- The ordered input log [0005](0005-deterministic-seeded-simulation.md) requires becomes a list of
  orders, each of which reproduces its event stream exactly. `ActionResult.fingerprint()` makes
  comparing two runs one integer comparison.
- Iteration 2 adds kinds to the enum and two fields to `ActionEvent`, and weaves interruptions in
  `ActionResolver`. No consumer changes shape. The camera follows whichever unit the current `BEGIN`
  names, so a spliced reaction-fire sub-sequence retargets it for free.
- `PathResult` gains `step_cost` and `turn_cost`, populated during backtracking from the `g` values
  the search already holds. The pathfinder owns the cost model and is the only honest source for
  per-step cost; recomputing it in the resolver would be a second copy that can disagree with the
  search, and a preview that disagrees with what the move charges is the worst bug this game can
  have. The invariant `sum(step_cost) + sum(turn_cost) == cost` is pinned by a test.
- Occupancy needed nothing: [0015](0015-movement-classes-and-the-traversal-graph.md) already made it
  a per-query blocker overlay, and the resolver derives it from `MatchState.occupancy()` on the way
  through. An occupied destination gets its own `Status` so the player is told what is actually
  wrong rather than "no route".
- The cost of the split is one indirection on the hover path: the preview now builds an event list
  it mostly does not read. Tens of `RefCounted` per hover-tile change, against a `find_path` in the
  same statement. Not measurable, and worth it for having exactly one shape that `game/` consumes.
