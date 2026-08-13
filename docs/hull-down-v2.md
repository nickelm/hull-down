# Hull Down — Iteration 2 prompt sequence

Issue in order. Do not start the next prompt until the acceptance check passes.

## Standing preamble

Prefix every prompt below with:

> Follow CLAUDE.md. Keep `sim/` free of Node dependencies. Put every tunable constant in `data/`, not in code. Update `docs/design/rules.md` for any rule change and add a decision record in `docs/decisions/` for any architectural change. Add headless tests. Append a dated entry to `docs/journal.md`.

---

## 2a — Spotting and side knowledge

Implement a side-level knowledge model and deterministic spotting.

- One `Knowledge` instance per side, holding: spotted units, ghost markers, and a slot for sound contacts (empty for now).
- Detection requires LOS and distance within effective spotting range.
- Effective range = observer optics x target tile concealment (per unit type) x target movement modifier x target exposure modifier.
- Spotting is asymmetric: A spotting B does not imply B spotting A.
- Evaluate spotting per tile entered during a move, emitting reveal events into the existing action event stream. Also evaluate at the start of each side's turn.
- Firing sets a revealed flag that clears at the start of the firer's next turn; normal rules then resume.
- Losing contact leaves a ghost marker at the last known tile, decaying after two turns.
- Add `optics` to the unit schema and `concealment` per unit type to `data/terrain.json`.
- **Change the renderer to draw enemy units from the viewing side's `Knowledge`, never from sim ground truth.** Unspotted enemies must not be visible.

*Accepts when:* headless tests on the pinned seeds assert who sees whom, an unspotted enemy is absent from the rendered scene, and a tank crossing a ridge produces a mid-path reveal event.

---

## 2b — Combat resolution

Implement shooting.

- Percentage to-hit from exposure state, range, weapon accuracy, whether the shooter moved, and elevation difference.
- On hit, penetration roll against the armour value of the facing struck (front, left, right, rear, top). Elevation above the target biases toward top.
- No null results: a non-penetrating hit permanently shreds armour on that facing or shakes the crew, costing it an action next turn.
- Two component criticals: immobilised, gun damaged.
- Destroyed units leave wrecks that block the tile and provide cover.
- Overwatch: a unit may spend its turn covering an arc (turret facing plus or minus a weapon-dependent angle, out to max range). Evaluate at each enemy movement step; fire on the first step where the mover is spotted, inside the arc, and in LOS. Fires once unless the unit has a multi-shot ability. Multiple overwatching units all fire, resolved in deterministic unit order.
- Add an unused `suppression` float to the unit schema.
- Hull facing costs movement; turret rotation is free.

*Accepts when:* a headless run of 1,000 resolutions at fixed range and facing produces hit and penetration rates matching the configured curve, and overwatch fires at the correct tile along a scripted path.

---

## 2c — Play loop

Wire combat into a playable turn.

- Tab cycles units with AP remaining. A second key cycles the full roster in fixed order. A side panel lists all units, click to select.
- A unit at 0 AP can rotate its turret but not its hull.
- Overwatch arcs render as translucent wedges clipped by LOS; overlapping arcs render darker.
- Unit card in a fixed screen corner: name, health, armour by facing, AP, current orders.
- Enemy turn replays from the event stream at 1x, 3x, or instant, and skips anything the player's side cannot see.

*Accepts when:* you can play a full turn of six tanks against stationary targets, including overwatch, without touching the console.

---

## 2d — Sound contacts

Add a second knowledge layer beside ghosts.

- Firing and noisy movement generate a sound contact at the true tile.
- Contacts ignore LOS entirely and have a generation radius.
- Store with positional error that grows with distance from the nearest friendly unit; render at the errored position.
- Contacts carry direction and rough range only, never identity.
- Render with a distinct visual language from ghosts: a wedge or ripple symbol, never a unit silhouette.
- Contacts expire after one turn.

*Accepts when:* a shot from an unspotted enemy produces a contact whose displayed position differs from truth by an amount that scales with distance, and no unit silhouette appears.

---

## 2e-i — AI scaffolding

Prepare for AI-controlled sides. No behaviour yet.

- A `Policy` interface returning an action for a given unit and knowledge state.
- A turn executor that walks a side's units and requests an action from that side's policy.
- A `NullPolicy` that passes.
- The AI reads only its own side's `Knowledge`. No access to sim ground truth anywhere in the AI code path.
- Reserve the `ai` RNG stream.

*Accepts when:* a full AI turn with `NullPolicy` completes, no unit moves, and the game state validates. Add a test asserting the AI code path never imports ground truth.

---

## 2e-ii — Utility policy

Implement the first real AI.

- For each unit, enumerate candidate end states (reachable tile plus hull facing), sampled down to a hard cap so a 30-unit turn resolves under one second.
- Score each candidate with weighted terms: progress toward assigned objective, hull-down at destination, concealment, exposure to known enemy overwatch arcs, proximity to sound contacts and ghosts, and value of shots available from that position.
- Weights in `data/ai.json`.
- Use the `ai` RNG stream for tie-breaking only.
- Add a side-level intent layer: assign groups of units to objectives along axes, rather than each unit picking its own nearest objective.
- Headless batch runner reporting win rate, turns to objective, and losses over N matches.

*Accepts when:* the batch runner completes 50 matches, a 30-unit turn resolves under one second, and the advance reads as coordinated rather than scattered.

---

## 2e-iii — Objectives and scoring

- Place victory points on generator features: villages, bridges, and crests.
- Capture by occupancy, held across turns.
- Graded outcome from points held plus kill and loss ratio: decisive victory, marginal victory, draw, marginal defeat, decisive defeat.
- Turn limit per scenario.

*Accepts when:* a headless AI-versus-AI match terminates with a graded result.

---

## 2f — Dig-in scenario

- Scenario definition format: map seed, force composition per side, deployment zones, turn limit, victory conditions.
- Asymmetric deployment: defender places first in a zone around the objectives.
- Entrenchment state applied at deployment: the unit starts unspotted, counts as hull down regardless of terrain, and loses both permanently on moving.

*Accepts when:* you can load the scenario, place a defending force, and the attacking AI advances into unspotted defenders.

---

## 2g — Attacker composition and waves

- Attacker outnumbers the defender roughly three or four to one, with thin armour, low penetration, and poor optics.
- Attackers arrive in two or three waves from map edges rather than all at once.
- Wave timing in the scenario definition.

*Accepts when:* the mission is playable end to end and produces a graded result.