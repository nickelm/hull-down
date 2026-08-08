# 0011 — Roads as a link layer, not a terrain type

Supersedes the **Representation** section of [0007](0007-tile-bound-roads-with-cut-and-fill.md).
Everything else in 0007 — 4-connected routing, cut and fill, bridges, villages at junctions — stands.

## Context

0007 defined a road as one segment per tile: an entry edge and an exit edge, stored as
`MapData.road_entry` and `MapData.road_exit`, one byte each. Stamping also set
`terrain[i] = TerrainTyper.Type.ROAD`.

Both halves of that turned out to be wrong, and in ways that were visible on screen the first time
anyone looked at a generated map.

**One segment per tile cannot represent a crossing.** `roads.count` is 2 and `SettlementPlacer`
looks for junctions of degree 3 or more — so crossings are not an edge case, they are a design
goal. `RoadBuilder._stamp` runs once per road and *overwrites* both bytes, so where two roads meet,
the second road wins and the first road's segment through that tile is silently erased. The
neighbours on either side still curve toward a tile that no longer draws anything. The same
overwrite produces tiles holding one road's entry and another road's exit, which renders as half a
turn heading nowhere. There is no assignment of two bytes that expresses four connected edges.

**Terrain type is the wrong slot for a road.** A road is a surface laid *on* ground, not a kind of
ground. Overwriting `terrain[i]` destroyed the information that the tile was field, or woods, or
scrub — so the renderer, which colours from `terrain[i]`, drew a grey ribbon on a grey tile with no
landscape under it. It also meant every consumer asking "is this a road" and "what is this ground"
had to ask the same byte, and only one of them could get an answer.

## Decision

**Connectivity is a bitmask.** `MapData.road_links: PackedByteArray`, one byte per tile, bit `d`
set when the tile's road connects to its neighbour in direction `d`. Stamping ORs bits in rather
than assigning, so a tile crossed by two roads ends up with degree 4 and both roads stay whole.
Endpoints that run off the map set their outward bit, so the ribbon reaches the boundary.

Links are **symmetric by construction and by test**: if tile A links in direction `d`, tile B at
`neighbour(A, d)` links in `opposite(d)`. Routing stays 4-connected, so only the four orthogonal
bits are ever set.

**Roads are a layer over terrain, not a terrain type.** `terrain[i]` keeps the natural type.
`has_road(i)` is `road_links[i] != 0`. The `road` row in `data/terrain.json` stays where it is —
the array order is load-bearing against the `TerrainTyper.Type` enum — but is reinterpreted as a
*modifier*: where `has_road(i)`, the road's `move_cost` replaces the terrain's and `blocker_h`
drops to zero. `TerrainTyper.Type.ROAD` is never assigned to a tile.

## Consequences

- Junctions, crossroads, dead ends and multi-road overlap are all representable, and the renderer
  can distinguish them: degree 2 draws the Bezier arc 0007 specified, degree 1 draws a stub with a
  cap, degree 3 or more draws a hub at the tile centre with a stub per link.
- The map keeps its landscape under its roads. A road through woods reads as a road through woods.
- Two questions that were competing for one byte now have separate homes, and every
  `terrain[i] == ROAD` test in the codebase becomes `md.has_road(i)`.
- `MapCodec.VERSION` goes to 2. Two byte arrays become one, so `MapData.content_hash()` changes for
  every map, and cached maps under `user://maps` regenerate on next load. This is a cache, not an
  archive; that is the mechanism 0007-era code already relied on.
- Suppressing tree instances on road tiles becomes a `has_road` test rather than something the
  terrain type could no longer answer.
- The C0 continuity argument in 0007 was necessary but not sufficient: adjacent tiles sharing an
  edge midpoint keeps the *centreline* continuous, but the ribbon has width, and extruding each
  sample independently leaves a notch at every joint. The builder now carries a mitred
  cross-section along the polyline and forces the cross-section at a tile boundary to be
  perpendicular to the crossing edge — which both neighbours compute identically from local data,
  so the seam is exact without either tile knowing about the other.
