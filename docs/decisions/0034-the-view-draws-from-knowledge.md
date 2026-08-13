# 0034 — The view draws from knowledge, never from ground truth

## Context

The simulation has had full fog of war since 0024. `Spotting` decides who sees whom deterministically,
`SideKnowledge` holds one contact list per side, `MatchState.contact` flattens it for drawing, and
`SPOT` / `LOST` events are woven into movement streams per tile entered (0025). All of it is covered
by `tests/test_spotting.gd` and `tests/test_knowledge.gd`.

None of it reached the screen. `game/main.gd` built one `TankView` per entry in `MatchState.units` and
`TankView` kept a live `UnitState` reference, posing itself from `state.tile`, `state.facing` and
`state.turret`. Nothing anywhere in `game/` ever set `visible = false`. `MatchState.contacts()` —
documented in its own docstring as "what the roster panel and the ghost markers draw" — had zero
callers outside the tests.

So every enemy tank was on screen at full opacity from the first frame, and the entire spotting model
was decoration. Firing was gated on `k.sees(target)` while the target you could not shoot at was drawn
in front of you.

It was worse than a missing feature, because the pieces all existed and looked done. The gap was not
in any one function; it was that no function owned the question.

There were three further leaks that had nothing to do with the tank meshes, and they matter because
they show the shape of the problem: hovering blank ground popped an unspotted tank's card, complete
with armour by facing and rounds remaining; the tile readout appended `[side 2 unit]`; and clicking an
unspotted enemy refused with "nothing of yours can see that", which is a sentence that only makes
sense if something is there.

## Decision

**A pure function in `sim/` decides what may be drawn, and `game/` has no discretion.**

`ViewState` answers three questions and `game/` asks all three rather than deriving any of them:

- `of(state, viewing_side, unit)` → `HIDDEN` / `OWN` / `SEEN` / `GHOST` / `WRECK`
- `pose(state, viewing_side, unit)` → where to draw it, choosing between `UnitState` and `Contact`
- `filter(events, mask, viewing_side)` → the subset of an action stream that side may watch

The reason it lives in `sim/` and not in `game/` is testability, and it is the whole argument. The
acceptance criterion for this work is "an unspotted enemy is absent from the rendered scene", and a
rendered scene cannot be asserted headlessly. A decision that cannot be tested is one that drifts
back. `tests/test_view_state.gd` is that criterion, written as assertions.

Three supporting rules follow from it.

**`TankView` holds no `UnitState`.** Not "does not currently read one" — does not have one. While the
reference existed, the leak was one line away forever, and the file's own history says that is not
hypothetical. `setup` takes plain values; poses are pushed in by `PlayerController`, which owns the
`MatchState` and is the one place entitled to turn knowledge into a position.
`tests/test_determinism.gd` scans `game/` for a stored `UnitState` and for the `.state.field` pattern
the old reference produced, the same way it already scans `sim/` for unseeded randomness.

**The replay is filtered before it plays, not while it plays.** `ActionPlayer` was already built to
hold no simulation reference (0022), so the one way it could leak a position was by being handed one.
`play(result, events)` takes the filtered stream as a separate argument rather than reaching for
`result.events`, because a defaulted argument is one a call site can forget. A visibility branch
inside the replayer would instead be a rule that has to stay right in four `match` arms forever.

**The mask is snapshotted before the action resolves.** Resolving mutates knowledge — that is what
`SPOT` events are the account of — so a mask taken afterwards says every unit the action revealed had
been visible all along, and the filter passes the whole stream through. This fails silently and it is
the single easiest thing to get wrong here, so `tests/test_replay_filter.gd` pins the ordering, and
`ActionQueue` carries each filtered stream alongside its result rather than filtering at playback.
That last point is not fastidiousness: an AI side resolves its whole turn before a frame is drawn, so
playback-time filtering would be wrong by construction for every action after the first.

**A wreck is terrain, and always drawn.** `Spotting.can_see` refuses dead units, so a destroyed tank's
contact goes ghost and then cold two turns later — while `MapData.blocker_dyn` (0031) goes on feeding
*every* side's line of sight with no knowledge gate anywhere in `Los`. Gating the visual on knowledge
would make a burning hulk wink out while it still blocked sight lines, which is the view disagreeing
with the model: the exact failure this record exists to close, reintroduced by being careful.

## Consequences

The board flips at hand-over. `PlayerController.viewing_side` tracks the active side in hot-seat, so
each player sees only what their own side has earned and what the last player had spotted goes away.
That variable is also the seam 2e needs: with an AI side it simply stops tracking.

`ActionPlayer._finish` no longer snaps units from `UnitState`. The reconcile that made a skipped
replay unable to desynchronise view and simulation still happens — one layer up, in the `finished`
handler, from `ViewState`. The 0022 guarantee was a convention about `setup`'s argument list; it is now
true of the whole file.

`ActionPlayer.play` used to `return` on an empty stream without emitting `finished`, contradicting its
own docstring. Survivable while every stream was replayed whole; a hung UI the moment an enemy can
move somewhere the player cannot see. Fixed here because filtering makes empty streams routine.

Two bugs surfaced that predate this work and were never seen because the game layer had never been
played. `_apply` posed `_view_for(ev.unit)` from interpolation state belonging to the *acting* unit, so
a woven overwatch shot drew the ambusher standing on the mover's tile. Reactions now keep the pose
knowledge gave them.

**A known limit, stated rather than papered over.** `MatchState.occupancy` is ground truth and the
pathfinder uses it, so a route that bends around an empty-looking tile still tells the player something
is there, and an `OCCUPIED` refusal on a tile with nothing visible on it is now reworded but still a
refusal. The wording is fixed here; the routing is not. Solving it properly means a per-side occupancy
overlay, which changes what a legal move *is* and wants its own record.

`look.marker.show_bars_for_idle_side` is deleted. With bars drawn for own units only it had no meaning
left, and 0014's rule cuts both ways — config nothing reads is as much a liability as state nothing
reads.
