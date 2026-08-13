# 0030 — Overwatch is a per-tile interrupt that truncates the movement stream

## Context

0003 established side-alternating turns and named the problem they create: *"Alpha strike is real: a
side that wins the first-contact roll can concentrate everything before the other side responds.
Overwatch exists to answer this, and is the reason it costs a unit its whole turn."*

Overwatch was therefore always going to exist, and it was always going to be the hardest thing in
iteration 2 — because it is the only mechanic that needs both halves of it working at once. The
trigger is a spotting question and the consequence is a combat one, and it resolves at a *point along
a path* rather than at either end of one.

0022 built the event stream for this and predicted the mechanism: "an interruption that stops the
unit at the sixth tile is the remaining events not being applied". 0026 found the half of that
prediction which needed sharpening. This record is the rule itself.

## Decision

**A unit goes on overwatch by laying its gun down a bearing, and gives up the rest of its turn for
it.** `Overwatch.plan` emits `TURRET`, `WATCH`, `ACTIVATED` — the whole action point is forfeited
(0021) and the turn ends (0003). It is priced exactly as firing is, because it is the alternative to
firing.

**The lane is one 45-degree step either side of the laid bearing** — a 90-degree cone,
`combat.overwatch_arc_steps: 1`. Deliberately much tighter than the turret's own ±135°. At two steps
the cone is 180 degrees, one watcher covers the whole approach, and choosing *where* to lay the
ambush stops being a decision at all. That was the first value tried and the tests that caught it
were the ones asserting a mover at right angles walks past untouched.

**The trigger is tested once per tile the mover enters, after that tile's spotting recheck and never
before it.** The order is fixed and it is a rule:

```
STEP  ->  spotting recheck, both sides  ->  overwatch trigger  ->  shots  ->  truncation
```

A watcher cannot shoot at something it has not seen, and the reveal must precede the tracer *in the
stream* so the presentation layer can put a contact marker down before a round comes out of it. Tests
pin the ordering rather than a comment asserting it.

**Watchers resolve in ascending unit index order**, and each is re-tested immediately before it
fires: an earlier watcher in the same pass may have killed the mover, and a corpse is not a target.
Fixed order is the determinism guarantee — with two watchers on one lane, which gets the first shot
must not depend on iteration order, or the match stops being reconstructible from its seed.

**Being shot at stops the mover where it stands and takes nothing else from it.** No forced
activation, no forfeited movement. 0021's forfeit rule is about *paying* for a whole action, and
taking fire is not a payment. The tank can be ordered on again — into the same ambush, if the player
insists. Overwatch costs you tempo, not your turn.

**The free hull swivel cancels it** — 0032, and that price is what makes the whole thing hold
together.

## Consequences

Truncation is `break`. `MoveAction.close_stream` rebuilds the tail against the tile the tank really
reached, so an interrupted stream is a complete, self-consistent account of a **shorter** move rather
than a full one with its end torn off. `commit` never learns an interruption happened, exactly as
0022 predicted — the prediction held, it just needed the tail rebuilt.

`ActionResult.destination()` reads the `END` event rather than the route. Those agree for an
uninterrupted move and disagree for a truncated one, and the stream is the authority: `path`
describes what was *planned*.

`test_overwatch.gd` replays an interrupted stream from the pre-action state and compares every field
of every unit, both sides' contact lists, and `blocker_dyn`. That is the assertion the interrupt
machinery is safe to build on, and it was not writable before 0026.

Overwatch was built last, and deliberately. It is the only thing that needed both knowledge and
combat already working; debugging an interrupt whose trigger and whose consequence are both new is
how a week disappears.

`combat.overwatch_shots` is 1. A watcher that emptied itself into one move would make the second
mover of a turn free, which is the opposite of what 0003 wants from the mechanic.

Reaction fire carries `F_OVERWATCH` on every event of its chain, and takes `overwatch_hit_mult` — a
gunner reacting is not a gunner who chose the moment. Nothing else about resolution differs, which is
why overwatch needed no second copy of the combat rules.
