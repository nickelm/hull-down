# 0043 — A start menu gates the boot

## Context

The project has exactly one scene: a bare `Node3D` whose script builds everything in code, and it
booted straight into map generation for a hardcoded seed. Missions were reachable only through an
export variable or the M key — fine while the sandbox was the product, wrong the moment there is
more than one thing to play: a mission with the machine attacking, an open battlefield against
the machine, and the two-human hot-seat sandbox.

## Decision

The boot gains a pre-match gate: a code-built full-screen `CanvasLayer` menu (`game/ui/main_menu.gd`),
shown before any map generates and toggled with ESC in play. No scene switching, no autoload —
one more layer over the board, in keeping with everything else being built in code from
`main.gd`.

- Missions are enumerated from `data/scenarios/` by `Scenario.list_available()` — sorted by
  filename, never directory order. Dropping a JSON in the directory is the whole act of adding a
  mission to the menu (0041).
- Three entry kinds: a mission (the machine takes every side but the objective-deployed one), the
  open battlefield (the symmetric sandbox deployment with the machine on side 2), and the
  hot-seat sandbox. Picking one drives the existing `_clear_units()` / `_load_or_generate()` /
  `_spawn_units()` rebuild path.
- The scrim eats the mouse and every key but ESC is inert while the menu is up; a pick hides the
  menu before its signal fires, so a double-click cannot land twice in a boot sequence that
  awaits frames.
- The `scenario_path` export still boots straight into a mission — the dev convenience is the
  bypass, not the norm.

## Consequences

- Boot is a two-phase flow: `_ready()` builds the world shell, the first pick builds the match.
  A failed generation leaves the player with ESC back to the menu rather than a dead window.
- ESC no longer quits; quitting is a menu entry. The keybind legend says so.
- Menu look (fonts, sizes, scrim) lives in `data/rules.json` under `look.menu`, sharing the HUD's
  `reference_height`/`max_scale` so the two surfaces agree about what a big window means.
- The menu's buttons follow the HUD's `FOCUS_NONE` rule — Tab stays the unit-cycling key.
