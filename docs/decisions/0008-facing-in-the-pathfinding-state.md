# 0008 — Facing in the pathfinding state

## Context

Armour is directional (0004), so the facing a tank arrives in matters as much as the tile it
arrives on. If pathfinding searches over tiles alone and facing is assigned afterwards by looking
at the last step, then turn costs are invisible to the search and the "optimal" path is not the
one the tank will actually pay for. Worse, the movement-range overlay becomes a lie: it shows tiles
as reachable that a tank cannot actually reach once turning is charged.

The spec (§4.12) requires turning to cost movement and reverse to be a distinct, costlier edge, but
does not say whether turning in place is legal.

## Decision

Search state is `(tile, facing)` — 200 x 200 x 8 = 320,000 states, packed as
`state = (tile_index << 3) | facing`.

Edges from a state:

| Edge | Condition | Cost |
|---|---|---|
| Turn in place | to facing ±45° | `turn_cost_per_45` |
| Forward | direction == facing | base step x terrain multiplier |
| Reverse | direction == `(facing + 4) & 7` | base step x terrain x `reverse_mult` (1.6) |

Turning in place is legal. Forward movement requires the facing to already match the direction of
travel, so a change of direction is paid for explicitly as turn steps.

Diagonal steps additionally require both adjoining orthogonal transitions to be passable
(no corner-cutting).

The heuristic is octile distance scaled by the cheapest terrain multiplier on the map. Turn-cost
lower bounds are deliberately **not** added to the heuristic without an admissibility proof — an
inadmissible heuristic here produces paths that are visibly not optimal and is a miserable bug to
track down.

## Consequences

- The branching factor is about four (turn left, turn right, forward, reverse) rather than eight.
  This is most of what makes the 320k-state search fit the frame budget; it is a performance
  decision as much as a modelling one.
- Reverse exists as a real option: backing off a crest without showing your rear armour is a
  tactical move the pathfinder will find on its own when it is cheaper than turning around.
- The movement overlay is honest. A Dijkstra flood fill over the same state space means every tile
  shown as reachable is reachable with the facing costs paid.
- Cost is integer throughout (base 10 orthogonal, 14 diagonal, terrain multipliers stored x10).
  Integer keys are what allow a bucket priority queue instead of a binary heap, which is another
  2-4x in GDScript.
- "Cannot fire the same turn" after a rough transition is computed **post hoc** from the
  reconstructed path (`PathResult.blocks_firing`), not carried in the search state. Putting it in
  the state would double the state space to buy a flag that iteration 1 only displays.
- The 50 ms overlay target holds for a realistic movement allowance and would not hold for a tank
  that can cross the map. If it is missed, the fallbacks in order are: 4 facings for the overlay
  only (keeping 8 for the committed path), then spreading the fill across frames. Dropping facing
  from the cost model is not a fallback — it reintroduces exactly the lie this decision removes.
