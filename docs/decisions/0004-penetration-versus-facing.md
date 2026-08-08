# 0004 — Penetration versus facing, rejecting regenerating armour

## Context

Two models were available for armour. The first is a hit-point pool, optionally with a regenerating
shield layer, where damage is subtracted and the unit dies at zero. The second is armour as a
threshold: a shot either defeats the plate it strikes or it does not.

Regenerating armour is a pacing tool — it punishes chip damage and rewards burst — and it is a
tempting fit for a two-action turn structure. It is rejected here because it makes flanking
optional. If armour comes back, the correct play is to wait for a burst window rather than to
manoeuvre, and manoeuvre is the entire game.

## Decision

Armour is directional plate thickness with five facings: front, left, right, rear, top. Resolution
is two rolls in sequence:

1. **To hit** — a percentage derived from range, exposure state, movement, and optics.
2. **Penetration** — the round's penetration at that range against the plate thickness of the facing
   actually struck.

**No null results.** A hit that fails to penetrate still does something: it shreds armour (reducing
the thickness of that facing for subsequent shots) or shakes the crew (a temporary accuracy or
action penalty). Armour lost to shred does not come back.

## Consequences

- Position is the primary damage multiplier. Getting behind a heavy tank is worth more than any
  upgrade, which is what makes a light tank with a small gun a genuine threat and gives it a role
  beyond spotting.
- No wasted turns. A player who set up a flank, hit, and rolled badly on penetration still made
  progress. This is the specific failure mode — "I did everything right and nothing happened" —
  that the no-null-results rule exists to prevent.
- Damage is monotone. A unit's state only degrades, so the board tells a story you can read: a tank
  with a shredded left side is a tank that has been flanked, and it stays that way.
- Facing must be tracked in the movement system, not just for display. This is why pathfinding
  searches (tile x facing) rather than tile — see 0007 and `sim/pathfinding/tank_pathfinder.gd`.
- Balance is set by penetration and thickness tables in `data/units.json`, not by tuning a health
  pool. Every number in that table is data.
