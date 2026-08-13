# Hull Down — rules of record

This file is the source of truth for game rules. Where it disagrees with anything else, this wins.
Every number cited here lives in `data/`, not in code; the values shown are the current defaults.

**Iteration 2 fills in spotting, combat, overwatch and victory.** Everything below is implemented.
The enemy AI is the one part of the iteration-2 preview that is not here: iteration 2 is hot-seat,
both sides played by the same person, and the three-rule AI is split out to be written against a
knowledge model that has been played against first.

---

## 1. Space and time

The battlefield is 200 x 200 tiles of 10 m — 2 km square. Elevation is quantized to 0.5 m and
stored as integer quanta; `height_m = level * 0.5`.

Each tile has one terrain type, one elevation, and optionally water, road connections, and a
deployment-zone or objective marker.

A road is a **layer over** the terrain, not a terrain type: the tile keeps its natural ground and
carries a bitmask of the edges its road connects to, so crossings and junctions are representable
and a road through woods is still a woods tile. Where a road runs it sets the movement cost and
removes the tile's line-of-sight cover. See `docs/decisions/0011`.

Distance is Euclidean. Direction is one of eight: N, NE, E, SE, S, SW, W, NW, numbered 0-7
clockwise from north.

Turns alternate by side. A side activates all of its units in any order. Each unit has two actions.

A turn's movement points are two actions' worth: one action buys `mp_max / actions_per_turn`. This
is not a separate counter — movement points already track what is left, and how far into the current
action a unit is follows from how much of them it has spent (`docs/decisions/0014`, amended by
`0021`).

*(Iteration 2 fields three units a side — one light, one medium, one heavy — hot-seat, with the
player driving both sides. An action is spendable on movement, on shooting, or on going to overwatch;
the last two end the unit's turn.)*

---

## 2. Movement

### 2.1 Cost

Movement is spent in integer cost units. A tank has a movement allowance (`default_mp`, 220).

| Component | Cost |
|---|---|
| Orthogonal step | 10 |
| Diagonal step | 14 |
| Turn, per 45° | 3 |

The step cost is multiplied by the **destination tile's** terrain multiplier — except along a
road, where it is multiplied by the road's own surface cost instead (see below).

Terrain does not have one multiplier. It has one per **movement class**, in `data/terrain.json`.
Iteration 1 fields tracked vehicles only; the other classes exist so nothing has to be retrofitted
(decision 0015).

| Terrain | Tracked | Wheeled | Foot | Amphibious |
|---|---|---|---|---|
| Road (surface) | 0.6 | 0.5 | 0.9 | 0.6 |
| Open, field | 1.0 | 1.3 | 1.0 | 1.0 |
| Scrub | 1.2 | 1.8 | 1.1 | 1.2 |
| Village | 1.4 | 1.2 | 1.1 | 1.4 |
| Light woods | 1.4 | 1.9 | 1.1 | 1.4 |
| Rock | 1.6 | 2.6 | 1.5 | 1.6 |
| Ford | 1.6 | 2.0 | 1.2 | 1.4 |
| Woods | 1.8 | 2.8 | 1.3 | 1.8 |
| Marsh | 2.2 | impassable | 1.6 | 1.6 |
| Heavy woods | impassable | impassable | 2.6 | impassable |
| Water | impassable | impassable | impassable | 2.4 |

**A road discounts the edge, not the tile** (decision 0017). A step that follows a road link is
priced at the road's surface cost outright; a step that merely crosses a road pays for the ground it
is actually on. Where a road runs over ground a class could not otherwise enter, the road's cost
replaces it — that is the **deck**, and it is what makes a bridge drivable. No tile takes both.

### 2.2 Actions

A unit's movement allowance is divided into `actions_per_turn` (2) equal action points, and movement
spends them in order. Two rules follow:

- **A part-spent action can be finished.** A unit that has used 60 of a 110-point action has 50
  points of that action left, not a fresh 110. This is what the movement overlay's near region is
  drawn at, so a short move visibly consumes part of an action instead of appearing free.
- **A whole-action cost forfeits the remainder.** Anything priced at a full action point — shooting,
  in iteration 2 — consumes whatever is left of the action in progress. Without that a unit banks
  unspent fractions and the two-action budget stops bounding anything.

With under one action's worth left in the turn, the near and far regions coincide and the overlay
draws one region: there is only one answer left to give. See `docs/decisions/0021`.

### 2.3 Facing

A tank always has a facing. Facing is part of its state, and part of the pathfinding search state
(decision 0008).

- **Forward** movement requires the facing to already equal the direction of travel.
- **Turning in place** is legal and costs 3 per 45°.
- **Reverse** movement is a distinct edge to the tile directly behind the tank
  (facing + 180°), at 1.6x the step cost, with no turn.

A change of direction is therefore always paid for explicitly.

### 2.4 Transitions

Passability is determined by the integer elevation difference `dl` between adjacent tiles:

| `dl` | Height change | Class | Effect |
|---|---|---|---|
| 0-2 | up to 1.0 m | Normal | normal cost |
| 3-4 | 1.0-2.0 m | Rough | +8 cost; **cannot fire this turn** |
| 5+ | over 2.0 m | Escarpment | impassable |

A diagonal step is legal only if **both** adjoining orthogonal transitions are legal **and both
corner tiles are ground the class can stand on**. Tanks do not cut corners between two escarpments,
and they do not cut corners between two tiles of river either — which is what makes a river
diagonally impermeable, and is the rule rather than any minimum channel width (decision 0018).

Every deployment zone can reach every objective. This is guaranteed at generation time, and there
are now three ways the generator can open ground, priced against each other in one search: lowering
an escarpment, felling a stand of heavy forest, or laying a ford. A map that cannot be repaired is
rejected.

The rough-transition firing restriction is enforced: a unit that crossed one this turn is refused a
shot and refused overwatch. It is computed as `PathResult.blocks_firing`, latched onto the unit by
the step that crossed, and cleared at the start of its next turn.

---

## 3. Line of sight and exposure

### 3.1 Geometry

Terrain is piecewise constant per tile — a tile has one height across its whole area. LOS samples
tile heights directly. It does not interpolate, because the mesh does not interpolate: what the
player sees on a crest is exactly what LOS computes.

Two reference heights on a tank, both measured from the ground of its tile:

| | Height |
|---|---|
| Hull top | 1.4 m |
| Turret (optics and gun) | 2.6 m |

Some terrain carries opaque cover above ground level, which blocks LOS through the tile but not
from it:

| Terrain | Blocker height |
|---|---|
| Woods | 8.0 m |
| Village | 6.0 m |
| Everything else | 0 |

A tile never blocks line of sight originating on itself.

### 3.2 Exposure states

An observer looks from its turret height. It evaluates two rays to the target tile — one to the
target's hull top, one to the target's turret. The result is one of three states:

| State | Turret visible | Hull visible | Meaning |
|---|---|---|---|
| **Exposed** | yes | yes | the whole tank can be hit |
| **Hull down** | yes | no | the tank can see and shoot; only its turret can be hit |
| **Masked** | no | no | no line of sight |

Hull down is the game's title and its central position. A crest that is at least 1.4 m and less than
2.6 m above your tile, with ground falling away beyond it, gives you a shot the enemy cannot answer
in kind.

Exposure is symmetric in geometry but not in consequence: two tanks both hull down to each other
are both firing at turrets, which is a different fight from two tanks in the open.

### 3.3 Spotting

**Knowledge is side-level.** One contact list per side. If one of your tanks sees something, your
whole side sees it (`docs/decisions/0024`).

**Spotting is deterministic — there is no roll.** A target is seen when some living unit of the
observing side has line of sight to it and the range is inside that observer's effective spotting
range. Being deterministic is what lets the move preview say where you will be seen *before* you
commit to driving there.

Effective range is the observer's optics multiplied by three modifiers, and all three are properties
of the **target**:

| Modifier | Source | Effect |
|---|---|---|
| Concealment | `data/terrain.json`, per terrain **and movement class** | open 1.0, woods 0.4, heavy woods 0.25 for a vehicle; much lower for a foot unit |
| Movement | how much of its allowance it spent this turn | ramps 1.0 → 1.6, so creeping is nearly as quiet as sitting still |
| Exposure | how it looks to *that* observer | exposed 1.0, hull down 0.55 |

Two overrides sit on top. Anything within `spotting.point_blank_m` (60 m) is seen if it can be seen
at all. Anything that has **fired** is seen at any range by anything with line of sight, until the
start of its own next turn — a muzzle flash is not subtle, and that is what makes firing a
commitment.

An **entrenched** unit (§7, applied at deployment only) multiplies its concealment by
`entrenchment.concealment_mult` (0.5) on top of the ground's own, and counts as **hull down to
every observer and every gun regardless of terrain** — exposure is capped, never masked. The first
`STEP` or `TURN` the unit makes clears the state permanently; traversing the turret does not, and
firing reveals the unit exactly as it reveals anyone, without digging it out. A revealed prepared
position is still a prepared position.

Spotting is therefore **asymmetric**: A seeing B implies nothing about B seeing A. Different optics,
different ground, different exposure. It is what gives a recon vehicle a job.

**Checks run per tile entered during a move**, not at turn boundaries (`docs/decisions/0025`). A tank
crossing a ridge is revealed on the tile it crests, the reveal is an event in the movement stream,
and it is the same hook overwatch fires from.

Units that were seen and are no longer leave **ghost markers** at the position contact was lost,
decaying over `spotting.ghost_turns` (2) of that side's own turns. A ghost's position is stale and
stays stale — that is the whole point of one.

Optics are sighted at 500 / 400 / 320 m for light / medium / heavy, against a measured median clear
sightline of about 141 m — `docs/decisions/0020` left that choice to iteration 2 and 0024 made it.

### 3.4 What a side sees

Knowledge is not only a rule the simulation applies — it is what the screen shows
(`docs/decisions/0034`). Every unit is drawn as exactly one of five things, from the viewing side's
knowledge and never from the board:

| | Drawn as |
|---|---|
| **Own** | your unit, at its own position, with its movement bar |
| **Seen** | an enemy in contact now, at its true tile and true turret bearing |
| **Ghost** | a remembered enemy at the tile contact was lost on, fading over `spotting.ghost_turns` |
| **Wreck** | a hulk, always visible — a wreck is terrain, and terrain is not spotted |
| **Hidden** | nothing at all. Not dimmed, not a marker: absent |

That table is exhaustive over *units*. **Sound contacts are a separate layer and deliberately not in
it** — see §3.5. They are not a sixth way of drawing a unit; they are not drawn from a unit at all.

An unspotted enemy is absent from everything, not only from the map — no unit card, no tile readout,
no refusal message that would confirm it is there. A replay is filtered the same way: watching an
enemy's move shows nothing before the tile that revealed it, and nothing after contact is lost.

Hot-seat swaps the viewing side at hand-over, so each player sees only what their own side has earned.

One limit is known and unsolved: routes are still planned against true occupancy, so a path that bends
around an empty-looking tile remains a tell.

### 3.5 Sound contacts

The second knowledge layer (`docs/decisions/0033` and `0037`). Everything above is about *seeing*;
this is about hearing, and the two are kept in separate containers because they answer different
questions and a marker built from a noise is not a fainter version of one built from a sighting.

| | Visual contact | Sound contact |
|---|---|---|
| Needs line of sight | yes, always | **no, never** |
| Position | exact, or exactly stale | deliberately wrong, by more at range |
| Identity | known | **never** |
| Lifetime | `spotting.ghost_turns` as a ghost | `sound.turns` |

**Firing and noisy movement make a noise.** A shot always does. A move does when it spent at least
`sound.noisy_mp_frac` (0.35) of the unit's allowance — a tank that crept a tile is quiet — and it
generates exactly **one** contact, at the tile the move finished on. Not one per tile: a row of
markers along the route draws the exact line driven, and a sound is not entitled to say that.

**A noise is heard by a side with a living unit within the source's radius** — `sound.fire_radius_m`
(1200 m) or `sound.move_radius_m` (500 m). A radius is the whole test. No ray is cast, no cover is
consulted, and a hill between you and the gun changes nothing.

**Two sides hear nothing.** The noisemaker's own, and any side that can already *see* it — a guess
drawn over a tank you are looking at says less than the tank does, and it teaches the player that a
ripple sometimes means a confirmed target. A side holding only a **ghost** of it still hears: the
ghost is a memory and the noise is evidence about now.

**The marker is in the wrong place, and further wrong the further you are from it.** The error radius
is `min(error_base_m + error_per_100m × d/100, error_max_m)` — 20 m, 18 m per 100 m, capped at 200 m —
where `d` is the distance from the noise to the hearing side's **nearest living unit**. The closer
your own troops, the better they place it. The marker is drawn at that radius, so its size *is* the
uncertainty; and it is never drawn on the true tile, because a marker that lands dead on reads as
certainty.

The displacement is a **hash** of the true tile, the hearing side, the turn and the source — not an
RNG draw. So the sound layer advances no stream and cannot reshuffle a combat roll (§5), and a replay
reproduces the same wrong position by construction. Two sides listening to one gun disagree about
where it is, which is correct and free.

**Contacts expire on the hearing side's own next turn**, aged as that side takes over, exactly as
ghosts are. `sound.turns` is 2 ticks, which is one full turn of yours.

They are drawn as **concentric rings, never a silhouette and never a wedge** — a silhouette would be
read as a tank, and a wedge points down a bearing this layer does not store. The roster panel states
them as a count rather than as rows, because a row implies something to click and select.

Note what follows from §3.3 and reciprocal line of sight: a gun fired *at you* is a gun you can see,
because firing reveals the firer to anything with an unmasked line to it. The sound layer is therefore
about **fights you are not in** — a gun on the far side of a ridge, an engine you never got eyes on.

---

## 4. Combat

Resolution is two rolls, in order.

1. **To hit** — a percentage from range, exposure state, the firer's and target's movement, crew
   state, gun damage and elevation, clamped at both ends. Firing or going on overwatch ends the
   unit's turn regardless of remaining actions, and forfeits the unused remainder of the action in
   progress (§2.2). Reloading is automatic and free.
2. **Penetration** — the round's penetration at that range against the plate thickness of the facing
   actually struck. Facings are front, left, right, rear, and top.

**Which plate is struck** follows from the bearing of the shooter relative to the target's **hull**.
The front covers three eighths of the circle, each side two eighths, the rear one — so getting
*directly* behind is worth strictly more than reaching a rear quarter. The roof is in the data and is
never struck by direct fire. See `docs/decisions/0029`.

**Penetration resolves on a band, not a step.** At or below 0.80 of the plate nothing gets through,
at or above 1.30 everything does, and between them the chance rises linearly. `gun.penetration_mm`
is quoted at 1000 m; closer is better, further is worse, with a floor.

**There are no null results**, and the shape is exact:

```
FIRE  ->  MISS
      ->  HIT (bounced)     ->  SHRED  or  SHAKEN
      ->  HIT (penetrated)  ->  CRITICAL  or  DESTROYED
```

Shred is permanent and is scaled by how close the round came, so wearing down a heavy tank with a
light gun is slow rather than impossible. A shake wears off. Armor never regenerates; damage is
monotone, and the state of the board is readable as a history of what happened to it.

Criticals are limited to two components: **immobilised** and **gun damaged**. Neither is recoverable.
An immobilised tank still fights and still traverses its turret; a thrown track takes the hull, not
the turret ring.

### 4.1 Facing, hull and turret

Hull facing and turret bearing are different things (`docs/decisions/0027`). The **hull** is what
armor is computed from, costs movement to change, and is part of the pathfinding search. The
**turret** is an absolute bearing, free to traverse within ±135° of the hull, and is what a gun is
laid along. A hull turn that pushes the turret outside its arc drags it to the arc's edge.

**Traversing the turret is free, unlimited within the arc, and legal at zero movement points and for a
unit that has already acted. Turning the hull always costs movement.** What you present to a gun is
therefore settled by where you drove and by nothing else, while the gun itself is free to look
wherever the mounting allows. A tank caught side-on stays caught side-on, and can still shoot back.

Traversing a gun that is on overwatch re-lays the watch along the new bearing rather than cancelling
it: the bearing a unit watches down *is* where its gun points. See `docs/decisions/0035`, which
supersedes 0032's free hull swivel.

### 4.2 Overwatch

A unit lays its gun down a bearing and gives up the rest of its turn. During the enemy's turn, the
first mover that enters a tile within **±45°** of that bearing, in sight of the watcher, is fired on
— once, at a to-hit penalty.

The check runs per tile entered, after that tile's spotting recheck and never before it: a watcher
cannot shoot at what it has not seen. The mover **stops where it was fired on and keeps whatever
movement it had left** — overwatch costs tempo, not the turn. See `docs/decisions/0030`.

### 4.3 Wrecks

A destroyed tank stays where it died. Its tile stays blocked, and it carries 2.0 m of cover — above
the hull line and below the turret line, so a wreck conceals a hull and leaves a turret exactly as
light woods does. A burning tank is a hull-down position. It is not a unit any more: it is not
spotted, not shot at, not cycled to, and it holds no ground. See `docs/decisions/0031`.

---

## 5. Randomness

Every random draw in the simulation comes from a named seeded stream (decision 0005). There is no
global RNG in `sim/`.

Reloading a save and repeating the *same* action gives the *same* result. Reloading and doing
something *different* gives a different result. You can undo a plan; you cannot reroll a die.

---

## 6. Victory

Hold objectives to win. Objectives are placed at generation time on the generator's own features —
**villages, bridges, and crests**, preferred in that order (`docs/decisions/0040`) — and are
reachable from every deployment zone, with a keep-out band around the zones so no flag sits on
anyone's doorstep. Each carries victory points scaled to how contested its ground is: village 3,
bridge 2, crest 1 (`victory.value_*`).

A side **holds** an objective when it has a living, on-board unit within
`victory.capture_radius_tiles` of it and the other side does not. An objective both sides are on is
held by neither — walking a scout onto a tile the enemy is sitting on does not take it off them,
which is what stops the last turn of a match being a race of suicidal dashes. A wreck blocks ground
without garrisoning it, and a wave that has not arrived holds nothing.

Holding is counted in **consecutive turns**. A side that loses an objective and retakes it starts
again from one. The match is won outright by holding `victory.objectives_to_win` objectives for
`victory.hold_turns` turns each — or by being the last side with anything left that can fight,
reserves off the board included.

**The clock and the grade** (`docs/decisions/0040`). A match that reaches `victory.turn_limit`
(24, or the mission's own) ends and is graded. Each side scores
`points held x grade_vp_weight + kills x grade_kill_weight`; the margin between the two scores
lands on a signed five-step ladder — decisive defeat, marginal defeat, draw, marginal victory,
decisive victory — cut at `victory.grade_marginal` and `victory.grade_decisive`. One side's grade
is definitionally the negation of the other's. An outright winner grades at least a marginal
victory whatever the arithmetic of corpses says.

---

## 7. Missions

A mission is a data file in `data/scenarios/` (`docs/decisions/0041`): map seed, turn limit, and
per side a deployment mode, a unit list, an entrenchment flag, and waves.

**Deployment is asymmetric and the defender places first.** A force deploying on `objectives` is
planted around the flags, round-robin across them; a force deploying from a `zone` uses its
deployment zone. Entrenchment (§3.3) is applied at deployment and can never be regained.

**Waves** are whole units of the match from turn one — they count against annihilation and their
side keeps taking turns — but until their arrival turn they are off the board in every sense: not
observers, not targets, not blockers, not capturers, and drawn for nobody, their own side included.
A due wave enters from its named map edge at the start of its side's turn, near the middle of that
edge, and waits a turn if the edge is blocked.

**The machine player** (`docs/decisions/0038` and 0039) obeys every rule above through the same
resolver a click goes through, and knows only what its side's knowledge holds — its contacts,
ghosts and sound ripples, never the board. Its decision weights live in `data/ai.json`; its only
randomness is tie-breaking, drawn from the reserved AI stream so an AI decision can never reshuffle
a combat roll.
