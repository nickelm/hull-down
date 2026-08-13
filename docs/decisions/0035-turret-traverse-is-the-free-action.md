# 0035 — Turret traverse is the free action; the hull swivel is withdrawn

Supersedes 0032.

## Context

0032 identified a real problem and solved it in the wrong place.

The problem stands exactly as it was written: a unit that has spent all its movement points and is
facing the wrong way has nothing to decide, and running out of movement one tile short is the normal
end of a move rather than an edge case. That is a feel-bad with no play in it.

0032's answer was one free 45° step of **hull**, once a turn, priced by cancelling overwatch. It saw
the danger — "if turning the hull is free and unlimited, every tank ends its turn facing whatever is
most dangerous to it, rear armour becomes unreachable, and the armour model stops being about
position" — and tried to contain it with a cap and a price rather than avoid it.

Containment held, mostly. But the free step still let a tank adjust the plate it presents *after*
seeing the board, which is a smaller version of the thing 0004 rejected a health pool to prevent. And
the price was strange on inspection: a rule about hull rotation was paid for out of the overwatch
system, which is a coupling with no physical reading. The two are related only by both being things a
stationary tank does.

Meanwhile the actual free action a tank has was not implemented at all. 0027 gave `UnitState` a
separate absolute `turret` bearing and `docs/hull-down-v2.md` 2b says plainly that "hull facing costs
movement; turret rotation is free" — but nothing could traverse the gun. The turret was moved only as
a side effect of firing, of laying overwatch, or of being dragged by a hull turn. A player had no way
to point the gun at anything without committing to shooting at it.

And 2c asks for the opposite of what was built: *a unit at 0 AP can rotate its turret but not its
hull*.

## Decision

**Traversing the turret is free, unlimited within the arc, and legal at zero movement points. The free
hull swivel is withdrawn.**

`TurretAction` takes an **absolute** bearing, because that is what `UnitState.turret` stores and what
`Overwatch` lays along (0027). A relative order would have to be resolved against the current bearing
somewhere, and doing that at the call site is how the two drift; the keypress is relative and
`PlayerController` resolves it once.

**Uncapped, deliberately.** A per-turn allowance would be arithmetic in search of a reason. The bound
already exists and is physical: `combat.turret_arc_steps` is ±135° from the hull, a property of the
mounting, and within it a crew traverses as often as it likes in the time a turn represents. What is
scarce is hull rotation, and that has a price already — the movement points a turn costs. So
`data/rules.json` carries no allowance to tune, only the size of one keypress.

This makes the split clean in a way 0032's never was. **What you present to a gun is settled by where
you drove.** Armour facing is a consequence of manoeuvre and only manoeuvre; the gun is free to look
wherever the mounting allows. A tank caught side-on stays caught side-on, and can still shoot back.

**Traversing re-lays overwatch rather than cancelling it.** 0032's cancel was a price, and with the
free hull turn gone there is nothing left to charge for. What remains is a consistency requirement
pointing the other way: the bearing a unit watches down *is* where its gun points, so moving one must
move the other or the two disagree, which would be a bug rather than a cost. Free re-aiming buys
nothing anyway — orders are issued only on your own turn, so adjusting between laying the ambush and
ending the turn tells you nothing you did not know when you laid it.

## Consequences

`SwivelAction`, `UnitState.swivels_left`, `turn.free_swivel_steps`, `turn.free_swivel_per_turn` and
`ActionEvent.F_FREE` are all deleted. `Z` and `X` traverse the gun instead of turning the hull, and the
`EventApplier` `TURN` arm loses its free-turn branch — the only `TURN` events left are ones somebody
paid for, which is simpler than it was.

`ActionResult.Status.NO_SWIVEL` is **retired in place** rather than reclaimed. `status` is the first
field `ActionResult.fingerprint()` writes, so renumbering would silently change the meaning of every
recorded fingerprint — the same argument `ActionEvent.Kind` makes for appending and never inserting.

An order to lay the gun where it already points is refused with `SAME_TILE` rather than emitting a
zero-length stream, for the reason that status exists on a move: an order that changes nothing should
not produce an account of having happened.

Traversing is silent to spotting. It costs no movement points, so `mp_moved` does not move and the
concealment ramp in 0024 does not widen — and unlike the free swivel this now falls out of the event
kinds themselves rather than out of the arithmetic, because a `TURRET` event never reaches the arm
that feeds `mp_moved`.

Not woven, for 0032's reason and one stronger one: traversing enters no new tile, and nothing about
spotting depends on where a gun points at all.

The two cycling keys 0032 introduced are unaffected and its argument for them stands — Tab for "what
should I be doing next", the backtick for "let me look at that one". The roster panel it promised is
built in this batch, under 0034's rules about what a panel may list.
