# 0027 — Hull facing and turret facing are different things

## Context

Iteration 1 gave a unit one `facing`. That was correct for a game with movement and no combat: the
only question a heading answered was which way the tank could drive, and 0008 put it in the
pathfinding search state on exactly that basis.

Combat asks two different questions of a heading and they have different answers.

**Armour is a property of the hull.** Which plate a shot strikes depends on how the tank is parked,
and that is the whole of the flanking game — 0004 rejected a health pool specifically so that
position would be the primary damage multiplier.

**Aim is a property of the turret.** What a tank can shoot at, and what an overwatch shot points
along, is where the gun is traversed to. Real tanks traverse turrets freely and quickly, and a game
where turning the gun costs the same as turning the vehicle is one where every tank drives everywhere
sideways.

With one facing those two are the same number, and the consequences are both wrong in the same
direction: presenting frontal armour means pointing your gun at whatever you are hiding from, and
laying an ambush means parking side-on to it.

## Decision

**`UnitState` carries `facing` (hull) and `turret`, and they are separate.**

`facing` is unchanged: it is what armour is computed from, changing it costs movement points at
`turn_cost_per_45`, and it stays in the pathfinding search state.

`turret` is an **absolute world bearing** in the same 0-7 numbering, free to traverse within
`combat.turret_arc_steps` (three steps, ±135°) of the hull.

**Absolute, not relative to the hull.** A relative turret swings with the vehicle, so laying an
ambush down a road and then turning the hull to present frontal armour would silently point the gun
at the sky. Overwatch aims at a *place*, and a rule where the place moves when you shuffle is a rule
nobody can plan around.

**The turret does not enter the pathfinding search state.** The cheap argument is cost: it would take
the search from 320k states to 2.56M, and 0008 already records the 320k version sitting on the frame
budget with "four facings for the overlay" as the fallback if it were missed. The real argument is
that there is nothing to search for. Traversing is free, so it never changes the cost of an edge; and
the entire turret track is a pure function of the hull track, because the clamp depends only on
`(previous turret, new hull)`. A linear walk reconstructs it. Searching over a derivable quantity is
searching for something you already know.

So the turret is **dragged**: `MoveAction._build_events` emits a `TURRET` event after any hull `TURN`
that pushes the turret outside the arc, moving it to the arc's nearest edge the short way round. That
is arithmetic on data `plan` already holds, so `plan` stays pure and the hover preview shows the gun
swinging before the player commits.

An exact reversal has no short way. The tie is broken anticlockwise, consistently, because a tie
broken differently on two runs is a determinism bug that only appears when a tank is ordered to turn
completely round.

## Consequences

`TankView.set_pose` takes both yaws and does the world-to-local subtraction for the turret child in
one place. The hull and turret were already separate `MeshInstance3D` nodes, so the view cost of the
split is that one function and an interpolation pair in `ActionPlayer` — which is the other half of
the argument for doing it now rather than after the AI reasons about it.

The visible consequence, and the one that makes the split legible with no label on screen: a hull
turning under a stationary turret. `ActionPlayer`'s `TURN` arm deliberately leaves `_to_turret_yaw`
alone, and the turret traverses at its own faster rate when it does move.

`UnitState.can_bear_on` asks about the **hull**, not about where the turret currently points.
Traversing inside the arc is free and unlimited, so everything in the arc is already aimable; making
the answer depend on the current bearing would mean it changed according to what the tank last looked
at, which is not a rule anyone could hold in their head.

`combat.turret_arc_steps` is global rather than per-unit. A per-unit override is a one-line `get` on
the unit's data block on the day a vehicle needs one, and inventing the field before then would be a
tunable nobody tuned.

There is deliberately no cost, no limit and no action price on aiming. The turret is free; the hull
is what you pay for. Overwatch is the one place a bearing is committed to in advance, and it is
priced by costing the unit its turn (0003) rather than by charging for the traverse.
