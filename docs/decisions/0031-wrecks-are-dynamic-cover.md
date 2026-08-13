# 0031 — Wrecks are dynamic cover on a static map

## Context

A destroyed tank has to go somewhere. Removing it from the board is the cheap option and it throws
away the best thing about a game whose damage is monotone: the battlefield should be readable as a
history of what happened to it.

Leaving it there costs almost nothing and makes the ground evolve. The tile stays blocked, so a
burnt-out tank in a gap is a gap that is now closed, and the fight has to go somewhere else. That is
a rule worth having for the price of one array.

The problem is where the array goes. `Los.classify` and `VisionField.compute` are the two hottest
functions in the game and neither has a `MatchState` — `VisionField` computes a whole board's
exposure in about 10 ms by radial sweep, which is the only reason the visibility overlay is
interactive. Threading a unit list into either of them would cost that.

## Decision

**`MapData.blocker_dyn`, one float per tile, summed into `blocker_top_m`.**

```gdscript
func blocker_top_m(i: int) -> float:
    return float(level[i]) * quant + blocker_h[i] + blocker_dyn[i]
```

Wrecks reach `Los`, `VisionField` and the sightline metric with **no signature change anywhere** and
one extra array read in a loop that already does two. Nothing that draws or measures line of sight
was touched.

**`blocker_dyn` is match state, not map content.** It is excluded from `MapData.content_hash()` and
from `MapCodec`. Destroying a tank must not change what map you are playing on, and if it did, every
pinned seed in `tests/test_pinned_seeds.gd` would move the first time anything died. A test asserts
the hash is unchanged after a kill.

**A wreck's cover is 2.0 m: above the hull line (1.4) and below the turret line (2.6).** That is the
same threshold `woods_light` is chosen against in 0016, and it is chosen for the same reason. Below
the hull line it is decoration that blocks nothing; above the turret line it is an opaque wall, and
destroying a tank would blind everyone behind it — which would make killing something a way to
create cover for the enemy. Between the two, a wreck conceals a hull and leaves a turret. **A burning
tank is a hull-down position**, and that is a rule rather than an accident.

**A wreck is terrain, not a unit.** `alive` goes false; `MatchState.side_units` and `is_selectable`
and `remaining_on_side` stop returning it; `Spotting` stops seeing it and `FireAction` refuses it as
a target. `unit_at` and `occupancy` go on reporting it, because the tile is still blocked. It stays
in `units` at its own index — identity is positional, and compacting the array would renumber every
contact every side holds.

## Consequences

`MatchState.side_roster(side)` is added alongside `side_units`, returning the dead as well, for the
roster panel and for counting losses.

The visibility overlay picks wrecks up for free, because it goes through `VisionField`, which goes
through `blocker_top_m`. Nothing had to be told about them.

A wreck cannot hold an objective (0031 meets `docs/design/rules.md` §6): it blocks ground without
garrisoning it, which is the distinction between denying a tile and taking one.

`blocker_dyn` is written only by `EventApplier`'s `DESTROYED` arm, and that arm is idempotent — it
checks `alive` before acting, so replaying a stream that contains a kill does not stack cover.

The obvious extension is that other things could write this layer: burning terrain, smoke, a
demolished building. None of them exist and none of them are designed here. What this record fixes is
that when they do arrive, they arrive as values in an array that already reaches every sight test,
rather than as a second mechanism.
