# Journal

Newest first. One entry per session: what changed, what is next.

## 2026-08-13 (evening) — the start menu, visible terrain control, and U.S. English

**556 tests pass**, up from 551. Three decision records: 0043 (the start menu gates the boot),
0044 (objective possession is public), 0045 (U.S. English is the project spelling).

**The game now opens on a menu instead of a seed.** A code-built full-screen `MainMenu`
CanvasLayer lists every mission `Scenario.list_available()` finds in `data/scenarios/` (sorted by
filename; a broken file is skipped, a nameless one is named after its file), plus **Open
Battlefield** — the symmetric sandbox with a `UtilityPolicy` on side 2, the "empty battlefield
with some enemies" mode — and **Hot-Seat Sandbox**. ESC toggles the menu in play and no longer
quits; quitting is a button. Every other key is inert while it is up, the scrim eats the mouse,
and a pick closes the menu before its signal fires so a double-click cannot boot twice. The
`scenario_path` export still bypasses it for development.

**Terrain control is on screen at last.** Objectives were invisible in `game/` since 0040 built
the rules. Now: a pennant per objective (`ObjectiveMarkers`, SDF-rasterized like every other
marker, billboarded, drawn through terrain like the selection arrow), tinted neutral / yours /
theirs from `Victory.held_by`; an `80_vp` status line with both sides' points; and ticker lines —
"Objective 2 (3 pts) captured / lost / taken by the enemy" — from a holder diff the controller
takes at every turn boundary, flushed when the replays drain, the same beat as the outcome line.
0044 records the call this forced: possession is public, ground truth for both sides, even though
a flipped flag betrays that something enemy is near it. The units taking it stay under 0034.

**The no-unbridged-crossing guarantee is now watertight end to end.** The generator already
guaranteed zone-to-objective and zone-to-zone connectivity (carving fords when it must), but three
holes stood: cached `.hdmap` files loaded without re-validation — `MapCodec.VERSION` bumped 3→4,
no format change, purely to regenerate pre-guarantee caches; `Deployment.start_tiles`' overflow
fallback took *any* passable tile and could strand a unit in a walled-off pocket — it now floods
from the zone over the traversal graph first (built only when overflow actually happens) and only
a zone with no usable ground at all falls back to the whole map, with `Scenario._around_objectives`
given the same reachability filter; and nothing pinned the promise — `test_zone_routes_cross_water_only_at_fords_and_bridges`
now drives real `TankPathfinder` routes from each zone to every objective and the far zone on
three pinned seeds and asserts no route tile is RIVER (STREAM is legal ground; the traversal
layer never reads `water`), plus `test_deployment_overflow_stays_in_the_zone_component`.

**The whole repo speaks U.S. English.** `colour`→`color` (322 uses, `Config.colour` and every
`*_colour` JSON key in lockstep), `neighbour`→`neighbor`, `centre`→`center` (`tile_center`,
`recenter_on`, the Center button and its signal), `Armour`→`Armor` with the file renamed,
`defence`, `metres`, `grey`, `-ise` verbs, doubled-L participles — all of it, in one sed pass with
the suite green on both sides. Decision records and past journal entries keep their spelling:
records are immutable. CLAUDE.md and `docs/design/rules.md` swept too.

**Next:** the hot-seat hand-over interstitial is still the obvious roughness (the board flips with
no screen between); the keybind legend has outgrown its corner (F1 toggle?); zone imbalance still
fails 17 of 20 seeds and blocks pinning regression seeds; the utility policy still never reverses
into hull-down and never lays overwatch en route; and the menu could show a mission's one-line
description if scenarios grew a `description` field.

## 2026-08-13 (later) — the action bar, the event ticker, and paced shots

**551 tests pass**, up from 550. One decision record, 0042. A UI-polish session: no rule changed,
nothing in `sim/` touched except the read-only paths the new surfaces consult.

**Orders are now one input language.** The bottom-centre `ActionBar` carries what was keyboard-only
— turret left/right and overwatch — with enabled states that restate the resolver's legality
ladders, so a greyed button is the refusal shown before the click. Overwatch from the bar is a
two-step order: the button arms an aim mode owned by `PlayerController`, and the next click on the
board is the bearing, one click deep by construction. Move and fire deliberately stay clicks on the
board. The corner row gains **Centre**, completing prev / next / centre / end-turn.

**Outcomes have a timeline.** `ActionPlayer` gained `event_reached` — once per event, in stream
order, on the skip path too — and the controller narrates it into the new `EventLog` ticker:
"contact — enemy Panzer IV spotted" lands on the step that earned it, "gunfire heard" on the beat
the ripple appears. The stream is already `ViewState.filter`ed by the time it reaches the signal,
so the ticker structurally cannot say more than the board shows. Order confirmations and refusals
moved there from the `80_order` status line; the after-the-fact `_shot_report` summary is gone
because the ticker tells the same story on the beats the rounds land.

**The four pacing keys finally have a reader.** `shot_flight_seconds`, `shot_impact_seconds`,
`destroyed_seconds` and `spot_seconds` had been authored in rules.json since the combat batch with
nothing consuming them; fire actions no longer resolve on screen in a single frame. Also new:
`tests/test_ui_scripts.gd` walks every script under `game/` and asserts it compiles, turning a HUD
typo from a blank window into a named test failure.

**Next:** the ticker and bar make the hot-seat hand-over screen the obvious remaining roughness —
the board flips sides with no interstitial. And the keybind legend has outgrown its corner; an F1
toggle would free the bottom-left for something earned.

## 2026-08-13 — 2e through 2g: the AI, the graded outcome, and the dig-in mission

**550 tests pass**, up from 507. Four decision records, 0038 through 0041. This closes iteration 2's
remaining prompts — 2e-i (scaffolding), 2e-ii (utility policy), 2e-iii (objectives and scoring), 2f
(dig-in scenario) and 2g (waves) — which closes the iteration.

**The AI is 0034 again, and knowing that up front is what made it a day's work.** The renderer's
problem — a complete knowledge model beside a code path that never consulted it — is exactly the
AI's problem, and worse, because an AI that peeks *wins* and nothing looks broken. Same solution,
same shape: policies decide through an `AiView` that serves the side's own units, its `Contact` and
`SoundContact` lists, and pure planning services, and holds nothing else. `AiRunner` and `AiView`
are the only files under `sim/ai/` entitled to a `MatchState`; a scan bans the ground-truth class
names and all `._` reaches from every other file there, covering policies not yet written. The scan
promptly caught its first offender: my own `create` factory writing `p._rng` from outside. The fix
was `_init` — the boundary applies to the policy's author first.

**One point of utility is one tile of progress.** Every weight in `data/ai.json` is priced against
that yardstick — cover ~2.5 tiles, a counted shot 8, a kill 60 — so "too timid" is a data edit with
units, not a soup retune. Danger is priced only against *known* enemies, which is the honest reason
the AI walks into ambushes. The arc-threat term reads a live contact's turret bearing, not its watch
order: 0036 withholds the wedge, but the gun on a spotted tank is visible, so "do not cross a laid
gun's lane" is knowledge the side really has. The spec's "tile plus hull facing" candidate space
collapsed to "tile": arrival facing belongs to the route the pathfinder picks and the turret is
free (0035), so a facing term would score a guess — recorded in 0039 rather than approximated
silently. 30 units resolve in ~500 ms against the 1 s budget; 50 quarter-scale matches run in 36 s
flat with balanced win rates (46/34/20) and first objective holds around turn 3.

**Grades are signed so the debrief cannot lie.** Decisive defeat is -2, decisive victory +2, and
one side's grade is the *negation* of the other's by construction — two independently computed
grades can disagree, and "both sides lost marginally" is not a rule anyone wrote. Objectives moved
to the end of the generation pipeline and onto the features — village 3, bridge 2, crest 1, chosen
round-robin so a map with all three fields all three — with `objective_value` entering the codec
(v3) and the content hash. Points count current possession; `hold_turns` stays with the outright
win. They ask different questions.

**Entrenchment is three rules in three owners, none of them new files.** Hull-down-regardless went
into `Spotting.exposure_between` — the seam whose docstring reserved it for "a dug-in stance" the
day it was written — and `FireAction` now reads exposure through that seam, so the eye and the gun
cannot disagree about a dug-in target. Starts-unspotted is a concealment multiplier, not an
invisibility flag, so scouting still works. Lost-on-moving is the `STEP`/`TURN` arms of
`EventApplier` clearing the flag one-way, so replays stay idempotent; `TURRET` deliberately does
not, and firing reveals without digging out — a revealed prepared position is still hull down,
which is the whole phrase.

**Waves forced `on_board` to be a first-class absence.** Reserves are created at build time —
knowledge arrays are sized to the roster and identity is positional, so a unit appended mid-match
would exist for one side's bookkeeping and not another's — and until arrival they are excluded from
spotting, occupancy, capture, cycling and `ViewState` (hidden from their *own* side too). The two
places that had to keep counting them found themselves by test: annihilation, and the turn
hand-over — a side whose first wave died with two more coming is bloodied, not beaten, and
skipping its "empty" turns would strand the waves off-board forever.

**The mission surfaced a generator gap.** Seed 1017's quarter map put an objective close enough to
the attacker's deployment zone that one dug-in defender was spotted at deployment, failing the
acceptance test. The fix is placement, not the test: objectives now keep a clearance band around
the deployment zones (`objective_zone_clearance_frac`), because a flag the defence can ring while
standing inside the attacker's deployment-time spotting range is a degenerate mission on any seed.

**The interactive wiring cost almost nothing, and that was 2c's foresight paying out.**
`ActionQueue`'s docstring has said since it was written that it exists because an AI turn is a
list; `AiRunner.run_turn_watched` pairs each result with its stream filtered against the
spectator's pre-order knowledge (the same ordering `test_replay_filter` pins), the controller
queues them, and the M key boots the dig-in mission with the machine attacking. The player defends,
watches filtered replays of what their side can see, and gets a graded match-over line — the first
UI the ladder reaches.

Also: `sim/` subclassing needed the RefCounted source scan taught transitivity (`NullPolicy extends
Policy` is the intended hierarchy, and Policy's own file is scanned), and `data/ai.json` mounts
under `Config`'s `rules["ai"]` so the dotted paths, the `missing` guard and the leaf test all cover
it for free.

**Next.** Iteration 2 is code-complete but the presentation half has still only been judged by
tests: the sound ripples, the overwatch cones, the AI's replayed turns and the match-over line all
want eyes on them in the running game. Zone imbalance still fails 17 of 20 seeds and still wants
its own session before regression seeds get pinned. `combat.critical_chance` and `shred_share`
remain suspected mistuned — the batch runner can now measure that cheaply. The utility policy never
reverses into hull-down positions and never uses overwatch en route, both natural 2e-ii follow-ons
the weight file can hold. And `Victory` still special-cases two sides in the controller's outcome
line (`3 - viewing_side`), which is fine until a three-sided scenario exists.

## 2026-08-10 — 2d: sound contacts

**507 tests pass**, up from 489. One decision record, 0037, which is the one 0033 said this layer
would want when it landed. This closes 2d.

**The finding that reframed the batch, and it arrived as a wall of failing fixtures.** The mental
model I built the tests around was *you are shot at from the dark and get a vague marker*. It is
unreachable. `Los.classify` marches one segment with both endpoints excluded, so line of sight is
reciprocal — "that tank can see me and I cannot see it" is not a geometry this engine can produce.
And `Spotting.can_see` reveals a firer to anything with an unmasked line to it, at any range,
deliberately ahead of the range early-out. So a gun fired at you is a gun you can see. Always.

Which means the sound layer is not about being ambushed. It is about **fights you are not in**: a gun
on the far side of a ridge shooting at somebody else, an engine you never got eyes on. Smaller than
the iteration prompt implies and more honest, and every rule in 0037 is shaped around it. It is also
why `tests/test_sound.gd` needs a **three-sided** fixture — with two sides, a shot is either at you
and visible or at nobody at all. Ten of eighteen tests failed on the first run and every one of them
was the fixture rather than the code, which is the good version of that ratio.

**The layer is purely event-driven, and that is the one place it deliberately diverges from
`Spotting`.** `Spotting.recompute_side` mutates as it decides, because the weave's next step reads the
board back. Nothing ever reads a sound contact back — no later check depends on whether an earlier one
was recorded — so `Sound` decides and appends and mutates nothing, and `EventApplier` is the layer's
only writer. "The stream is the account of what happened" then needs no argument for it at all; the
replay test restores an empty layer, walks the stream, and gets the same fingerprint.

**The error is a hash, not a draw**, over the true tile, the hearing side, the turn and the source. No
fifth `Rng.Stream`, no generator advanced, so `test_combat_distribution`'s thousand pinned resolutions
are provably unmoved by the whole batch — a stronger version of what the COMBAT/CRITS split buys. It
also makes the replay reproduce the same wrong position by construction rather than by remembering to
record it, and it gets two sides disagreeing about where one gun is for free, which is correct.

**Three details that are load-bearing rather than tidy:**

- The error radius rides in `flags`, not `cost`. `FIRE` sets a precedent for `cost` meaning something
  else, but `cost` is under the `mp_left == previous - cost` invariant that
  `test_the_movement_snapshots_only_ever_fall` walks a whole stream to check. That test uses
  `plan_move`, so it would *not* have caught a `HEARD` violating it — which is exactly the reason not
  to introduce one. `flags` is already the designated kind-scoped payload field.
- `SideSound.add` dedupes on (tile, source) and refreshes rather than appending. That single property
  is what makes the applier arm idempotent, which every non-arithmetic arm has to be.
- The movement noise is evaluated **after** the weave's walk loop, not inside it. One contact per move
  at the tile it ended on; one per step would draw the exact line the tank drove, which is a track and
  not a sound. The position also gets truncation-by-overwatch right with no special case, because
  `tile` is whatever the walk left it as.

**Two rules I did not expect to have to decide.** A side that can already *see* the noisemaker hears
nothing — a ripple over a tank you are looking at says less than the tank does, and teaches the player
that a ripple sometimes means a confirmed target, after which the layer's honesty is gone. But a side
holding only a **ghost** still hears, because the ghost is a memory and the noise is evidence about
now. That is the one place the two layers touch and the one place they could most easily have been
conflated, which is what 0033 was written to prevent.

And `sound.turns` is **2**, not 1, despite the spec saying "expire after one turn". Decay is charged
to the hearing side as it takes over, exactly as ghosts are; at 1 the contact is aged away by the very
hand-over that gives that side its turn, and nobody would ever see it. Caught by the expiry test
asserting the thing the feature is for rather than the number in the file.

**The marker is a ripple drawn at the diameter of its own error radius**, so its size *is* the
uncertainty rather than a legend to learn — a noise near your own troops is small and tight, one far
away is large and vague. Never a silhouette, which is read as a tank; never a wedge, which points down
a bearing this layer does not store. The rings had to be widened once: `_write` fades an edge from the
rim colour inward over `RIM_TEXELS`, so a band thinner than about `RIM + EDGE` never reaches the body
colour anywhere and comes out uniformly dark, with `modulate` then multiplying the tint into
near-black. Rings thick enough to have an interior are rings few enough to fit, hence two.

Also fixed on the way past: **`look` had two `roster` blocks.** A duplicate key in JSON is not an
error — the later one simply wins — so `width_px` had silently been reading 210 rather than the 180
next to the note explaining it, and `look.roster.selected_colour`, which `RosterPanel.setup` reads,
had been falling back to a default nobody chose and landing in `cfg.missing` where no test looks.
`test_config` checks a curated path list, which is why it never showed.

**Next.** None of the presentation half has been looked at, and it is the half only eyes can judge:
whether a ripple at 0.40 alpha reads over terraced flat-shaded ground, whether two rings read as a
ripple or as a target reticle, and whether the violet is far enough from the amber and cyan already on
screen. Worth watching specifically: the marker is sized in real metres, so at `error_max_m` it is a
400 m circle, and the interaction between that and the movement overlay is not something I can
reason about.

The layer also goes quiet exactly when the board is busiest — once both sides are in contact almost
nothing is heard, because almost everything is seen. That is correct, and it means the mechanic will
matter most in the approach phase, which is what 2f and 2g are.

Carried forward unchanged: **zone imbalance still fails 17 of 20 seeds** (median 37% against a 15%
limit) and still blocks pinning regression seeds — it wants its own session before 2e-ii's batch
runner leans on them. `combat.critical_chance` and `shred_share` are still suspected mistuned.
`Spotting.recompute_side` is still O(observers × targets × LOS) per tile; the sound pass does not
worsen it, casting no rays and scanning a handful of units for the nearest listener.
`MatchState.occupancy` is still ground truth, so a route bending around an empty-looking tile remains
a tell.

Still not started: 2e AI, 2f dig-in scenarios, 2g waves. `Victory` remains binary rather than graded,
and there is no turn limit.

## 2026-08-09 — Batch 2.1: the view draws from knowledge

**488 tests pass**, up from 463. Three decision records, 0034 through 0036, one of which supersedes
0032. This closes iteration 2a and finishes 2c.

Started by comparing `docs/hull-down-v2.md` against the code. The finding was sharper than expected:
**2a's simulation was complete and its last bullet was untouched.** `Spotting`, `SideKnowledge`,
`Contact`, per-tile `SPOT`/`LOST`, ghosts, optics, concealment — all built, all tested. And
`game/main.gd` spawned one `TankView` per entry in `MatchState.units`, each holding a live `UnitState`
it posed itself from, with nothing anywhere in `game/` ever setting `visible = false`.
`MatchState.contacts()`, whose own docstring says it is "what the roster panel and the ghost markers
draw", had zero callers outside the tests. So every enemy tank was on screen from the first frame and
the whole spotting model was decoration — while firing was correctly gated on `sees()`, at a target
drawn in front of you.

The fix is `ViewState` in `sim/`, and it is in `sim/` for one reason: the acceptance criterion is "an
unspotted enemy is absent from the rendered scene", a rendered scene cannot be asserted headlessly, and
a decision that cannot be tested drifts back. `tests/test_view_state.gd` is that criterion written as
15 assertions. `game/` asks three questions — may I draw this, where, and which events may I replay —
and derives none of them.

`TankView` now holds no `UnitState` at all. Not "does not read one": does not have one. While the
reference existed the leak was one line away forever, and `test_determinism.gd` now scans `game/` for a
stored `UnitState` and for the `.state.field` pattern the old one produced, alongside its existing
scans of `sim/`. It also gained `test_every_script_in_game_parses` — nothing in the suite had ever
touched `game/`, so until now a syntax error there could only be found by launching the game.

The replay is filtered **before** it plays rather than during. `ActionPlayer` was already built to hold
no simulation reference (0022), so the only way it could leak a position was by being handed one;
`play(result, events)` takes the filtered stream explicitly because a defaulted argument is one a call
site forgets. The subtle part is that the mask must be snapshotted *before* the action resolves —
resolving mutates knowledge, so a mask taken after says everything revealed had been visible all along
and the filter passes the whole stream. It fails silently. `tests/test_replay_filter.gd` pins the
ordering against streams the resolver really emits, using `test_reactions.gd`'s wall-with-a-gap fixture.

The same argument killed the first `ActionQueue` design: filtering at playback is wrong by construction
for an AI side, which resolves its whole turn before a frame is drawn. Each filtered stream now travels
with its result.

Three leaks had nothing to do with tank meshes and are worth recording because they show the shape:
hovering blank ground popped an unspotted tank's card with armour and ammunition on it; the tile
readout appended `[side 2 unit]`; and clicking an unspotted enemy refused with "nothing of yours can
see that", a sentence that only parses if something is there.

Two live bugs surfaced, both invisible until now because the game layer had never been played.
`ActionPlayer._apply` posed `_view_for(ev.unit)` from interpolation state belonging to the *acting*
unit, so a woven overwatch shot drew the ambusher standing on the mover's tile. And `play` returned on
an empty stream without emitting `finished`, contradicting its own docstring — survivable while every
stream replayed whole, a permanently locked UI the moment filtering makes empty streams routine.

**0032 is withdrawn.** The free 45° hull swivel solved a real problem in the wrong place: it let a tank
adjust the plate it presents *after* seeing the board, and it paid for that out of the overwatch system,
a coupling with no physical reading. Meanwhile the actual free action a tank has was not implemented at
all — 0027 gave the turret an absolute bearing and nothing could traverse it, so a player had no way to
point the gun without committing to a shot. `TurretAction` is free, uncapped within the arc (the
mounting is the bound; a second cap would be arithmetic in search of a reason) and legal at zero
movement points. Hull rotation always costs. Traversing a gun on overwatch re-lays the watch rather
than cancelling it — the bearing you watch down *is* where the gun points.

Also landed: the roster panel, built from `contacts()` so the enemy half starts short and grows; the
fire forecast on hover, which `player_controller.gd` had carried a comment *claiming* for a whole batch
while `preview_fire` was only ever called inside the commit path; and overwatch arcs, as the overlay
texture's alpha channel promoted to RGBA8. The arc channel is the only one carrying a **count** rather
than an enumerated state, and the only overlay drawn as a fill rather than an outline — an arc is a
claim about a volume of ground, and how much of it two arcs both cover is the information. Own-side
arcs only: an enemy's watch bearing is exactly what 0030's ambush exists to withhold.

**Next.** None of this has been looked at. The game layer had never been played before this batch and
still has not been, which is now a larger gap than it was — ghosts, wrecks, arcs, the roster and the
hand-over flip are all first drafts of things only eyes can judge. Specifically worth watching: whether
a reveal mid-path reads as a reveal or as a pop-in, whether the ghost fade is legible at two turns, and
whether the arc fill at `0.16` survives being drawn under the movement overlay.

Carried forward unchanged: **zone imbalance still fails 17 of 20 seeds** (median 37% against a 15%
limit) and blocks pinning regression seeds — it wants its own session on `place_zones`, and it should
get one before 2e-ii's batch runner starts leaning on those seeds. `combat.critical_chance` and
`shred_share` are still suspected mistuned and are now finally observable. `Spotting.recompute_side` is
still O(observers × targets × LOS) per tile; this batch does not worsen it, since `ViewState.all` reads
knowledge only and casts no rays.

One limit is stated rather than papered over: `MatchState.occupancy` is ground truth and the pathfinder
uses it, so a route bending around an empty-looking tile is still a tell. The refusal *wording* is
fixed; the routing is not. A per-side occupancy overlay changes what a legal move is and wants its own
record.

Still not started: 2d sound contacts (0033 holds the slot), 2e AI, 2f dig-in scenarios, 2g waves.
`Victory` remains binary rather than graded, and there is no turn limit.

## 2026-08-08 — Iteration 2: spotting, combat, overwatch, victory

**463 tests pass**, up from 332. Ten decision records, 0024 through 0033. Built in nine batches, each
leaving the suite green.

Six settled questions came first, and three of them changed the shape of the work. Iteration 2 is
**hot-seat** — the three-rule AI is split out, because it wants a knowledge model that has been
played against before it is written against. Spotting stays **deterministic**, which is not a
determinism nicety: `plan_move` is pure, so the hover preview can say *where you will be seen* before
you commit, and a roll would make that preview a lie half the time. And 0020's open question is
answered — optics drop from 1400/1150/900 m to **500/400/320 m**, against a measured median clear
sightline of 141 m, because at the old numbers range never bound and the optics column was
decoration.

**What the architecture resisted, and what it cost.** Four things, all found before writing code and
all cheap in the end:

- `commit` was a whole-list replay, and reaction fire needs the world updated *between* two of the
  mover's steps. `EventApplier` is now the single function that knows how an event changes the world;
  the resolver applies as it appends, `commit` replays. That made "the stream is the account of what
  happened" a **test** rather than a comment — restore the pre-action state, replay, compare — which
  was unwritable before, because `commit` was the only path and a thing always agrees with itself.
- `Los` and `VisionField` know only static terrain and have no `MatchState`. `MapData.blocker_dyn`,
  summed into `blocker_top_m`, gets wrecks into every sight test with **no signature change** and one
  extra array read. Excluded from `content_hash` and the codec, so no pinned seed moved.
- `Grid.dir_between` snaps by sign, so ten tiles east and one north reads as NE — a tank shot squarely
  in the side would have taken it on the front plate. `Armour.bearing` quantises by angle in integer
  arithmetic (169/408 for tan 22.5°, per 0010 on float determinism). There is a regression test for a
  bug that never happened.
- `Config.f` walks a dotted path per call and the weave calls it per (step × observer × target).
  `SpottingParams` and `HitParams` read once at construction — which also means a mistyped key lands
  in `cfg.missing` where a test can see it, rather than the first time somebody pulls a trigger.

**Four real bugs the tests caught**, none of them in the code they were written for: the reveal-on-fire
check sat *behind* the range early-out, so a firer hiding in woods — exactly the case worth revealing —
was thrown away first; `UnitState.create` left `swivels_left` at zero, so nobody could take their free
hull step on turn one; the `WATCH` arm never applied the action-point forfeit, so overwatch was free;
and `overwatch_arc_steps: 2` is a 180° cone, which means one watcher covers the whole approach and
choosing *where* to lay the ambush is not a decision. That last one is now 1.

**The distribution suite** is a thousand resolutions from one pinned seed. Its first test is an exact
integer identity — every shot produces exactly one terminal outcome, and `misses + shreds + shakes +
criticals + destroyed == 1000` — which is 0004's central promise and is completely retune-proof. The
band assertions are four standard errors wide, sized against *retuning* risk rather than sampling
risk, because with a fixed seed there is no sampling risk. It works only because
`HitResolver.resolve_shot` emits rather than mutates: a resolver that wrote through would degrade its
own target across the loop and the drift would look exactly like a tuning problem.

**Next.** None of the game layer has been played. Three things want eyes rather than reasoning: the
hull turning under a stationary turret (the one visible consequence of the 0027 split), a reveal
landing mid-path on the right tile, and whether an overwatch interrupt reads as an ambush or as a
stutter. The numbers in `combat` are internally consistent and untested by play — `critical_chance`
and `shred_share` are the two most likely to be wrong. Still outstanding from iteration 1: the
zone-imbalance failure (17 of 20 seeds, median 37% against a 15% limit), untouched by any of this.

Deferred deliberately: the roster panel and the ghost/overwatch markers in `game/` (the sim answers
both — `MatchState.contacts` and `overwatch_dir` — nothing draws them yet), the three-rule AI, and
sound contacts, whose *shape* is reserved by 0033 so the two knowledge layers can never be conflated.
`Spotting.recompute_side` is O(observers × targets × LOS) per tile entered: fine at three a side,
wrong at dozens, and the named fix is a per-observer cached `VisionField`.

## 2026-08-08 — Batch 1.5b, first playtest pass

Four presentation defects, **320 tests pass**. No decision record: none of this changes a rule, and
0023 already puts path decoration in 3D geometry rather than overlay bands — a ribbon is still that.

**The billboards were casting shadows.** `Sprite3D` and `Label3D` are `GeometryInstance3D` and
default to shadows on, so the selection arrow, the movement bar and both figures each threw a
quad-shaped shadow on the ground. Off everywhere, and off on the new line mesh too. Unlike the
scatter builder's `look.scatter.tree_shadows`, this is not behind a key — there is no case for an
annotation casting a shadow.

**The selection arrow was jagged, and there was no filtering fix for it.** Three things had to
change together: the rasteriser wrote alpha 1 or 0, `ALPHA_CUT_DISCARD` threw away partial alpha
even where there was some, and `TEXTURE_FILTER_NEAREST` magnified whatever survived. A hard-edged
texture filtered smoothly is a blurry staircase, so the coverage has to be in the image.

New `game/world/marker_textures.gd` rasterises from a **signed distance to a polygon** instead of an
inside-or-outside test: alpha is a `smoothstep` across about one texel, and the dark rim is a second
band of the same field, so the outline is antialiased on both of its edges rather than being a ring
of hard pixels inside a soft one. The shapes are vertex lists, which is what makes the chevron's
concave tail notch free — the sign comes from a crossing count, not from winding. Sprites pair it
with `ALPHA_CUT_DISABLED` and `LINEAR_WITH_MIPMAPS`; the two settings have to agree or the
antialiasing is not merely wasted but actively undone. Generated once at 64 px whatever size it is
drawn at, shared across units, tinted per side by `modulate`. `arrow_px` 26 → 16.

`tests/test_markers.gd` pins it, because the difference between a jagged edge and a smooth one is a
band of pixels a few wide and is not what anyone catches in a screenshot review: every shape must
have a solid interior, a silhouette, and enough partly-covered pixels to be an edge rather than a
staircase; those edge pixels must carry the *rim* colour, or mipmapping grows a pale fringe as the
marker shrinks; and the chevron's notch must read as outside.

**The route is a line now, not a row of dots — and not a row of tiles either.** The pips are gone,
and so is the shader's path fill. That fill was the original "path line": a flat 30% tint over every
tile the route entered, which however it is shaded is a ten-metre staircase. `_repaint` stops
writing the `B = 128` band, the hover outline at 255 stays, and the shader's path branch is left
standing but unfed — its comment argued the path should be a fill because outlining a one-tile-wide
region gives two parallel lines, which was true of the thing it was describing and is no longer the
question.

`PathMarkers` builds a mitred ribbon instead, through **`RoadMeshBuilder._emit_ribbon`**, which
already solves this exact problem: shared cross-sections so corners do not gap, and edge midpoints
taken at the height of the *higher* of the two tiles so the ribbon rides over a terrace lip instead
of sinking into the wall for half a tile before it. Going straight through tile centres would also
cut the corner on every diagonal. Two colour bands sharing the boundary point, split where the
action in progress runs out. About 25 segments and 150 vertices rebuilt on hover — three orders of
magnitude away from the whole-map rebuild `OverlayLayer` warns about.

Its material is unshaded vertex colour and deliberately **not** the terrain shader the road ribbon
borrows. The road shares that shader precisely so the movement and exposure overlays tint it; the
route is drawn on top of those overlays and is the one piece of ground geometry that must not be
tinted by them.

**The figures were too big and were sliced by the ground.** Half of that was simply that a quad
centred 3.2 m up has its lower half reaching back down toward the terrain — fixed by bottom
alignment and a higher anchor, plus `label_px` 26 → 15. The rest is that a billboarded quad seen at
a shallow camera angle *intersects* the ground mesh, and no amount of height or size cures that;
only `no_depth_test` does. It now shows through a hill in front, which for a transient preview
figure is the right way round, and is the trade the selection arrow already makes.

**The gunner view is available during a move again**, and it turned out the gate was hiding a real
bug rather than preventing one. `CameraDirector._follow` took the hull yaw from `_tank.state.facing`
— the *simulation's* facing — while taking the position from the animated node. Those agree exactly
whenever the tank is parked, because `snap_to_state` sets one from the other, so nothing had ever
shown it. But an action now resolves in full before a frame of it is drawn, so from the instant an
order is given `state.facing` is the heading the tank will *finish* on: dropping into the turret
mid-drive would have ridden along pointing at the destination heading while the hull underneath was
still turning. It reads the view's own yaw now. This view exists to be evidence about what the
overlay claims, and evidence has to show what is actually on screen.

The key is deliberately not gated on `is_busy()` like the rest: the gunner camera reads the tank's
pose off the view every frame and writes nothing back, so there is nothing it can desynchronise.
Orders and hover stay suspended while it is up, as they always were, and leaving it now refreshes
the tile readout — hover was suspended for the whole visit and the mouse has usually not moved.
`set_input_enabled` also no longer switches edge scroll back on underneath a follow that suppressed
it, which is newly reachable now that you can leave the gunner view mid-action.

**The gunner view was never standing where the rules say the observer stands.** Reported as "the
turret makes it hard to look behind", and the fix is not a camera offset. `eye_position()` returned
the `muzzle` marker — a child of the turret mesh at 2.3 m, which is *inside* the turret box and 30
cm below the 2.6 m `Los` and `VisionField` both read from `visibility.turret_h_m`. The docstring
claimed the height came from the same place the LOS code reads it "so the two cannot drift apart";
they had never agreed. It reads the config key now, at the tank's own XZ, which is exactly the
observer the overlay is making claims about — and 2.6 m clears the turret's top face at 2.5, so it
is a commander out of the cupola and looking backwards works. Two requests answered by making one
wrong thing right; a test asserts the eye clears the turret mesh.

**The wheel works the optic in gunner view**, multiplicatively between `gunner_fov_min_deg` and
`gunner_fov_max_deg` so a notch feels the same at 40 degrees as at 8. The look direction is still
reset on each visit — the hull may have turned while you were away — but magnification is not, since
it has nothing to do with where the tank is pointing and re-zooming to settle the same sightline
argument twice is a chore.

**Look sensitivity scales linearly with the field of view**, which is the only factor that keeps a
mouse movement pushing the image the same distance across the *screen* whatever the magnification.
Unscaled, the optic got proportionally more violent the more useful it became: at 7 degrees it
covers a quarter of the angle it does at 28, so the same flick throws the picture four times as far
and the view is unusable exactly where it is most wanted. Referenced against `gunner_fov_deg`, so
the tuned `gunner_look_sensitivity` still means what it meant and nothing needed retuning, with
`gunner_zoom_sens_scaling` at 1.0 for the full law and 0.0 for flat.

The law is a `static func` rather than three lines inline, which lets `tests/test_camera.gd` — new,
and the first test of any camera arithmetic — check it without a viewport: neutral at the starting
zoom, linear across the range, and monotonic over every notch the wheel can reach, that last being
the property that actually matters in the hand. No zoom step may make the view faster than the step
before it.

**Q and E turn 90 degrees, not 45.** A quarter turn puts a different side of the battlefield toward
the camera in one press, which is what the key is for; a facing increment took two presses to do
anything worth doing. The test that guarded it asserted the step divided the circle into exactly
eight, which was a coincidence of the old value rather than the requirement: what actually matters
is that the step divides the circle evenly *and* is a whole multiple of the 45-degree facing
increment, or the camera lands between facings and diagonals stop reading as diagonals. It asserts
that instead, and 45, 90 and 180 all pass it.

**Next.** Still unplayed since these changes: the ground arrow's orientation under `axis = AXIS_Y`
is the one thing left that reasoning cannot settle — if it comes out square to the route rather than
along it, it wants a quarter turn in `_make_ground_arrow`.

---

## 2026-08-08 — Batch 1.5b: action resolution and the presentation layer

**312 tests pass**, up from 280. Two decision records: **0022** actions resolve to an ordered event
list, **0023** the unit readout is a fixed card. They are 0022 and 0023 rather than 0021 and 0022
because the third playtest pass had already taken 0021 for the movement band.

**The simulation was downstream of an animation, and now is not.** `mark_activated` — a simulation
state transition — was called from `TankView.move_finished`, which fires when an interpolation
reaches its last leg. A unit became "done for the turn" because a lerp finished. That was also
reachable in an order nothing prevented: no key and no HUD button was gated during playback, so
pressing End Turn mid-drive ran `begin_turn()` on the unit still animating, and the completion
handler then evaluated `can_act()` against a refilled unit and marked the wrong thing.

The fix is the shape iteration 2 needs rather than a guard clause. An action now resolves in `sim/`
to an ordered `Array[ActionEvent]` — `BEGIN`, `TURN`, `STEP`, `ACTIVATED`, `END` — and the
presentation layer replays it. `MoveAction` holds the rules of one move: `legality` returns a
`Status` enum and allocates nothing, `plan` is pure, `commit` walks the events into the state.
`ActionResolver` is the sequencer and the only object that sees the whole board; it owns the
per-movement-class pathfinders and the occupancy overlay, both moved out of `PlayerController`.

Three things about it are load-bearing rather than tidy:

- **`commit` replays the event list rather than applying the path.** That makes "the stream is the
  authoritative account of what happened" a property a test checks, and it is how an interruption
  will work — an event that stops the unit at the sixth tile is the remaining events not being
  applied, with no special case anywhere.
- **The plan/resolve split is a determinism boundary.** 0005 says the combat stream advances per
  *resolved action*, which is only enforceable if exactly one function constitutes resolving one.
  `resolve_move` is it, and the only thing that will ever draw from the combat stream. `plan_move`
  is pure, so the hover preview calls it on every mouse move for free.
- **`ActionPlayer` is constructed without a reference to `MatchState`, `UnitState` or
  `ActionResolver`.** "Playback speed cannot change an outcome" is then structural rather than a
  convention someone has to remember — there is no reference it could write through. Durations come
  out of the events (`Grid.turn_steps` for a swing, tile-centre distance for a step) and are never
  measured. 1x, 3x and instant are one `_apply(event, t)` fed a differently scaled delta; instant
  and the skip key are the same function.

`UnitState.apply(path)` is deleted — two ways to move a unit is how they drift — and `TankView` lost
its animation loop, its `move_finished` signal and its two hardcoded speeds, which are now
`playback.*`. It is a pose sink with a `set_pose` and nothing else.

**Per-step cost, from the only honest source.** `PathResult` gains `step_cost` and `turn_cost`,
filled during backtracking out of the `g` values the search already holds, where the chain is still
uncollapsed and a turn can be told from a drive. Recomputing them in the resolver would be a second
copy of the cost model that can disagree with the search, and a preview that disagrees with what the
move charges is the worst bug this game can have. `sum(step_cost) + sum(turn_cost) == cost` is
pinned over every destination on a varied grid. The tile readout now says "24 mp (18 driving, 6
turning)", which explains the facing model for free.

**Occupancy needed nothing.** 1.5a had already made it a per-query blocker overlay, so the resolver
just carries `MatchState.occupancy()` through to the search. It earns a `Status.OCCUPIED` so the
player is told what is actually wrong instead of "no route", and a test pins that a tank standing in
the only doorway is routed around rather than through.

**Camera.** Q and E snap the yaw to the next multiple of 45 degrees *in the direction pressed* —
snapped rather than continuous because right-drag already does continuous, and the thing the mouse
cannot do is land on a clean angle. The grid is eight-way, so multiples of 45 are what keep
north-east pointing up-right. The trap was `_ease`'s early-out: it returned once focus and distance
had settled, which froze a step about 30 degrees in. The camera also follows the acting unit, with a
tighter lerp than the ordinary glide because at 3x the ordinary one trails thirteen metres and reads
as lag — deliberately a second fixed rate and not one scaled by the playback multiplier, which would
be animation timing feeding back into the camera. Edge scroll is suspended for the duration: the
cursor is almost always near an edge right after the click that gave the order, and the two fighting
over the focus every frame presents as "following is broken". Two edge-scroll bugs on the way past —
the band was 6 px, below the width of a window border, and there was no window-focus gate, so an
unfocused Hull Down scrolled whenever the cursor rested over its edge.

**The readout.** A billboarded arrow over the selected unit and a movement bar over every unit on
the acting side, both `fixed_size`, both hanging off **one** world anchor and separated by
`Sprite3D.offset` in texture pixels — a world-space gap between them shrinks with distance and they
overlap at nine hundred metres. Everything with a numeral in it is in a card pinned top-right
instead, because the camera spans 25 m to 1400 m over terraced flat-shaded ground the shader
deliberately does not tint. The card's layout is final today: hull, crew, ammo and criticals are
drawn now as a dimmed placeholder so iteration 2 changes a value expression and nothing moves. No
placeholder fields were added to `UnitState`. The armour, gun and optics blocks have been sitting
unread in `units.json` since the roster was written and are finally on screen, labelled as class
data rather than per-unit state.

**Path preview.** One pip per tile of the route, coloured by which action it falls in, so the ring
the overlay draws and the route agree about where the boundary is; the running total where the route
crosses it; the total at the destination; and a flat arrow on the ground showing the facing it ends
on. Pooled 3D nodes, not overlay bands — the overlay expresses region membership, an arrow's
direction needs three more bits than the highlight channel has, and the journal already records what
happens when the packed decode grows a band nobody checks.

**Also:** `tests/test_determinism.gd` is a source scan over `sim/` for unseeded `randi`/`randf`/
`randomize`, for `res://game` references, and for anything not extending `RefCounted`. All three are
stated as absolutes in CLAUDE.md and none of them was enforced by anything; a scan is blunt but it
covers the files that do not exist yet, which is most of iteration 2.

**Next.** None of the game layer has been played yet — it builds, boots headless clean and the
simulation half is covered by tests, but camera follow, Q/E, the markers and the card have not been
looked at. Two things specifically want eyes rather than reasoning: the sign of `Sprite3D.offset`
that separates the selection arrow from the bar, and which way the ground arrow's texture "up" maps
under `axis = AXIS_Y` — if it comes out square to the route it wants a quarter turn. Unchanged and
still open: the sightline band (0020) and zone imbalance failing on 17 of 20 seeds.

---

## 2026-08-08 — Third playtest pass: the action in progress

Three pieces of feedback on the movement overlay. The first two turned out to be one bug, and the
third turned out to be a bug in a test. **280 tests pass.** One decision record: 0021, movement fills
the action in progress.

**The near band was a fresh action's worth measured from wherever the tank now stands.** Drive 60 of
a 110-point action and 50 of it remain — but the overlay drew 110 again, from the new position,
handing back the movement just spent. So a short move looked free, and the misclick complaint was
exactly right: nothing on screen said the action point was nearly gone. Drawing the near band at the
*remainder of the action already in progress* fixes that, and it also fixes the other report — once
under one action's worth is left in the whole turn the near budget equals `mp_left`, the far region
empties, and the two collapse into one. Which is what 0014 said should happen and never did.

It stays derived. 0014's objection was to a stored `ap_left` drifting out of sync with `mp_left`, not
to knowing which action you are in — and since movement fills the actions in order, that follows from
what has been spent. The counterpart is `commit_action`: anything costing a whole action point
forfeits the unused fraction of the current one, or a unit banks slivers across actions and "two
actions" stops bounding anything. Nothing calls it yet; there is no non-movement action to call it.

**Two tests were measuring the wrong thing, and that is why none of this was caught.**

The three action-point tests written for 0014 each recomputed `min(action_mp, mp_left)` inline rather
than calling what the game calls. They passed unchanged through a rules change that inverted the
thing they were named after. A test that reimplements what it is testing agrees with itself whatever
the game does.

The colour guard was the same shape. `test_the_two_pip_colours_are_distinguishable` summed absolute
RGB differences and passed at 0.56 — on two colours **six degrees apart in hue**. The whole movement
UI was one amber family separated by brightness: `move_colour` at 37°, `move_far_colour` at 31°, the
far pip also at 31°. Brightness says "the same thing, further away". Hue says "a different thing".
The guard compares hue now, and the same assertion covers the overlay bands, which had no guard at
all.

So the bands are cyan for near and amber for far, walk-and-dash. Worth flagging: `rules.json` already
records that **a light-blue movement range was tried once and read as water**. It is back, and the
two differences are that it is an outline over a weak fill rather than a flat tint, and that the cyan
is pulled deliberately off the water terrain — hue 189 at value 0.88 against water's 204 at 0.47,
separated on both axes with a test asserting it. If it still reads as water on screen, the fix is to
push further toward green, not back to a brightness-only split.

**Next.** The band colours want eyes on them — the water question above is a judgement no test can
make, and `look.path.*` has no renderer yet, so the pip colours are data-and-test-only and cannot be
seen.

Still open from batch 1.5a, and untouched by any of this: **zone imbalance fails 17 of 20 seeds**,
median 37% against a 15% limit, spread 2.7% to 81%. `place_zones` scores candidate zone pairs for
balance and that spread is a lottery, not a guarantee. It is the last thing standing between the
generator and a clean §4.11 pass, and it needs its own session.


## 2026-08-08 — Batch 1.5a: terrain and movement rules

Eight items, all in `sim/`, all headless-testable. **254 tests pass**, up from 219. Five decision
records: 0015 movement classes and the traversal graph, 0016 forest tiers, 0017 roads discount the
edge, 0018 rivers are diagonally impermeable, 0019 roads as a spanning tree.

The finding that reframed the batch is in 0016 and it is about line of sight, not movement.
`Los.clear_range` blocks when a tile's cover clears the observer's eye, and the eye sits at
`turret_h_m` — **so cover height is a threshold at 2.6 m, not a dial.** A 3 m stand occludes exactly
as thoroughly as an 8 m one; a 2.2 m stand blocks nothing at all and still masks a target's hull.
That is why the sightline gate has failed on every seed the generator has ever produced, and it is
the lever the journal was looking for when it concluded that a 300 m median "needs woods nearer 3%,
which is a different kind of map". A light tier below the turret line raises sightlines without
thinning coverage at all.

What changed, in the order it landed:

- **`TraversalGraph`** — extracted from `TankPathfinder`'s edge tables. The movement overlay, the
  connectivity flood fill, the repair pass and the chokepoint min-cut had each been re-deriving the
  graph independently through the six-call `can_move → neighbour → transition → neighbour` chain,
  with nothing guaranteeing they agreed. Now one table, built once, shared. Parameterized by
  movement class: `tracked`, `wheeled`, `foot`, `amphibious` in `data/terrain.json`, with the
  per-type `move_cost` deleted so there is one source of truth.
- **The diagonal corner rule.** `can_move` checked the two adjoining level transitions and never the
  two corner *tiles*, so a tank drove diagonally between two tiles of river. One line, and the
  highest-value change in the batch. Chokepoint min-cut median fell 29 → 16 as a result, which is
  the correct number — those diagonals were never crossable.
- **Roads discount the edge.** The discount was on the tile, so a tank crossing a road at right
  angles collected it. Split into deck (passability, tile) and surface (discount, edge). The octile
  heuristic's lower bound had to move to the built edge table, or a route along a road overestimates
  and A* stops returning shortest paths.
- **Forest tiers**, promoted *after* majority smoothing and split by rank. Assigning before
  smoothing eats the dense cores — they are a minority all along their own edge.
- **Repair generalizes** to three priced ops: cut, clear, ford. The ford op is compound; a river bed
  sits metres below its banks, so the tile is raised and reclassified rather than re-marked.
- **Rivers**, as a property rather than a width. Widening was considered and deferred — it would
  have invalidated every ford, since `_detect_fords` sizes crossings before any widening.
- **Occupancy** as a per-query blocker overlay over the cached static graph.
- **Roads as an MST** over village sites and edge portals. Sites are chosen before routing; stamping
  still happens after the earthworks. Redundant edges are the pairs furthest apart *along the tree*
  and are routed at full price — at a 0.25 reuse discount a bypass otherwise retraces the road it
  was meant to short-circuit, and the network gains a duplicate rather than a loop.

Two live config bugs fixed on the way past: `TankPathfinder` read `movement.rough_extra_cost`, which
does not exist (the real key is `traversal.rough_extra_cost`, same value, so it had always silently
run on the fallback), and `tools/map_metrics.gd` printed a chokepoint target from two keys that do
not exist — the band superseded by 0009.

**Measured over twenty seeds at shipping settings**, before → after:

| metric | before | after | target |
|---|---|---|---|
| sightline median | 113 m | **141 m** | 300–900 m |
| chokepoint min-cut | 29 | 16 | 5–22% of width |
| zone imbalance | 35.3% | 37.3% | ≤ 15% |
| escarpment | 12% | 12% | 3–15% |
| passable | 96% | 94% | — |

**Next, and the two things blocking the pinned seeds.**

The sightline band is one of them and it is now a decision rather than a mystery — 0020 is where it
lands, written from the numbers above rather than before them. 141 m is a real gain and it is not
300 m; the question is whether a tank game whose guns are sighted to 900–1400 m should be fought at
a 141 m median, and the answer decides whether the forest thins further or the band moves.

The other was not on the plan and is arguably worse: **zone imbalance fails on 17 of 20 seeds**,
median 37%, against a 15% limit. `place_zones` already scores candidate zone *pairs* for balance and
it is evidently not working — the spread runs from 2.7% to 81%, which is a lottery, not a guarantee.
Nothing in this batch touched it and nothing in this batch will fix it. It wants its own look.


---

## 2026-08-08 — Second playtest pass

**Changed.** Eight pieces of feedback. **219 tests pass.** One decision record: 0014, movement spent
in two action points.

**The overlay's middle value never existed.** The movement overlay was asked for two regions — one
action's worth and two — and the near band simply did not draw. The channel is a byte, 255 for the
near band and 128 for the far, and the sampler was declared `filter_nearest, source_color`.
`source_color` makes Godot convert sRGB to linear on every read, and while the endpoints survive
that (0 stays 0, 255 stays 1.0) **128 comes back as 0.216, not 0.502** — below the 0.25 threshold
every three-state decode in the shader tests against.

That is not a new bug. The exposure channel packs masked/hull-down/exposed as 0/128/255 against the
same thresholds, so **the hull-down region has never once been drawn** — since it was written. It
was invisible because a missing region looks exactly like a region with nothing in it, and the one
number that would have contradicted it, the HUD's hull-down count, was correct all along. The
overlay is data, not colour; the sampler no longer claims otherwise.

**The shimmer was a coin flip on the tile boundary.** Reported as z-fighting between the glow and
the world up close, and it was not depth at all: the shader sampled the overlay at the fragment's
own position, so a fragment exactly on a tile boundary landed on the texel edge and `filter_nearest`
resolved it to whichever side float precision picked. Neighbouring pixels disagreed and the outline
crawled. Sampling at the *tile centre* — `(floor(xz / tile_m) + 0.5)` — makes the lookup exact and
the neighbour taps land exactly on neighbouring centres. Overlays also stop being drawn on terrace
walls now: the tile coordinate barely changes down a vertical face, which smeared the band over it,
and a wall is not ground a tank stands on.

**The tank turned a tile early.** `find_path` collapses turn-in-place states, keeping the *last*
facing held on each tile — so `facings[k]` is the facing the tank **departs** with, and the view was
driving leg k with `facings[k + 1]`, the heading for the leg after. Hence turning to the diagonal
before the step that needed it and crabbing sideways across the first tile. The docstring said
"facing on arrival", which is what made the wrong index look right; it now says what the code does,
and two tests pin it. The reverse special case underneath it was a no-op that assigned the same
value twice, and it turns out none is needed: reversing does not change facing, so `facings[k]`
already points away from the direction of travel.

**Roofs were 45 degrees out because a four-sided cone is not a box.** `_cone` puts its first base
vertex on +X, so a four-sided one has corners where an axis-aligned box has face midpoints. Phasing
it round a quarter turn fixes the angle but can still only ever be square, and a building is 6 x 7 m
— so roofs are a proper rectangular pyramid built from the footprint.

**Gunner view.** Right-drag now turns the turret: free yaw about the hull's facing, pitch clamped,
and the tactical camera is switched off outright while the gunner view owns the screen rather than
relying on `_unhandled_input` dispatch order to decide which of the two cameras reacts to the same
mouse button.

Tile picking was asking the *tactical* camera where the mouse pointed while the gunner camera was
on screen, so a first-person hover lit up unrelated tiles across the map — it picks against
`get_viewport().get_camera_3d()` now. Hover and orders are suspended in the gunner view besides: it
is a view for looking, and a right-drag to turn the turret should not also be able to become a move
order.

**Also.** Backspace ends the turn alongside Enter. A latent coplanar overlap at road junctions — the
hub polygon sits exactly on the inner ends of the stubs it covers — gets a centimetre of lift to
break the depth tie.

**Next.** Unchanged: the §4.11 metric targets are still unresolved and the seeds still cannot be
pinned. Sightlines remain woods-limited, which is a question about woods density; whether the 3–15%
escarpment band should move is the other open decision, and 0013 now has the numbers for it.

---

## 2026-08-08 — Iteration 1 revisions from the first playtest

**Changed.** Ten pieces of feedback, all addressed. **212 tests pass.** Three decision records:
0011 roads as a link layer, 0012 turn cycling pulled into iteration 1, 0013 how dramatic the
terrain can be.

**The build allowed exactly one move.** No turn structure, one unit, and `UnitState.begin_turn()`
had never been called by anything. `sim/match_state.gd` now owns the unit list, the turn number,
the active side and the selection; `sim/units/deployment.gd` puts two units a side into their
zones with no RNG. Tab cycles, Prev/Next/End Turn are the HUD's first buttons, and `end_turn`
skips sides with no units so the loop cannot stall. Selection lives in `MatchState` rather than in
`PlayerController`, which had been carrying a `_selected: bool` that nothing read — which is what
happens when state has no owner.

**Three road bugs with one cause.** `road_entry`/`road_exit` — one byte each — cannot describe a
crossing, and `roads.count` is 2. Where the two roads met, the second overwrote both bytes and
orphaned the first road's arms; the mesh builder skipped any tile with an unfilled slot. That is
all three reported symptoms at once: tiles with no geometry, arcs with gaps, turns that render
half a corner. `MapData.road_links` is now an 8-bit mask OR-ed across every road.

Two further defects came out of the rewrite:

*The ribbon was extruded per quad.* Each sample computed its own perpendicular, so consecutive
quads did not share corner vertices and every joint left a wedge notch — an eight-sample arc read
as eight separate chunks. It now carries a mitred cross-section along the polyline.

*The seam was 15 cm off, and the reasoning that said it could not be was wrong.* The endpoint
tangent of a quadratic Bezier whose control point is the tile centre **is** exactly the edge
normal, so it looked like the cross-section would land on the tile boundary for free. But the
ribbon is built from *chords*, and the chord to the first sample has already begun to curve toward
the far edge — about nine degrees at eight samples. The straight tile next door put its vertices
exactly on the boundary and the turn tile did not. Endpoint normals are now forced to the edge
axis, and `test_the_ribbon_meets_exactly_at_a_shared_edge` checks it. Worth remembering that the
derivative being right says nothing about the chord.

Also: `_edge_midpoint` averaged the two tiles' levels, which put the ribbon half a quantum *inside*
the higher tile, so the road sank into the ground on the uphill side of every terrace. `max` is
equally symmetric and rides over the step.

**Roads stopped being a terrain type.** `terrain[i] = Type.ROAD` destroyed the ground underneath,
which is why the road rendered grey on grey. The tile keeps its natural type and `road_links != 0`
overrides the going and clears the cover in `apply_terrain_attributes` — so a road through woods is
a road through woods, and a bridge is drivable because of the override rather than because the tile
was retyped. `MapCodec` to version 2; stale caches regenerate on the version check.

**Overlays are region outlines now, not tints.** A flat tint recolours the terrain, so light blue
read as water and competed with the thing it was annotating. The shader detects a region border
from four neighbour texels and the fragment's distance to that tile edge, and draws an emissive
line — `fwidth` on a world-space metre quantity keeps it one pixel wide at any camera distance.
Movement is amber, exposed red, hull-down green. Roads moved off `StandardMaterial3D` onto the
terrain shader at the same time; on their own material they had been a grey hole down the middle of
every movement region.

**Terrain: the hypothesis was wrong and the measurement was worth more than the idea.** The plan
was that repose decouples drama from drivability — lower the angle of repose and the same relief
arrives as taller hills with climbable flanks. It does not. **Impassability is itself an angle**: a
2.5 m step over a 10 m tile is 14°, and an angle does not care what scale it is measured at. Every
repose the config permits is above 14°. Measured at relief 70 over three seeds, dropping repose
from 34° to 18° moved escarpment by under one point and cost twenty to fifty times the thermal
passes — at shipping size, 471 seconds against one. The first full-scale experiment (relief 120,
repose 22°, six octaves) came out at **30.8% impassable edges** against a 3–15% band.

A second wrong belief went with it. "50 m over 2 km is 0.25 m per tile, under one quantum, so the
map is one flat terrace" confuses the *mean gradient across the map* with the *local* tile-to-tile
step. Terrain is ridged, not a ramp: the 50 m map measures 1.82 quanta per edge, nearly a metre.
`MapMetrics.relief_variety` reports that number now — reported, not gated, because the §4.11 targets
already fail on every seed.

Relief is **65 m**, which is the most the escarpment band allows: 10.7–14.3% across four seeds with
every road inside its gradient limit. 80 m puts all four over the ceiling and breaks the road limit.
The honest summary is that the ground gained about 18% in span and 15% in local step, and going
further means moving 0009's band — a decision about what kind of battlefield this is, not a tuning
knob.

**The test pipeline had not been measuring the shipping map.** `Params.small` shrinks the world and
keeps the cell and tile sizes, and its docstring gives the reason: stretching tiles instead would
quadruple every drop, so "tests would be running against terrain the game never produces". Right
principle, one axis. `target_relief_m` was still applied whole to a quarter-size world — four times
the gradient, **37% impassable edges where the shipping map measures 12%** — and that, not the road
rewrite, is what failed the road-gradient test. Relief now scales with the world's span, so what
holds constant across sizes is the gradient.

One more trap worth recording: a reduced-droplet tuning run reads three to five points pessimistic
on escarpment, because hydraulic erosion is what smooths the fine detail steep tile edges are made
of. The first pass settled on 60 m from `--hf-size 400` numbers and left real headroom unused.

**Smaller things.** Trees and buildings exist (`ScatterBuilder`, one `MultiMesh` per terrain chunk,
12k instances, shadows off) and are sized from `blocker_h` rather than a literal, so what the player
sees is the cover LOS asserts. The camera opens on the first unit at 130 m instead of 420 m and
eases to the selection rather than snapping. `window/stretch/mode` is `disabled`, which is right for
a 3D game and also fixes a latent picking bug — `TilePicker` feeds raw event positions into
`project_ray_origin`, and under a scaled canvas those are different spaces. `TilePicker.pick_ray`
had been rescanning all 40 000 tiles for the map's maximum height on every mouse-motion event.

Two Godot facts that cost time: HUD buttons must set `focus_mode = FOCUS_NONE` or the GUI eats Tab
as `ui_focus_next` before `_unhandled_input` ever sees it, and `set_anchors_preset` followed by
setting `position` leaves the offsets describing a zero-size box — `set_anchors_and_offsets_preset`
with `PRESET_MODE_MINSIZE`, applied after the children have their minimum sizes, is the one that
works.

**Next.** The §4.11 targets are still unresolved and the seeds still cannot be pinned; sightlines
remain woods-limited at ~70 m against a 300–900 m target, and that is a question about woods density
rather than about terrain. Whether the escarpment band should move is the other open decision, and
it now has numbers attached.

---

## 2026-08-07 — Mesh, camera, pathfinding, visibility, §4.9 to §4.14

**Changed.** Everything in Iteration 1 is now implemented. **175 tests pass.**

- **§4.9 / §4.10.** Terraced flat-shaded `ArrayMesh` in 25 chunks, per-water-tile surfaces, Bezier
  road ribbon, free-flying camera, HUD, and the overlay texture. `tools/screenshot.gd` renders
  fixed viewpoints so a visual check is one command.
- **§4.12.** `TankPathfinder` over (tile × facing), `DialQueue`, `PathResult`, `UnitState`, tile
  picking, orders, path preview.
- **§4.13 / §4.14.** `Los` (exact single-pair) and `VisionField` (radial sweep, all three exposure
  states from one traversal), the exposure overlay, and the gunner camera mounted at exactly the
  height the LOS rules use.
- **§4.11.** Metrics, vertex min-cut, `tools/map_metrics.gd`, `tools/gen_batch.gd`.

**Three bugs worth keeping.**

*The map rendered as floating wall strips with sky between them.* Tile tops were wound against
Godot's front-face convention and were all being culled — while the walls looked fine, because
they were being seen from the inside through the holes the missing tops left. It looked like
missing vertex colours, then a broken shader, then water drawn over the ground. `_quad` now does
the flip in one place and `test_faces_are_wound_to_face_outward` checks every triangle's winding
against its own normal.

*`DialQueue` silently lost half the search.* The buckets were an intrusive linked list keyed by the
value, so re-pushing a state — which lazy deletion does constantly — overwrote its `next` pointer
and orphaned everything behind it in that bucket. Symptom: "no route across open ground". A node
pool fixes it and allows the duplicates the algorithm needs.

*Edmonds–Karp never returned.* The `add_edge` helper was a lambda, and GDScript closures capture by
value, so every one of 360k appends copied the whole graph. The same copy-on-write trap as the
`Packed*Array` note in CLAUDE.md, wearing a different hat.

The movement overlay came in at 72 ms against a 50 ms budget until the per-edge `can_move` →
`neighbour` → `transition` call chain was replaced with a precomputed edge table. It is asserted at
the shipping map size now, on open ground, which is the worst case.

**Outstanding: the §4.11 metric targets are not met by any seed.** Twelve maps, zero passes, and
the failures are systematic rather than scattered — which is the signature of a wrong target, not a
wrong generator:

| metric | measured (12 seeds) | target |
|---|---|---|
| sightline median | 71–90 m | 300–900 m |
| hull-down | 24–36% | ≥ 5% |
| chokepoints | 19–41 | 2–6 |
| zone imbalance | 18–76% | ≤ 15% |
| escarpment edges | 7–13% | 3–15% |

Only escarpment and hull-down land where they should. The other three need a decision rather than a
tweak, and the numbers say what the decision is about:

- **Sightlines are woods-limited.** Woods stand 8 m and cover ~17% of the map, so a ray meets one
  within six tiles on average — 70 m is almost exactly `1 / 0.17` tiles. Reaching a 300 m median
  needs woods nearer 3%, which is a different kind of map. Either the target describes more open
  country than this generator makes, or woods should be sparser.
- **Chokepoints cannot be 2–6 on an open map.** A vertex min-cut between two edges of a 95%
  drivable 200-tile map is tens of tiles wide; 2–6 means a canyon. The metric is now measurable
  (the cap was raised from 8, which was reporting every map as "9"), and a fraction-of-width target
  would be scale-free and achievable.
- **Zone imbalance is noisy at zone scale.** Now measured over each zone's own footprint, per the
  spec, rather than over map halves — but a zone is only ~800 tiles and its hull-down fraction
  swings widely. Placement also picks the flattest window on each edge independently, so nothing
  balances the two against each other.

I have not retuned the bands to make them pass. Choosing between "the generator should make more
open, more funnelled maps" and "the targets describe a different game" is a design decision, and it
wants a decision record.

**Next.** Resolve those three targets, then pin the five regression seeds — which cannot happen
until a seed can pass.

---

## 2026-08-07 — Gameplay grid and roads, §4.6 to §4.8

**Changed.** The map pipeline is complete end to end: relief through roads and villages produces a
connected, playable 200×200 grid. 129 tests green.

`MapData`, `Quantizer`, `ConnectivityRepair`, `TerrainTyper`, `MapCodec`, `RoadBuilder`,
`SettlementPlacer`, plus `IntHeap` and `GridAStar`.

**The tuning was the work, not the code.** The first assembled map came out with **50% of tile
edges impassable** — a maze of cliffs with corridors through it. Three separate causes, and the
first two guesses were both wrong:

- Cutting octave count did almost nothing. Neither did the angle of repose, much.
- The actual lever is **total relief**. A 2 m drop across a 10 m tile is impassable, so anything
  over ~11° is a wall, and 220 m of relief over 2 km puts most of the map above that. Now 50 m,
  which gives 7% impassable edges — inside the 3–15% band decision 0009 asked for. It is also
  plenty: a turret sits 2.6 m up, so a 3 m fold is already a hull-down position.
- Woods came out at **0.2% of the map** because moisture was normalized against `log(n)`, which
  puts almost every tile below 0.1. Moisture is now a percentile, re-ranked *after* downsampling —
  ranking before it made the thresholds depend on the downsample ratio, so "the wetter 38%" meant
  the wetter 2% at the shipping resolution.

Bugs worth remembering, all found by tests rather than by looking:

- **Connectivity repair levelled its route backwards**, adjusting each tile against a neighbour not
  yet final, so the next step undid the edge just fixed. Sixty-five edges cut, map still
  disconnected. Forward levelling fixed it, and the same shape of bug turned up again in the road
  earthworks and once more in rounding.
- **Repair checked one representative tile per deployment zone.** A zone is 40×20 tiles of real
  terrain and is routinely split across components; it reported success on maps where two thirds of
  the zone could reach nothing. It now checks zones whole and disowns tiles it cannot connect.
- **`Params.small` stretched tiles to 40 m** instead of shrinking the world. That quadruples every
  tile-to-tile drop, so the test pipeline was running against fragmented terrain the game never
  produces. It now shrinks the map and keeps cell and tile sizes exactly as they ship.
- Objective separation was an absolute tile count, unsatisfiable on a small map, and the fallback
  abandoned the constraint entirely and stacked all three objectives on adjacent tiles. Zone and
  separation dimensions are fractions of the map now.

**Next.** §4.9 and §4.10: the terraced flat-shaded mesh, the water and road surfaces, the palette,
and the free-flying camera. First work that needs the editor rather than the test runner.

---

## 2026-08-07 — Terrain pipeline, §4.1 to §4.5

**Changed.** The continuous half of map generation is complete and green: 80 tests,
`TESTS_COMPLETE`, exit 0.

- **§4.1 skeleton.** `Rng` (splitmix64 seeding, four streams, tagged substreams), `Grid`,
  `Config`, and the headless runner. Three engine facts cost time and are now in `CLAUDE.md`: a new
  `class_name` is invisible until `--import` rebuilds the class cache; `PackedInt32Array` is not a
  constant expression, so the direction tables are `static var`; and a script that fails to parse
  still returns a `GDScript` from `load()`, so calling `new()` on it hangs a `SceneTree` tool with
  no output.
- **§4.2 base relief.** Hand-rolled ridged multifractal over `FRACTAL_NONE` samplers — Godot's
  `FRACTAL_RIDGED` lacks the per-octave weighting and produces exactly the isotropic lumps the
  check rejects. Directionality is imposed, not sampled: a per-map strike angle, coordinates
  compressed along it, plus elongated tectonic uplift bands. 1 s at 800².
- **§4.3 hydraulic erosion.** Mass drift 0.000%. The constants shipped in the plan were sized for a
  normalized 0..1 heightfield; against metres they let a single droplet level its entire step,
  which dug pits, trapped the next droplet, and stippled the uplands. Rescaled with a note in
  `rules.json` explaining the dimensionality. 40 s for 500k droplets.
- **§4.4 thermal erosion.** Converges to the angle of repose exactly. Full sweeps were too slow and
  a 400-pass cap was not enough — talus propagates one cell per pass, so a tall scarp needs passes
  proportional to how far the collapse travels. The active list makes settled ground free, so 715
  passes now cost what 400 did.
- **§4.5 hydrology.** Depression fill (priority-flood, intrusive-linked-list bucket queue), D8, Kahn
  accumulation, carving, fords. Two bugs worth recording. The carve expressed its cross-section as
  an absolute bed elevation plus a parabola, which on a steep valley wall sliced the wall down to
  the channel's own height and left a 23 m cliff at the edge of the carve radius; cutting a depth
  *relative to the local surface* fixed it (max step 23.04 → 5.40 m). And ford easing raises the
  bed after the monotonicity pass had run, so every ford broke the "rivers run downhill" check —
  the levelling pass is now a separate function called twice.

Also removed a piece of theatre: fords were gated on being naturally shallow, and rivers are carved
metres deep by construction, so that gate accepted nothing on every seed and the "fallback" repair
path was the only path that ever ran. The code now says what it does — pick the best crossings, ease
the ones that need it.

**Next.** §4.6: downsample 800→200 by area averaging, quantize to 0.5 m integer levels, classify
transitions, place zones and objectives, repair connectivity, and add `MapCodec` so the later stages
stop paying the full generation cost.

---

## 2026-08-06 — Bootstrap

**Changed.** Repository initialized from `docs/hull-down-v1.md`. Godot project created (4.7.1),
`.gitignore`, `README.md`, `CLAUDE.md` with the directory contract, the determinism contract, the
GDScript conventions, and the copy-on-write gotcha that `Packed*Array` is a value type.

Ten decision records written: the seven called for in §3, plus three covering resolutions to
ambiguities found while planning —

- **0008** facing in the pathfinding state (the spec did not say whether turning in place is legal;
  it is, and the branching factor that follows is what makes the 50 ms overlay target reachable).
- **0009** operational definitions for the map metrics. Three of the four metrics as written either
  measured the wrong thing or cost minutes per map. The sightline metric in particular: sampling
  random tile *pairs* on a 2 km square reports the geometry of the square (median separation about
  1030 m), not the terrain. Both are now computed; the ray-march version is the gate. Also added an
  escarpment-edge-fraction metric, because without it the angle-of-repose cap could silently leave
  the connectivity-repair path as dead code.
- **0010** pinned seeds and the limits of float determinism. Seeds and their metrics are committed;
  map binaries are not. A Godot upgrade can invalidate the pinned maps, and the mitigation is
  procedural rather than a test that fails on upgrade day.

`docs/design/rules.md` written, with movement, LOS, and exposure filled in and the combat sections
stubbed for iteration 2. `data/rules.json`, `terrain.json`, `units.json`, `pinned_seeds.json`
created — every tunable number in the project now has a home outside code.

**Next.** §4.1 skeleton: `sim/rng.gd` with named streams, `sim/grid.gd`, `sim/config.gd`, and the
headless test runner. Acceptance check is the runner reporting zero tests and exiting clean.
