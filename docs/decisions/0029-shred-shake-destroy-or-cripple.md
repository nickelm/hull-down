# 0029 — Non-penetrating hits shred or shake; penetrating hits destroy or cripple

## Context

0004 settled the *shape* of combat — two rolls, penetration versus the facing struck, no null
results, armour that never regenerates, exactly two component criticals. It settled no numbers, and
it left one thing genuinely unstated: what a penetrating hit actually does. There is no health pool
by design, so "penetrated, therefore what?" had no answer anywhere.

`docs/design/rules.md` §4 has the same gap. It says a non-penetrating hit "shreds armour or shakes
the crew" without saying which, when, or by how much.

## Decision

**To hit** is a base chance scaled by range beyond point blank, multiplied by exposure, the firer's
movement, the target's movement, crew state and gun damage, offset by an elevation term, and clamped
at both ends. Every modifier in `combat` is a penalty at or below 1.0 — the clamp is the only thing
that raises a chance, and it raises it off the floor rather than towards certainty. A test pins that
each modifier makes a shot worse, individually.

The clamp is a rule and not a safety net: `min_hit_chance` keeps a hopeless position from being
hopeless, and `max_hit_chance` keeps a perfect one from being a formality. Without both, the
interesting middle of the range band collapses at one end or the other.

**Penetration** is the round's penetration at range against the plate actually struck, resolved on a
**band around the ratio** rather than as a step. At or below `no_pen_ratio` (0.80) nothing gets
through; at or above `certain_pen_ratio` (1.30) everything does; between them the chance rises
linearly.

A step at parity would make every engagement a lookup — either your gun works on that tank or it does
not, and there is nothing to play. The band is deliberately wide so that "nearly enough" is frequent
and legible: the shot that shreds instead of killing, and shreds the plate that makes the next shot
work.

`gun.penetration_mm` is quoted at 1000 m, so falloff is measured from there — closer is better,
further is worse, with a floor at `pen_min_fraction` so a very long shot is weak rather than
harmless. A test asserts the nominal figure comes back exactly at 1000 m, because the day that stops
being true every gun in the roster has been silently rescaled.

**No null results, as a shape rather than a sentence.** Every shot emits exactly one terminal
outcome:

```
FIRE  ->  MISS
      ->  HIT (bounced)     ->  SHRED  or  SHAKEN
      ->  HIT (penetrated)  ->  CRITICAL  or  DESTROYED
```

There is no path through `HitResolver.resolve_shot` that produces a hit and nothing else, and
`test_combat_distribution` checks it as an **exact integer identity** over a thousand shots rather
than as a sampled rate. That test is completely retune-proof: no adjustment to any number can break
it without breaking the rule.

**Shred is scaled by how close the round came.** A shot that nearly got through takes more off the
plate than one that spanged away. That is what makes wearing down a heavy tank with a light gun slow
rather than impossible, and it is why the light tank's role in the roster — "armour shred" — is a
real job rather than a label.

**A shake wears off; shred does not.** That asymmetry is the whole of "no null results" being worth
having: one outcome is permanent progress and the other is a window.

**A penetrating hit destroys the tank unless it rolls a component critical instead.** Iteration 2 has
exactly two components, as 0004 says, and neither is recoverable. An immobilised tank still fights,
still traverses its turret and still takes its free hull step — it simply never drives again.

**The component comes from the `CRITS` stream, everything else from `COMBAT`.** This is the first
real use of 0005's stream separation and the line where the promise is kept: adding a roll to the
combat sequence can never reshuffle which part breaks.

## Consequences

`HitResolver.resolve_shot` is **pure except for its draws** — it reads, rolls, and emits; only
`EventApplier` changes anything. That is what makes the thousand-resolution test stationary. A
resolver that wrote through would degrade its own target across the loop, and the measured
distribution would drift into a band it was never meant to occupy, which looks exactly like a tuning
problem and is not one.

`FireForecast` exists because a percentage-based game has to show its percentages before the player
commits. It is the exact analogue of `plan_move` being pure, and a test asserts the preview and the
shot agree field by field — a forecast that can silently disagree with what the shot charged is the
worst bug this game can have, because it does not look like a bug, it looks like bad luck.

Firing costs a whole action point and so forfeits the unused remainder of the one in progress. That
gives `UnitState.commit_action` its first caller, three batches after it was written for exactly
this, and it is spelled as `mp_after_action` so that the planner and the preview can both have the
arithmetic without the mutation.

`PathResult.blocks_firing` is finally read, by `FireAction.legality`. Iteration 1 computed and
displayed it with no mechanical effect; `rules.md` §2.4 has specified the rule since before there was
anything to enforce it against.

The numbers here are untested by play. They are internally consistent, every ordering claim in them
is pinned by a test, and the two that most want a human eye are `critical_chance` — how often a
penetration leaves a wounded tank rather than a dead one — and `shred_share`, which decides whether
a light tank chipping at a heavy feels like work or like futility.
