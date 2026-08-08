# 0012 — Turn cycling lands in iteration 1

Amends the scheduling note in [0003](0003-side-alternating-turns.md). The turn *model* in 0003 is
unchanged; only the iteration it ships in moves.

## Context

0003 chose side-alternating turns with full activation, and closed by saying that Tab-cycling with a
clear "who has not acted" indicator "is not optional" but that the UI "lands in iteration 2".
`docs/design/rules.md` §1 and `docs/hull-down-v1.md` §6 agree: iteration 1 has one unit and no turn
structure.

That scoping is now the thing blocking playtesting. With one unit and no way to end a turn, the
build allows exactly one move and then nothing. Movement points never refill, so the movement
overlay can only ever be inspected once per launch, and the visibility overlay can only be seen from
one vantage point per launch. The two features iteration 1 exists to prove are each observable once.

`UnitState` already carries `side` and `begin_turn()`; nothing has ever set or called them. The gap
is not in the simulation's model, it is that nothing owns more than one unit.

## Decision

Turn cycling ships in iteration 1. Specifically:

- **`sim/match_state.gd`** owns the unit list, the turn number, the active side, and per-unit
  activation. Pure `RefCounted`, like everything else in `sim/`.
- **Two units per side**, deployed into `md.zone_tiles(1)` and `zone_tiles(2)`.
- **Hot-seat.** There is no AI — that remains iteration 2 — so the player drives both sides. Ending
  a turn hands control over rather than triggering anything.
- **Selection** is Tab, plus Prev / Next / End Turn buttons in the HUD. Only the active side's units
  can be selected or ordered.
- `end_turn()` flips the active side, calls `begin_turn()` on every unit, and increments the turn
  number when the side wraps back around.

What does **not** move forward: the two-actions-per-unit budget from 0003. Actions are shooting and
overwatch, and there is no combat in iteration 1, so there is nothing for a second action to spend
itself on. Movement points remain the only budget. The activation flag is tracked but is advisory —
it drives the "who has not acted" indicator and nothing else.

## Consequences

- Iteration 1's acceptance checks become repeatable. Driving a tank onto a ridge, ending the turn,
  and driving the next one along the same crest is the loop the visibility overlay was built to be
  judged by, and it is now reachable.
- Side B's tanks give the visibility overlay real targets instead of empty ground, which is a better
  test of the hull-down band than an unoccupied ridge.
- `PlayerController` changes shape rather than gaining a feature: it held `tank.state` directly, and
  now holds an index into `MatchState`. Everything that recomputed on move now also recomputes on
  selection change.
- `docs/design/rules.md` §1's parenthetical — "iteration 1 has one unit and no turn structure" — is
  now false and is updated with this record.
- Two units per side on a 200×200 map is sparse, and deployment picks the first passable tiles in a
  zone rather than anything tactical. That is deliberate: unit composition and deployment are
  iteration 2 problems, and guessing at them now would be work thrown away.
