# 0003 — Side-alternating turns with full activation

## Context

With dozens of units per side, the turn structure decides whether a turn is a plan or a chore. The
candidates were: initiative-interleaved activation (one unit per side, alternating), squad
activation, and side-alternating full activation.

Interleaved activation reads well at squad scale and collapses at company scale — forty
back-and-forth handoffs per turn is a UI problem with no good answer.

## Decision

Side-alternating turns. One side activates all of its units, in any order the player chooses, then
the other side does the same. Each unit gets two actions. Shooting or going on overwatch ends that
unit's turn regardless of actions remaining. Reloading is automatic and costs nothing.

## Consequences

- The player sees the whole board state before committing anything, so a turn is a plan rather than
  a sequence of independent decisions. This is what makes hull-down positioning meaningful — you
  can coordinate a ridge line, not just move one tank onto it.
- Alpha strike is real: a side that wins the first-contact roll can concentrate everything before
  the other side responds. Overwatch exists to answer this, and is the reason it costs a unit its
  whole turn.
- Free activation order within a side is a large tactical space (spot with the light tank, then
  decide who shoots) and a UI obligation — Tab-cycling with a clear "who has not acted" indicator
  is not optional. That UI lands in iteration 2.
- The enemy turn must be fast. Dozens of AI units resolving serially with animation is unwatchable;
  the enemy turn needs to batch or elide movement that the player cannot see.
- "Two actions, shooting ends the turn" means the interesting choice is move-move, move-shoot, or
  shoot-and-be-done. Anything that adds a third action type has to be checked against that shape.
