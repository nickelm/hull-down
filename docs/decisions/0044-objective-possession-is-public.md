# 0044 — Objective possession is public

## Context

Decision 0034 established that the view draws from knowledge, never from ground truth: what the
screen shows of the enemy is what the viewing side has spotted. Decision 0040 gave objectives a
holder, hold counters, and point values that decide the match. Iteration 2 built the rules and
none of the presentation — objectives are invisible in `game/`, captures happen silently inside
`ActionResolver.end_turn()`, and the first UI the scoring ladder reaches is the match-over line.

Making terrain control visible forces the question 0034 leaves open: is *who holds a flag*
knowledge, or fact? `Victory.holder_of` reads ground truth. Showing "the enemy holds the mill"
when no enemy unit has been spotted near the mill leaks that something enemy is, or was, there.

## Decision

Objective possession is public information. The on-map objective markers, the HUD points line,
and the capture/lost ticker lines all read ground-truth `Victory` state for both sides, spotted
or not.

The flag on the pole is the wargame convention: control of ground is the kind of fact both staffs
know from the map, radio traffic, and the absence of their own troops there — hiding it would
mean the score that decides the match is a secret from the player it is deciding against. The
units *taking* the flag stay under 0034: the marker changes tint, but no tank is drawn that
spotting has not earned.

## Consequences

- A flipped flag betrays that an enemy stands within the capture radius, uncounted and unseen.
  Accepted: that is the same information a real front line's collapse would carry.
- The renderer reads `Victory.held_by` (a `PackedInt32Array` of side ids) — no `UnitState`
  crosses into `game/`, so the determinism scan is unaffected.
- If a future mode wants fog over possession itself (a raid behind the lines, say), that is a
  per-side believed-holder layer and a record superseding this one.
