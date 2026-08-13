# 0041 — A mission is data, and entrenchment is a deployment state

## Context

2f asks for a scenario definition format, asymmetric deployment with the defender placing first
around the objectives, and an entrenchment state — starts unspotted, counts as hull down
regardless of terrain, loses both permanently on moving. 2g adds the attacker's shape: three or
four to one in numbers, thin armour, low penetration, poor optics, arriving in waves from the map
edges on a clock the scenario owns.

## Decision

**A scenario is a JSON file** (`data/scenarios/`), parsed by `sim/scenario.gd`: map seed, turn
limit, and per side a deployment mode (`zone` or `objectives`), a unit list, an entrenched flag,
and waves (turn, edge, units). The rules stay in `rules.json`; a mission overrides only what it
genuinely owns — its clock, its forces, its ground. `MatchRunner.for_scenario` plays one headless;
`game/main.gd` boots one interactively (the M key), with the machine on every side but the
player's.

**The defender places first, by construction.** `build_state` deploys `objectives`-mode forces
before `zone`-mode ones, round-robin across the objectives so a three-flag defence is three posts
rather than a crowd on the first flag. Supporting this, objective placement gained a keep-out band
around the deployment zones (`zones.objective_zone_clearance_frac`) — an objective the defence can
ring while standing inside the attacker's deployment-time spotting range is a degenerate mission
on any map, and seed 1017 promptly demonstrated it.

**Entrenchment is three rules, each in the one place that owns that kind of rule:**

- *Hull down regardless of terrain* lives in `Spotting.exposure_between` — the seam that function's
  docstring reserved for "a dug-in stance" when it was written — and `FireAction` now reads
  exposure through that seam instead of calling `Los.classify` raw, so the eye and the gun cannot
  disagree about a dug-in target. Entrenchment never masks; it caps exposure at hull down.
- *Starts unspotted* is a concealment multiplier (`entrenchment.concealment_mult`, at or below 1.0
  — the spotting early-out prunes on pre-exposure range, so modifiers may only shrink). Not a
  hard "invisible" flag: a scout that drives close enough still finds the position, which is what
  makes scouting worth doing against a dug-in defence.
- *Lost permanently on moving* is the `STEP` and `TURN` arms of `EventApplier` clearing the flag —
  one-way, so replays stay idempotent, and in the applier so a replayed stream enforces it
  identically. `TURRET` deliberately does not clear it: traversing the gun is the free action
  (0035), and a dug-in gun that fires is *revealed* (by `fired_this_turn`, as ever) but still hull
  down — a revealed prepared position is exactly what "hull down" names.

**Waves are whole units created at build time with `on_board = false`,** not conjured when due.
Knowledge arrays are sized to the roster and identity is positional (0031); a unit appended
mid-match would exist for one side's knowledge and not another's depending on who resized when.
Off-board is a first-class absence: excluded from `side_units`, spotting, occupancy, capture, and
`ViewState` (hidden even from its own side) — but counted by `side_alive_count`, which the
annihilation test and the turn hand-over now use, because a side waiting on its next wave is
bloodied, not beaten, and skipping its turns would strand the wave off-board forever.
`Scenario.spawn_due` delivers a due wave at its edge, walking the edge band from the middle
outward, and simply tries again next turn if the band is blocked.

**The attacker's tank is a new data row** (`assault` in `units.json`): armour under the light
tank's, penetration that needs a flank even against the medium, and the poorest optics on the
roster — so the mass advances half-blind into defenders it cannot see, which is the mission.
`tests/test_scenario.gd` asserts the composition claims against the data, so a retune cannot
quietly hand the attacker good eyes.

## Consequences

- The dig-in mission plays end to end headlessly (both acceptance tests run it) and interactively.
- The interactive AI turn reuses the whole 0034 replay path: `AiRunner.run_turn_watched` pairs
  each result with its stream filtered against the spectator's knowledge *before* that order
  resolved — the same ordering `test_replay_filter` pins for human orders — and `ActionQueue`
  finally does the job its docstring promised it was built for.
- The match-over announcement (grade, points) is the first UI the graded ladder (0040) reaches.
- Entrenchment is deployment-only by construction: nothing in the rules can set the flag
  mid-match, so "dig in as an action" is a future decision, not a latent behaviour.
