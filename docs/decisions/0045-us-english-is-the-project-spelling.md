# 0045 — U.S. English is the project spelling

## Context

The codebase had accumulated British spellings throughout: `cfg.colour`, `tile_centre`,
`neighbour()`, `class Armour`, `data/units.json` "armour" blocks, the HUD's "Centre" button, and
several hundred comment and docstring uses. The project owner's convention is U.S. English
("center", not "centre"), and a codebase split between the two misspells every search: half the
call sites for a renamed accessor simply do not turn up.

## Decision

U.S. English everywhere: identifiers, UI strings, comments, JSON keys, `CLAUDE.md`, and
`docs/design/rules.md`. The full sweep was applied on 2026-08-13 — the load-bearing renames were
`Config.colour` → `color` (with every `*_colour` key in `data/rules.json` in lockstep),
`Grid.neighbour`/`MapData.neighbour` → `neighbor`, `Armour` → `Armor` (file renamed to
`sim/combat/armor.gd`), `TerrainView.tile_centre` → `tile_center`, and the HUD's centre
signal/button family.

Two exemptions:

- **Existing decision records and past journal entries keep their original spelling.** Records
  are immutable (CLAUDE.md); a spelling edit is still an edit.
- Engine and third-party names are whatever they are.

## Consequences

- All new code, data keys, and prose are written in U.S. English from the start.
- The sweep renamed public API and data keys; anything outside the repo that read the old names
  (there is nothing known) would need the same rename.
- The 556-test suite passed unchanged across the sweep, which is the evidence the rename was
  mechanical and complete.
