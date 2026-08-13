# 0025 — Spotting is checked per tile entered

## Context

0024 settled what spotting *is*. This settles **when it runs**, which turns out to be the harder half.

The cheap implementation is a sweep at the start of each turn: recompute every side's contacts, emit
whatever changed, carry on. It is correct in the sense that the contact lists end up right, and it is
useless for everything built on top of it.

A tank drives eight tiles, crosses a ridge on the fourth, and is in cover again by the eighth. A
turn-start sweep sees the start and the end and reports nothing happened. What actually happened is
that it was visible, briefly, on one tile — and that is precisely the moment overwatch fires, the
moment the player needed to see a contact marker appear, and the moment an AI would have wanted to
react to.

Worse, a sweep cannot answer **where**. Overwatch is an interrupt at a *place*: the defender's shot
happens when the mover reaches a particular tile, not before it sets off and not after it arrives.
Building the reveal on a mechanism that has no concept of "during" means building overwatch on a
second, different mechanism later, and then having two answers to "can this side see that tank".

## Decision

**Spotting is rechecked after every `STEP`, for both sides, and the changes are events in the
movement stream.** `ActionResolver._weave` walks the planned events, applies each one as it appends
it, and calls `Spotting.recompute_side` per step.

The order within a step is fixed, and it is a rule rather than an implementation detail:

```
STEP  ->  spotting recheck, both sides  ->  overwatch trigger  ->  truncation test
```

**Spotting before overwatch, unconditionally.** A watcher cannot shoot at something it has not seen,
and the reveal has to precede the tracer *in the stream* so the presentation layer can put a contact
marker down before a round comes out of it. A test pins the ordering rather than a comment asserting
it.

**Both sides every step.** The asymmetry from 0024 means a mover cresting a ridge can *gain* contacts
as well as give itself away, and both are things that happened. Only checking the moving side's
visibility to the enemy would make driving into an ambush silent for the driver.

**The turn-boundary sweep stays.** It is idempotent, it costs nothing next to a hand-over, and it
catches a contact that changed for a reason no event described — a unit removed, a wreck appearing, a
rule edited between saves. A test asserts the sweep agrees with what the weave already decided, which
is what stops the two becoming two answers instead of one answer and a check.

**`MoveAction.close_stream` is extracted**, and the weave rebuilds the tail rather than carrying the
planned one through. That is what makes truncation work in 0030 without a special case: an
interrupted stream is a complete, self-consistent account of a *shorter* move, whose `END` names the
tile the tank really stopped on.

**A reveal is emitted once.** `SideKnowledge.mark_seen` reports *news*, not truth, so driving along in
plain view produces no events at all. Without that, every step of every move would carry a reveal for
every enemy already visible, and the marker would flash on each one.

## Consequences

`ActionResult.destination()` and `final_facing()` now read the `END` event rather than the route.
Those agree for an uninterrupted move and disagree for a truncated one, and the stream is the
authority — `path` describes what was *planned*, which after 0026 is no longer the same claim.

`recompute_side` mutates and *then* the weave records what it did, rather than the event being the
thing that changes the model. That is deliberate: it keeps the rule in one place. The `SPOT` and
`LOST` arms of `EventApplier` are idempotent precisely so both readings work — replaying the finished
stream from the pre-action state reproduces the knowledge, and replaying it over the live state does
nothing.

The old `test_planning_and_resolving_agree_in_iteration_one` is amended, exactly as its own docstring
said it would have to be. Planning and resolving now legitimately differ, and the sharper claim
replaces it: they must differ *only* by the reactions, and what the tank itself did has to be
identical — or the preview the player committed to was not the move they got.

`PlayerController.prime_knowledge()` runs at setup. Without it the first order of the match would
emit a reveal for every enemy that was already in plain view at deployment, all attributed to
whichever unit happened to move first.

The cost is `O(observers x targets x line-of-sight)` per tile entered. At three a side that is
nothing. At the spec's "dozens per side" it is wrong, and the fix is a per-observer cached
`VisionField` invalidated on that observer's move — `VisionField` already does a whole board in about
10 ms by radial sweep. Noted, not built.
