# 0007 — Tile-bound roads with cut and fill

## Context

Roads on a tile grid are usually one of two things: a free-floating spline that looks good and does
not line up with the tiles the rules use, or a tile flag that lines up perfectly and renders as a
staircase. Neither is acceptable here — the terrain is terraced and legible precisely because what
you see is what the rules see, and a road that cheats on that breaks the contract.

There is also a gameplay question. A road that is only a movement discount is a minor convenience.
A road that is the only low-gradient crossing of an escarpment is a piece of terrain worth fighting
over.

## Decision

**Representation.** A road is one segment per tile, defined by an entry edge and an exit edge.
It renders as a quadratic Bezier through the tile centre: control points are the entry edge
midpoint, the tile centre, and the exit edge midpoint. Adjacent tiles share edge midpoints exactly,
so the polyline is C0-continuous by construction — straight-through gives a straight line, a turn
gives a quarter arc.

**Routing.** A* over slope cost between map edges, reusing `sim/pathfinding/grid_astar.gd`. Routing
is **4-connected**: diagonal steps would need corner entries, which the entry-edge/exit-edge
representation cannot express and which would break Bezier joint continuity.

**Cut and fill.** After routing, the height profile along the polyline is relaxed until no
tile-to-tile step exceeds the configured maximum, then blended back into the terrain over a radius-2
corridor and re-quantized. Transitions in the corridor are re-classified.

Bridges are placed where a road meets a river. Villages go at junctions and crossings, with fields
around them.

## Consequences

- The road is on the grid, is smooth on screen, and is the same object to the renderer and the
  rules. No two representations to keep in sync.
- Cut and fill makes the road **emerge** as the only crossing of an escarpment rather than being
  special-cased. The router prefers gentle ground; where it has to cross steep ground, it carves a
  passage, and that passage is then genuinely the way through. This is a consequence of the
  algorithm, not a rule anyone wrote.
- Roads mutate `level` after quantization, so anything derived from `level` — transitions, the mesh
  chunks in the corridor, connectivity — must be recomputed locally afterwards. Stage order is
  load-bearing.
- 4-connected routing means roads never run diagonally. At 10 m tiles over 2 km this reads as a
  road with corners, which is what real roads on terrain look like; it is not a visible compromise.
- Villages flatten terrain inside their footprint, which can create or destroy an escarpment. They
  run before the final connectivity check for that reason.
