# 0033 — Sound contacts are a second knowledge layer, reserved

## Context

Iteration 2.5 adds sound contacts: firing and noisy movement generate a contact at the unit's true
tile, rendered with positional error that grows with distance, ignoring line of sight entirely,
giving direction and rough range but no identity.

None of that is built here, and this record does not build it. It exists because the cheapest moment
to decide *where* it goes is before the thing it sits beside is finished, and the decision is one
line of structure that costs nothing now and is expensive to retrofit.

The temptation, once `SideKnowledge` exists with `UNKNOWN / SEEN / GHOST`, is obvious: add `HEARD` as
a fourth state. It would work. It is also wrong, and it would be wrong in a way that only shows up in
the UI, months later, as a class of bug nobody can name.

## Decision

**Sound contacts are a sibling class with their own arrays and their own slot on `MatchState`, never
a fourth value in `SideKnowledge.State`.** The visual fields on `SideKnowledge` are prefixed
`_visual_` so that the distinction is visible in the code rather than only in this file.

A sound contact is **not a downgraded sighting**. It is a different kind of information about a
different kind of question:

| | Visual contact | Sound contact |
|---|---|---|
| Needs line of sight | yes, always | no, never |
| Position | exact (or exactly stale) | deliberately wrong, by more at range |
| Identity | known | not known |
| Decays | over turns, as a ghost | on its own schedule |

Sharing one enum forces those into one code path, and every consumer then has to ask "is this the
precise kind or the imprecise kind" at the point of use — which is exactly the check that gets
forgotten once. Two containers make the question unaskable: you either read the layer that has
positions or the layer that has bearings.

The presentation half matters as much. Chaos Gate's version of this mechanic works because the
imprecision is **honest** — the marker looks like a guess and is drawn like one. The moment a sound
contact renders as a dimmer ghost, players read it as a ghost with a rendering bug, aim at it, and
learn to distrust the whole layer. Separate containers make separate markers the path of least
resistance instead of a thing someone has to remember to do.

## Consequences

Nothing is built. `data/rules.json`'s `look.ghost` block carries a note saying the sound layer gets
its own block beside it rather than another alpha value on this one.

`SideKnowledge` gains nothing speculative — no `HEARD`, no reserved slot, no field waiting for a
producer. 0014's rule holds: state nothing reads is worse than no state. What is reserved here is a
*shape*, and a shape costs nothing to write down.

When the layer lands it will want its own decision record for the rules it actually adopts — how the
positional error scales, what counts as noisy movement, whether a sound contact can be fired at
speculatively the way a ghost can. This one only says where it goes.
