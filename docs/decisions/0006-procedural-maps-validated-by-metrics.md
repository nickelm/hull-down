# 0006 — Fully procedural maps validated by tactical metrics

## Context

Hand-authored maps are reliably good and do not scale. A campaign layer needs more battlefields than
anyone will author, and every authored map is a fixed puzzle that stops being interesting once
solved.

The standard objection to procedural maps is that they are tactically flat: noise produces terrain
that looks varied and plays identically everywhere. That objection is correct about *unvalidated*
procedural generation.

## Decision

Maps are fully procedural. No hand authoring, ever — not even a "hero map" for the tutorial.

Quality is enforced by measurement rather than by authorship. `tools/map_metrics.gd` computes, on
the generated map:

| Metric | Target |
|---|---|
| Sightline distribution (median unobstructed distance) | 300-900 m |
| Hull-down tile fraction | at least 5% |
| Chokepoints (vertex min cut between deployment zones) | 2-6 |
| Zone balance (hull-down count, mean elevation) | within 15% |
| Escarpment edge fraction | 3-15% |

Generation runs in a generate-measure-reject loop: seeds that miss the targets are discarded. Five
passing seeds are pinned as named regression maps — Ridge, Village, Steppe, Chokepoint, Sprawl.

Realism is a means, not an end. The pipeline uses hydraulic and thermal erosion and D8 hydrology
because eroded terrain has ridges, valleys, and drainage that produce *tactical structure* —
approaches, dead ground, crests worth holding. It is not there to look like a satellite photo.

## Consequences

- The metrics are the design document for terrain. Changing what makes a good battlefield means
  changing a target number, and the generator follows. That is a much shorter loop than re-authoring
  maps.
- Rejection has a cost: full generation is 1.5-4 minutes, so a batch of twenty is tens of minutes.
  `tools/gen_batch.gd` fans out across cores. Erosion is never cheapened for the batch, because
  erosion is precisely what drives the metrics being selected on.
- Any metric that is expensive to compute exactly gets an operational definition that is cheap and
  faithful, not dropped. See 0009.
- Repair before rejection wherever possible: connectivity is repaired by lowering escarpments along
  a minimum-earthwork path, and fords are forced if too few emerge naturally. Rejecting a seed is
  the last resort, because a rejected seed is minutes of erosion thrown away.
- Pinned seeds are a regression suite. If a generator change moves their metrics, that is a
  reviewable event, not a surprise.
