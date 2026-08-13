# 0024 — Knowledge is side-level and asymmetric

## Context

Spotting comes before combat, not after it. Overwatch triggers on reveals, to-hit depends on
exposure and on whether the target has been seen at all, and an AI has to plan against what it knows
rather than against the board. Building combat first and knowledge second means writing combat twice.

`docs/design/rules.md` §3.3 had the shape of the rule — line of sight plus a range threshold,
modified by optics, terrain and recent movement, with no roll — and left four things open. This
record settles them.

## Decision

**Knowledge is side-level.** One contact list per side, in `MatchState.knowledge`. If one of your
tanks sees something, your whole side sees it.

Per-unit knowledge is more realistic. It also doubles the state, turns every query into "which of my
units are we asking about", and asks the player to hold a mental model of who is looking at what
before they can read their own screen. The realism buys a kind of confusion that is indistinguishable
from a bug.

**Spotting is asymmetric.** A spotting B implies nothing about B spotting A. Different optics,
different ground, different exposure. The extra check is one direction of a loop, and the asymmetry
is the entire reason a recon vehicle has a job — a light tank that sees a heavy before the heavy sees
it is doing something no amount of armour replaces.

**Effective spotting range** is the observer's optics multiplied by three modifiers, and all three
are properties of the *target*:

```
effective = optics(observer)
          x concealment(target's movement class, target's terrain)   [0028]
          x movement(how hard the target drove this turn)
          x exposure(how the target looks to this observer)
```

A target is seen when some living unit of the side has line of sight to it and the distance is inside
that. Line of sight is a gate, never a modifier. Two overrides sit on top: anything inside
`spotting.point_blank_m` is seen if it can be seen at all, and anything that has **fired** is seen at
any range by anything with line of sight, until the start of its own next turn.

**There is no roll**, and the reason is not determinism for its own sake. `plan_move` is pure, so the
hover preview may ask "will I be seen if I drive here" on every mouse move. With a threshold that
question has an answer worth showing. With a roll the preview would be lying about half the time,
and a tactics game whose previews lie is one nobody trusts twice.

**Movement is a ramp, not a switch.** `1 + (moved_max_mult - 1) x (mp_moved / mp_max)`. A tank that
crept one tile is nearly as quiet as one that never moved; a tank that spent its whole allowance is
loud. A binary moved/did-not flag makes creeping forward to peek over a crest cost exactly as much
concealment as driving flat out across a field, which is the opposite of the decision the player
should be making.

`mp_moved` is accumulated from `STEP` and `TURN` events rather than derived from `mp_max - mp_left`,
because firing forfeits the rest of the action in progress (0021) and a tank that stood still and
shot has not driven anywhere. It is revealed regardless, by the muzzle flash, and for a better
reason.

**A lost contact leaves a ghost** at the position it was lost at, for `spotting.ghost_turns` of that
side's own turns. Ghosts age on their owner's hand-over, not on every hand-over: "my information is
two turns old" is a length a player can plan around, whereas ageing on every side's turn would make
`ghost_turns: 2` mean one round in a two-sided match and half a round in a four-sided one, with
nothing in the data file saying so.

**A `SEEN` contact's position is not stored.** It is the unit's own tile, and a second copy is a
second thing that can go stale — the objection 0014 raised to `ap_left`. Only a ghost has a memory,
written exactly once, at the moment contact is lost. This is also what makes the model replay-safe: a
unit that moves while staying visible produces no knowledge change at all, so there is nothing the
event stream has to record and nothing a replay can get wrong.

## Consequences

`SideKnowledge` is structure-of-arrays with `_visual_`-prefixed fields, and that prefix is load
bearing — see 0033.

`UnitState.begin_turn` takes a `Config` now, because `fired_this_turn` has exactly one place it may
be cleared and that place is the *firer's* own next turn. Clearing it at the end of the firing turn
would be a muzzle flash that went out before anyone was looking at it. The signature change ripples
to `MatchState.end_turn(cfg)` and its callers.

The turn-boundary sweep lives on `ActionResolver`, not `MatchState`: handing over is when contacts
are refreshed, and only the resolver can see the ground they are seen across. `MatchState` holds the
board's occupants, not the board.

`Spotting.recompute_side` is O(observers x targets x line-of-sight) and is called per tile entered
once 0025 lands. That is fine at three a side and wrong at the spec's "dozens". The fix, when it is
needed, is a per-observer cached `VisionField` invalidated on that observer's move; `VisionField`
already computes a whole board's exposure in about 10 ms by radial sweep. Noted, not built.

The optics in `units.json` were rescaled from 1400/1150/900 m to 500/400/320 m as part of this,
answering the question 0020 left open. Against a measured median clear sightline of ~141 m the old
numbers meant range never bound and the optics column was decoration.
