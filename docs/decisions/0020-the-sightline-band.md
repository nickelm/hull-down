# 0020 — The sightline band, and what actually sets it

Supersedes the sightline target in [0006](0006-procedural-maps-validated-by-metrics.md) and the
sightline section of [0009](0009-operational-definitions-for-the-metrics.md).

## Context

§4.11 asks for a sightline median between 300 m and 900 m. **No seed the generator has ever produced
has met it.** The journal has carried this as the open question across three sessions, with the
standing diagnosis that woods stand 8 m over about 17% of the map, so a ray meets one every ~70 m.

That diagnosis was right about the cause and wrong about the remedy. It concluded that a 300 m median
"needs woods nearer 3%, which is a different kind of map", and left it there. Two measurements in
this batch say otherwise.

**First: cover height is a threshold, not a dial.** `Los.clear_range` blocks when a tile's cover
clears the observer's eye line, and the eye sits at ground plus `turret_h_m` (2.6 m). Cover at 3 m
occludes exactly as thoroughly as cover at 8 m; cover at 2.2 m blocks nothing at all. So forest can
be made transparent without removing any of it, which [0016](0016-forest-tiers-and-a-second-source-of-impassability.md)
does with a light tier at 2.2 m. Over twenty seeds at shipping settings that moved the median from
**113 m to 141 m**.

**Second, and this is the finding that decides the record: forest is no longer the limit.** Pushing
the split further — opaque stands from 55% of the forest down to 20%, so that under 4% of the map
carries sight-blocking cover — moved the median only **141 m to 150 m**. If forest were still
dominant, 3.4% coverage would predict a mean free path near 290 m. It measures 150. Roughly half the
blocking is now **ground**, and no amount of thinning the woods will reach 300 m.

The ground is not negotiable either. [0013](0013-how-dramatic-the-terrain-can-be.md) fixed
`target_relief_m` at 65 m, and fixed it *against the escarpment band* — 3–15% of edges impassable,
from 0009 — which caps relief around 65–70 m. So the sightline target and the escarpment target are
in direct tension, and satisfying the first by flattening the map would break the second. 0013
anticipated this exactly: "if more drama is wanted, the decision to revisit is 0009's band."

## Decision

**The band moves to 120–400 m.** It is a measurement of the terrain the rest of the design has
already committed to, not a target the terrain failed to hit.

The 300–900 m figure was written before anything had been measured, and it describes open steppe.
What 65 m of relief, 17% woodland and a 10 m tile actually produce is a median around 140 m with a
long upper tail — country where a ridge or a wood is usually within a few hundred metres, and where
the long shot exists but has to be positioned for. That is a defensible battlefield and arguably a
better one than a billiard table: it is what makes hull-down positions worth the trouble.

**What is explicitly not done.** The statistic is not touched. Reporting a q3 instead of a median,
or excluding forest tiles from the sample, would move the number without moving the terrain, and it
would poison every comparison made against a pinned seed afterwards. 0009 already redefined this
metric once, and it did so because the literal reading measured *the size of the map* rather than
the terrain. That is not the situation here: the ray-march median is measuring exactly what it
claims to. Only the target was wrong.

## Consequences

- The generator is measured against what it builds. Whether the resulting engagement ranges are the
  *game* anyone wants is a separate question, and it is now a live one: `units.json` sights the
  medium tank's optics to 1150 m against a map whose median clear view is 141 m. Either the optics
  are aspirational or the maps are close country. Iteration 2 has to pick, and this record is the
  measurement it should pick from.
- Reaching the old band would need `target_relief_m` well below 65 m, which breaks 0009's escarpment
  floor and undoes 0013. The two bands cannot both be satisfied; this one gave way because it is the
  one that was never measured.
- The forest tier split stays at 45/37/18 rather than the thinner mix trialled here. The extra
  thinning bought 9 m of sightline and cost the map most of its real woodland, which is a bad trade
  once forest is not the binding constraint.
- **This unblocks pinning but does not make seeds pass.** Zone imbalance still fails on 17 of 20
  seeds at a median of 37% against a 15% limit, and that has nothing to do with sightlines —
  `place_zones` scores candidate pairs for balance and the spread runs 2.7% to 81%, which is a
  lottery rather than a guarantee. It needs its own investigation and probably its own record.
