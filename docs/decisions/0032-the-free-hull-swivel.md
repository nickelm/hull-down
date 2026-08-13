# 0032 — The free hull swivel, and what it costs

## Context

A unit that has spent all its movement points and is facing the wrong way has nothing to decide. It
sits there presenting whatever plate it happens to be presenting until the next turn, and the player
watches it happen. That is a feel-bad with no play in it, and it is a common one — running out of
movement one tile short is the normal end of a move, not an edge case.

The obvious fix is free reorientation at zero cost. The obvious fix quietly deletes flanking.

If turning the hull is free and unlimited, every tank ends its turn facing whatever is most dangerous
to it, rear armour becomes unreachable, and the armour model stops being about position. 0004
rejected a health pool specifically so that manoeuvre would be the primary damage multiplier; a free
turn at the end of every activation hands that back.

## Decision

**One 45-degree hull step, free, once per turn — and it cancels overwatch.**

`turn.free_swivel_steps: 1` and `turn.free_swivel_per_turn: 1`, refilled in `begin_turn`. Legal at
zero movement points and legal for a unit already marked activated: being spent is the case this
exists for, so `SwivelAction.legality` deliberately does not refuse an activated unit.

One notch is enough to matter and not enough to save you. A tank caught side-on can present a front
corner; it cannot turn to face. The decision the player is left with is "which way do I finish", made
before they know what will happen — which is the decision worth having.

**It is its own action, not a `MoveAction` special case.** `find_path` prices every turn at
`turn_cost_per_45` and could never produce a zero-cost one. Teaching it to would corrupt the cost
model the movement overlay is drawn from, in order to express something that is not a route.

**The turret is dragged by the same rule a paid turn uses**, read from the same `clamp_turret`. A free
turn must not become a way to slew the gun that a paid turn is not.

**And it cancels overwatch.** This is the price, and without it the cap does not hold. A watching
tank could re-aim its ambush 45 degrees every turn for nothing, and 0003's "overwatch costs your whole
turn" would stop being a cost — you would pay once and adjust forever. The cancel is applied on the
free `TURN` event itself, not only on the `WATCH(-1)` that accompanies it, so the price is
unconditional even if some future caller forgets to emit the pair.

**Two cycling keys, not one.** Tab cycles units that still have orders left — the workflow key,
already built. The backtick walks the whole roster in fixed deployment order, spent units included,
and the roster panel lists everyone with click-to-select. Steel Panthers had both because they answer
different questions: "what should I be doing next" and "let me look at that one". A single key trying
to be both stops reaching half the force at exactly the point in a turn when you want to check on it.

## Consequences

`swivels_left` and `overwatch_dir` join `UnitState`, both cleared and refilled in `begin_turn`.
`overwatch_dir` survives the enemy's turn — that is when it fires — on the same lifecycle as
`fired_this_turn` and for the same reason.

The free `TURN` event carries `F_FREE`, and `value` holds the swivels **remaining afterwards** rather
than the one just spent. An absolute snapshot, because every arm of `EventApplier` has to survive
being applied twice (0026) and `-= 1` does not. The `WATCH` event does the same with its shot count.

A free swivel is silent to spotting: it costs no movement points, so `mp_moved` does not move and the
concealment ramp in 0024 does not widen. That is the right answer — a tank shuffling on the spot is
not the tank that sprinted across a field — and it falls out of the arithmetic rather than needing a
rule.

`ActionResult.Status` gains `NO_SWIVEL`. It is the ninth refusal reason and, like the other eight, an
enum that the controller turns into English; `sim/` still carries none.

The swivel is not woven. It enters no new tile, so a per-tile spotting check has nothing to run on,
and nothing about spotting depends on facing. If that ever stops being true — a facing-dependent
optics arc, say — the turn-boundary sweep is the backstop that would catch it.
