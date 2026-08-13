# 0021 — Movement fills the action in progress

Amends [0014](0014-movement-in-two-action-points.md).

## Context

0014 split the movement overlay into a near region — reachable on one action's movement points — and
a far region needing both. It defined the near band as `min(action_mp, mp_left)`: one action's worth,
or whatever is left if that is less.

That is a fresh action's worth measured from wherever the tank currently stands, and it is wrong as
soon as the tank has moved. A unit with 220 points and two actions buys 110 per action. Drive 60 of
them and 50 of the first action remain — but the overlay drew a near band of 110 again, from the new
position. It was handing back the movement just spent.

Two things follow, and both were reported from play:

- **A short move looks free.** Move four tiles of a five-tile action and the near ring springs back
  to a full action's reach, so nothing on screen says that four fifths of an action has gone. The
  practical complaint was about misclicks: move one tile by accident and the interface gives no sign
  that the action point is nearly spent.
- **The bands do not collapse when they should.** 0014 says that with under one action's worth left
  the two regions become one, because there is only one answer left to give. Under the old
  definition a part-spent unit kept showing two regions whose boundary meant nothing in particular.

## Decision

**The near band is what remains of the action already in progress.** Not a fresh one. The action was
begun and paying for it twice is not on offer.

It stays **derived**, which was 0014's actual point — the objection there was to a stored `ap_left`
that could drift out of sync with `mp_left`, not to the idea of knowing which action you are in.
Movement fills the action points in order, so that follows from what has been spent:

```
spent    = mp_max - mp_left
index    = spent / per_action          # which action we are inside
boundary = (index + 1) * per_action    # where it ends
near     = clamp(boundary - spent, 0, mp_left)
```

The clamp is what makes the bands collapse: once under one action remains in the whole turn, `near`
equals `mp_left`, the far region is empty, and the overlay draws one region.

**A whole-action cost forfeits the unused fraction.** This is the price of the above and it is not
optional. If a part-spent action can be finished later, then something costing a whole action point —
shooting, in iteration 2 — must consume whatever is left of the current one. Otherwise a unit banks
slivers of movement across actions, and "two actions" stops bounding anything. `UnitState.
commit_action` implements it. Nothing calls it yet, because movement is the only action iteration 1
has; it exists so that a rule already decided is written down rather than rediscovered as a bug.

**The two bands are separated by hue, not by brightness.** Near is cyan, far is amber, on the
walk-and-dash convention. They were previously one amber at two brightnesses — hues 37° and 31°, six
degrees apart — which reads as one region lit unevenly rather than as two answers to two different
questions.

## Consequences

- The near ring tightens as an action is spent and resets when the next one begins, so the boundary
  on screen is always the real one. The tile readout says "this action" or "spends both actions"
  rather than "1 action" / "2 actions", which was wrong once the near band became a remainder.
- `near_mp` is now the single definition, and the tests call it. The three action-point tests written
  for 0014 each recomputed `min(action_mp, mp_left)` inline, so they went on passing unchanged when
  the near band stopped being that. A test that reimplements what it is testing agrees with itself
  whatever the game does; that was the real defect and it is the reason this went unnoticed.
- The colour guard was measuring the wrong quantity too. `test_the_two_pip_colours_are_
  distinguishable` summed absolute RGB differences and passed at 0.56 on two colours six degrees
  apart in hue. It compares hue now, and the same assertion covers the overlay bands, which had no
  guard at all.
- **A light-blue movement range was tried before and read as water** — the note in `rules.json`
  records it. It is back, and the differences are that it is an outline over a weak fill rather than
  a flat tint, and that the cyan is deliberately pulled off the water terrain (hue 204 at value 0.47)
  to hue 189 at value 0.88, separated on both axes and asserted by a test. If it still reads as
  water, the fix is to move further toward green, not to go back to a brightness-only split.
- Nothing about the totals changes. Movement per turn, path costs and the reachable set are exactly
  as before; only where the near boundary falls, and what colour each side of it is.
