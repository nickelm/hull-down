# 0039 — Utility scores priced in tiles of progress

## Context

2e-ii asks for the first real AI: candidate end states scored with weighted terms, weights in
`data/ai.json`, the AI stream for tie-breaking only, a side-level intent layer, and a hard
performance budget — a 30-unit turn under one second. Every one of those is a decision about
*shape* before it is a number, and the shapes needed writing down.

## Decision

**One point of utility is one tile of progress toward the assigned objective.** Every other weight
is priced against that yardstick: hull-down cover against a known gun is worth about two and a half
tiles of progress, a counted shot about eight, a kill about sixty. The alternative — each term in
its own units, tuned against each other by trial — is how utility AIs become a soup nobody can
retune. With a yardstick, "the AI is too timid" translates directly to "cover is priced too high in
tiles", which is a one-line data change.

**Danger is priced only against what the side knows.** Cover terms are evaluated per known enemy —
live contacts, then ghosts and sound ripples as caution fields with a radius — because `AiView`
holds nothing else (0038). This is also the honest reason the AI can be ambushed: a tile is only
safe against the enemies it has heard about. The overwatch-arc term reads the *turret bearing* of a
live contact, not its watch order: 0036 withholds the wedge from the enemy, but the gun itself is
visible on any spotted tank, so "do not cross a laid gun's lane" is knowledge the side honestly has.

**Candidate enumeration is a deterministic stride, not a draw.** The reachable set is sampled down
to `ai.candidates.max_per_unit` in tile order, with three guaranteed members: the current tile
(staying is a real candidate, with a hysteresis bonus so the force does not oscillate), the
reachable tile nearest the objective (the stride must not skip the point of the move), and the
strided rest. Hull facing is *not* enumerated separately: facing is decided by the route the
pathfinder takes and by the free turret traverse (0035), and a facing term without the arrival
facing would be scored against a guess. The spec's "tile plus hull facing" collapses to "tile"
under this engine's movement model, and that is recorded here rather than approximated silently.

**The AI stream breaks ties and does nothing else.** Candidates within `ai.tie_break_epsilon` of
the best score are a tie; one draw picks among them, and only when the tie is real. Everything else
is deterministic, so a match replays from its seed.

**Intent is sticky group assignment.** Units are walked in deployment order; each takes the nearest
objective with an open slot, slots being an even split of the force. Once assigned, a unit keeps
its axis until it dies. A fresh greedy pass each turn re-shuffles the groups as distances change,
and a force whose axes flap re-crosses its own line of advance — coordinated on every turn,
scattered across any two. The assignment lives in the policy object, so a side's intentions are
private to that side by construction.

**The policy decides one order at a time.** The runner re-asks after every resolved order, so
"advance, then shoot from the new position" emerges from the two-action budget (0014) without the
policy ever planning a sequence — and an overwatch interruption re-plans automatically, because the
next ask sees the new board.

## Consequences

- `tools/ai_batch.gd` reports win rate, turns to first objective hold, losses, and per-turn
  timing over N matches on quarter-scale maps — the measurement loop the weights get tuned in.
- The 30-unit budget holds with margin (~500 ms measured on the flat worst case, debug build),
  and the candidate cap is what makes it a promise; raising the cap buys quality with linear cost.
- The shot-value term inside tile scoring is a cheap estimate (base hit minus range falloff), not
  a full `preview_fire` — the preview runs once per order, the estimate hundreds of times per
  turn. If the two drift far enough to matter, the fix is a cheaper preview, not a slower loop.
- Sound and ghost caution weights are signed in data: an aggressive force that *investigates*
  ripples is a sign flip, not a rewrite.
