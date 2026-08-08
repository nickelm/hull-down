# Hull Down — rules of record

This file is the source of truth for game rules. Where it disagrees with anything else, this wins.
Every number cited here lives in `data/`, not in code; the values shown are the current defaults.

**Iteration 1 fills in movement, line of sight, and exposure only.** Combat sections are stubs
marked *iteration 2* and are not implemented.

---

## 1. Space and time

The battlefield is 200 x 200 tiles of 10 m — 2 km square. Elevation is quantized to 0.5 m and
stored as integer quanta; `height_m = level * 0.5`.

Each tile has one terrain type, one elevation, and optionally water, road connections, and a
deployment-zone or objective marker.

A road is a **layer over** the terrain, not a terrain type: the tile keeps its natural ground and
carries a bitmask of the edges its road connects to, so crossings and junctions are representable
and a road through woods is still a woods tile. Where a road runs it sets the movement cost and
removes the tile's line-of-sight cover. See `docs/decisions/0011`.

Distance is Euclidean. Direction is one of eight: N, NE, E, SE, S, SW, W, NW, numbered 0-7
clockwise from north.

Turns alternate by side. A side activates all of its units in any order. Each unit has two actions.

*(Iteration 1 implements the side-alternating structure with two units a side, hot-seat, and a
movement-point budget as the only limit — see `docs/decisions/0012`. The two-actions-per-unit rule
waits for iteration 2, since both actions are combat and there is no combat yet.)*

---

## 2. Movement

### 2.1 Cost

Movement is spent in integer cost units. A tank has a movement allowance (`default_mp`, 220).

| Component | Cost |
|---|---|
| Orthogonal step | 10 |
| Diagonal step | 14 |
| Turn, per 45° | 3 |

The step cost is multiplied by the **destination tile's** terrain multiplier:

| Terrain | Multiplier |
|---|---|
| Road | 0.6 |
| Open, field | 1.0 |
| Scrub | 1.2 |
| Village | 1.4 |
| Rock, ford | 1.6 |
| Woods | 1.8 |
| Marsh | 2.2 |
| Water | impassable |

### 2.2 Facing

A tank always has a facing. Facing is part of its state, and part of the pathfinding search state
(decision 0008).

- **Forward** movement requires the facing to already equal the direction of travel.
- **Turning in place** is legal and costs 3 per 45°.
- **Reverse** movement is a distinct edge to the tile directly behind the tank
  (facing + 180°), at 1.6x the step cost, with no turn.

A change of direction is therefore always paid for explicitly.

### 2.3 Transitions

Passability is determined by the integer elevation difference `dl` between adjacent tiles:

| `dl` | Height change | Class | Effect |
|---|---|---|---|
| 0-2 | up to 1.0 m | Normal | normal cost |
| 3-4 | 1.0-2.0 m | Rough | +8 cost; **cannot fire this turn** |
| 5+ | over 2.0 m | Escarpment | impassable |

A diagonal step is legal only if **both** adjoining orthogonal transitions are also legal. Tanks do
not cut corners between two escarpments.

Every deployment zone can reach every objective. This is guaranteed at generation time by lowering
escarpments along a minimum-earthwork path; a map that cannot be repaired is rejected.

*Iteration 1 note:* the rough-transition firing restriction is computed and displayed
(`PathResult.blocks_firing`) but has no mechanical effect, because there is no firing yet.

---

## 3. Line of sight and exposure

### 3.1 Geometry

Terrain is piecewise constant per tile — a tile has one height across its whole area. LOS samples
tile heights directly. It does not interpolate, because the mesh does not interpolate: what the
player sees on a crest is exactly what LOS computes.

Two reference heights on a tank, both measured from the ground of its tile:

| | Height |
|---|---|
| Hull top | 1.4 m |
| Turret (optics and gun) | 2.6 m |

Some terrain carries opaque cover above ground level, which blocks LOS through the tile but not
from it:

| Terrain | Blocker height |
|---|---|
| Woods | 8.0 m |
| Village | 6.0 m |
| Everything else | 0 |

A tile never blocks line of sight originating on itself.

### 3.2 Exposure states

An observer looks from its turret height. It evaluates two rays to the target tile — one to the
target's hull top, one to the target's turret. The result is one of three states:

| State | Turret visible | Hull visible | Meaning |
|---|---|---|---|
| **Exposed** | yes | yes | the whole tank can be hit |
| **Hull down** | yes | no | the tank can see and shoot; only its turret can be hit |
| **Masked** | no | no | no line of sight |

Hull down is the game's title and its central position. A crest that is at least 1.4 m and less than
2.6 m above your tile, with ground falling away beyond it, gives you a shot the enemy cannot answer
in kind.

Exposure is symmetric in geometry but not in consequence: two tanks both hull down to each other
are both firing at turrets, which is a different fight from two tanks in the open.

### 3.3 Spotting — *iteration 2*

Spotting is deterministic: line of sight plus a range threshold, modified by the observer's optics,
the target's terrain (a spotting multiplier per type), and the target's recent movement and firing.
There is no spotting roll.

Units that were seen and are no longer seen leave ghost markers at their last known position,
decaying over turns.

*Iteration 1 implements the LOS and exposure layer only. Spotting ranges are defined in
`data/terrain.json` and `data/units.json` but not consumed.*

---

## 4. Combat — *iteration 2*

Resolution is two rolls, in order.

1. **To hit** — a percentage from range, exposure state, observer movement, and optics. Firing or
   going on overwatch ends the unit's turn regardless of remaining actions. Reloading is automatic
   and free.
2. **Penetration** — the round's penetration at that range against the plate thickness of the facing
   actually struck. Facings are front, left, right, rear, and top.

**There are no null results.** A hit that fails to penetrate still shreds armour (permanently
reducing that facing's thickness) or shakes the crew (a temporary penalty). A player who set up a
flank and hit has made progress even on a bad penetration roll.

Armour never regenerates. Damage is monotone — the state of the board is readable as a history of
what happened to it.

Criticals in iteration 2 are limited to two components: immobilised and gun damaged.

---

## 5. Randomness

Every random draw in the simulation comes from a named seeded stream (decision 0005). There is no
global RNG in `sim/`.

Reloading a save and repeating the *same* action gives the *same* result. Reloading and doing
something *different* gives a different result. You can undo a plan; you cannot reroll a die.

---

## 6. Victory — *iteration 2*

Hold objectives to win. Objectives are placed at generation time and are reachable from every
deployment zone.
