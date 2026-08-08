# 0002 — Square 10 m grid on a quantized heightfield

## Context

Tank tactics need a spatial representation that supports facing (armour is directional), line of
sight against relief, and legible movement costs. Hexes give uniform neighbour distance and six
facings; squares give eight facings, trivial array indexing, and terrain that reads as terrain
rather than as a board.

Terrain elevation could be continuous or quantized. Continuous height makes every threshold a float
comparison with an epsilon, and makes "is this edge passable" a question with a fuzzy answer near
the boundary.

## Decision

Square grid, 200x200 tiles of 10 m, over a heightfield quantized to 0.5 m. Eight facings. Euclidean
range for distance.

The gameplay heightfield is stored as **integer quanta**, not metres: `level: PackedInt32Array`,
where `height_m = level * 0.5`. The generation pipeline works at 800x800 / 2.5 m in floats and is
downsampled by exact 4x4 area averaging, then quantized once.

Tile-to-tile transitions are classified from the integer difference `dl`:

| `dl` | metres | Class |
|---|---|---|
| 0-2 | up to 1.0 | passable, normal cost |
| 3-4 | 1.0 to 2.0 | passable, extra cost, cannot fire the same turn |
| >= 5 | over 2.0 | escarpment, impassable |

## Consequences

- Passability is exact integer arithmetic. There is no "is 1.0000001 m passable" class of defect,
  and no epsilon to tune.
- The terraced look is not a stylistic layer applied to smooth terrain — it is the terrain. The
  mesh renders exactly what the rules see, so what the player reads off a crest is what LOS
  computes. This is the property that makes hull down legible without a tutorial.
- Quantization is lossy and irreversible. Anything needing sub-0.5 m precision must be read from the
  generation-stage `HeightField`, before quantization, not from `MapData`.
- Eight facings means diagonal movement, which means corner-cutting has to be explicitly refused
  (a diagonal step requires both adjoining orthogonal transitions to be passable).
- 200x200 = 40,000 tiles. Every per-tile layer is one `Packed*Array` of that length; the whole
  gameplay map is about 1 MB and serializes trivially.
