# 0040 — Objectives are features, and outcomes are graded

## Context

2e-iii asks for victory points on generator features — villages, bridges, crests — capture by
occupancy, a graded outcome from points plus kill and loss ratio, and a turn limit. Until now
objectives were bare high ground chosen early in the pipeline, before a single road was routed or
village stamped, because in iteration 1 they existed only as connectivity anchors. And `Victory`
was binary: a winner or nobody, which cannot express "the attack failed but bled the defender
white" — the outcome the dig-in scenario (2f) is *about*.

## Decision

**Placement moves to the end of the pipeline and reads the features.** `place_objectives` now runs
after roads and settlements and before the connectivity repair (which still needs objectives as
its anchors). Three pools — village tiles scored by road degree, bridge tiles scored toward
mid-span, crest tiles scored by elevation as before — are taken round-robin, best-first, under the
existing separation constraint with its halving fallback. Round-robin rather than a single merged
ranking, because the point is variety: a map with all three features fields all three kinds, and a
map without villages degrades to bridges and crests rather than to nothing.

**Values follow contestedness: village 3, bridge 2, crest 1** (in `victory.*`, like every other
number). A village is cover, a road hub and a close-range trap at once; a bridge is a chokepoint;
a crest is just ground. `MapData.objective_value` rides parallel to `objectives`, enters the
content hash and the codec (version 3), and `objective_worth()` answers 1 wherever the array is
missing — a hand-built fixture's objectives must read as plain, never as worthless.

**Grades are a signed five-step ladder** — decisive defeat (-2) to decisive victory (+2) — so one
side's grade is *definitionally* the negation of the other's; two independently computed grades
could disagree, and a debrief screen that says both sides lost marginally is not a rule anyone
wrote. The margin compares `points_held x grade_vp_weight + kills x grade_kill_weight` across
sides; thresholds `grade_marginal` and `grade_decisive` cut the ladder. Points count *current*
possession, not `hold_turns` — grading asks where the line stands when time runs out, while the
hold requirement belongs to the outright win, which is a different question deliberately left
unchanged (hold enough objectives long enough, or annihilate).

**An outright winner is clamped to at least marginal victory,** and its enemy to at most marginal
defeat. A side that met the victory condition has won whatever the arithmetic of corpses says.

**The turn limit lives in `victory.turn_limit` and ends the match rather than deciding it** —
`Victory.over` says the clock ran out, `Victory.grade` says what that means, and a scenario may
pass its own limit (2f). `MatchRunner.play` defaults to the config's.

## Consequences

- Every generated map's objectives move, so every map's `content_hash` changes and cached
  `.hdmap` files regenerate (codec version bump). The pinned-seed metrics are unaffected — none
  of the seven pinned metrics reads objective positions.
- `MatchRunner.summary` now carries `grade_N` and `points_N` per side; the 2e-ii batch gains a
  graded column for free.
- The AI already contests the right ground without a change: intent assigns axes over
  `md.objectives`, which now *are* the villages and bridges.
- Villages sit in nobody's deployment zone by construction (the pools filter them out), so a
  defender "around the objectives" (2f) starts outside its own zone — scenario deployment will
  place by radius around objectives, not by zone, which is exactly what 2f specifies.
