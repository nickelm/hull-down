# 0014 — Movement is spent in two action points

Implements the movement half of [0003](0003-side-alternating-turns.md)'s two-actions rule, which
[0012](0012-turn-cycling-in-iteration-1.md) deferred.

## Context

0003 gives every unit two actions per turn. 0012 pulled the turn structure into iteration 1 but left
the action budget out, on the grounds that both actions are combat and there is no combat yet — so
movement points were the only limit and the movement overlay was a single region.

That leaves out the decision the overlay exists to inform. "How far can I get?" has two answers, and
they are tactically different: how far can I go **and still have an action left**, versus how far
can I go by spending everything. A single region cannot express that, and a player reading it has no
way to see where the line is.

## Decision

A turn's movement points are **two actions' worth**. `movement.actions_per_turn` is 2, and one
action buys `mp_max / actions_per_turn` movement points. Nothing about the total changes — a unit
that spends everything on movement covers exactly what it covered before.

The movement overlay draws two regions:

- the **near** region, reachable for at most one action's movement points,
- the **far** region, reachable only by spending more than that.

They are painted as disjoint sets, so the boundary between them is outlined from both sides and the
one-action limit reads as a ring. Where a unit has already spent enough that under one action's
worth remains, the two collapse into one region, which is correct: there is only one answer left.

This is deliberately *not* a separate `ap_left` counter. Movement points already track what remains,
and a second budget that can only ever be `floor(mp_left / per_action)` is a derived quantity
pretending to be state — the kind of thing that goes out of sync. Actions become real state in
iteration 2, when shooting and overwatch give them something else to be spent on.

## Consequences

- The overlay answers the question a player actually asks. The near boundary is where "move and
  still act" ends, and it moves as movement points are spent.
- No rules change: total movement per turn, path costs, and the reachable set are all exactly as
  before. Only the presentation splits, plus the tile readout naming which band a tile is in.
- Turn costs make the split slightly non-obvious in a good way — a tile straight ahead can be one
  action away while a nearer tile behind the tank is two, because turning costs movement. That is
  the facing model doing its job, and it is now visible.
- When combat arrives, "moving costs one action" becomes a real constraint rather than a display
  convention, and the near region becomes the set of tiles you can move to *and still shoot from*.
  The overlay does not have to change shape for that.
