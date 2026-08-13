# 0028 — Terrain concealment is a per-class table, not a scalar

## Context

`data/terrain.json` carried one `spotting` number per terrain type: a multiplier on the observer's
range for a unit standing on that ground. Open 1.0, woods 0.4, heavy woods 0.25. It was loaded into
`Config.terrain_spotting` at the start of iteration 1 and read by nothing for the whole of it.

Iteration 2 is where it becomes load-bearing, and the moment it does the scalar is wrong — not
numerically, structurally. Concealment is the one visibility number that is not a property of the
ground alone. A tank in heavy forest is a tank wedged between trunks it cannot fit through and could
not have driven into in the first place; a rifle section in the same stand is invisible. One number
per terrain type says those are the same situation.

The spec has always intended infantry, APCs and the rest to arrive later, and `MovementClass` already
exists precisely so that nothing has to be retrofitted when they do (0015). Concealment is the second
axis that wants the same treatment, and the cost of adding it now — while exactly one class is
fielded and every row is a copy — is a table nobody has to look at. The cost of adding it later is a
migration of whatever spotting code has grown on top of the scalar in the meantime.

## Decision

**`terrain.json` gains `concealment_classes`, indexed by `MovementClass.Kind`, each with a `values`
array parallel to `types`.** The per-type `spotting` scalar is deleted rather than kept alongside:
two places holding the same number is one place to get it wrong, which is a sentence already written
in this file's own `_movement_classes_comment` about movement costs.

**`Config.class_concealment` is the authoritative flat table**, `mclass * type_count() + type`, with
`concealment(mclass, type)` as the accessor. **`Config.terrain_spotting` survives as a slice of the
tracked row**, re-derived at load — exactly the relationship `terrain_move_cost` has to
`class_move_cost`, and for exactly the same reason: most callers genuinely mean "the vehicles this
game fields", and making every one of them index the full table would be noise.

**A short `values` array pads to 1.0 — fully visible.** This is the mirror image of the movement
table, which pads to impassable, and it is the same argument in both directions: the padding must be
the value that fails loudly in play. For movement, "nobody decided" must not read as "drive straight
through". For concealment, "nobody decided" must not read as "invisible". Neither default is safe;
each is the unsafe one that gets noticed.

## Consequences

**The tracked row is numerically identical to the twelve scalars it replaces, and a test pins it
against a literal.** That is what makes this a restructure rather than a silent retune of every
spotting range in the game. Deriving the expectation from the file under test would prove nothing, so
the twelve numbers are written out in `tests/test_config.gd` by hand.

**The `foot` row is where infantry-in-heavy-forest already lives** — 0.10 against tracked's 0.25, and
0.55 against 0.90 in scrub. Those numbers are untested by play and will move. What matters is that
the axis they move along exists before the units that need it do, so the first infantry commit is a
data commit.

Nothing else in `terrain.json` changed. The `types` array lost one key per entry and kept its order,
which remains load-bearing against `TerrainTyper.Type`.

The `wheeled` and `amphibious` rows are copies of `tracked` today. That is honest — a lorry hides
about as well as a tank does — and it costs one line each to stop being true.
