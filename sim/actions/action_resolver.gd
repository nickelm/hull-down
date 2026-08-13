class_name ActionResolver
extends RefCounted

## The sequencer: the one object that sees the whole board when an action is resolved.
##
## `MoveAction` holds the rules of a single move. This holds everything a move needs to know about
## the rest of the match — which pathfinder answers for this unit's movement class, and which tiles
## are occupied — and it is where iteration 2 will weave interruptions from other units into the
## stream. docs/decisions/0022.
##
## The plan/resolve split is a determinism boundary, not a convenience.
## [docs/decisions/0005] says the combat stream advances **per resolved action**, and that sentence
## is only enforceable if exactly one function constitutes resolving one. `resolve_move` is it: the
## only mutator, and the only thing that will ever draw from `Rng.stream(seed, COMBAT)`. `plan_move`
## is pure and non-random, so the hover preview may call it on every mouse move and an AI may call
## it a thousand times while scoring, and no roll anywhere shifts. `_init` gains a `master_seed`
## when there is something to roll for.

var md: MapData
var cfg: Config
var state: MatchState

## The `spotting` section, read once at construction rather than per query — `SpottingParams` says
## why. Building it here is also what makes `cfg.missing` a real guard: a mistyped key is recorded
## the moment a resolver exists, not the first time somebody drives past a hedge.
var spotting: SpottingParams
## The `combat` section, read once, for the same two reasons.
var hits: HitParams
## The `sound` section, read once, for the same two reasons — docs/decisions/0037.
var sounds: SoundParams

## The two draws combat makes, constructed **once** — docs/decisions/0005.
##
## Once, not per action, and that is the rule rather than an optimisation. A generator built fresh
## each time a shot is resolved is a generator seeded identically each time, so every shot in the
## match would roll the same number. The stream advances *per resolved action* because the same
## object is asked repeatedly.
##
## Two objects, because `CRITS` is separate from `COMBAT`: adding a roll to the combat sequence must
## never change which component a critical takes out.
var _combat_rng: RandomNumberGenerator
var _crit_rng: RandomNumberGenerator

## One pathfinder per movement class actually fielded, built lazily and kept. The edge tables cost a
## fifth of a second to build and never go stale, so the only wrong answer is building them per
## query. Keyed on `UnitState.movement_class` — docs/decisions/0015.
var _pathfinders: Dictionary = {}

## Scratch for the per-step spotting deltas, reused rather than allocated. A fifteen-tile move on a
## two-sided board asks for these sixty times, and sixty throwaway arrays per order is the kind of
## cost that only shows up once there are dozens of units.
var _gained: PackedInt32Array = PackedInt32Array()
var _lost: PackedInt32Array = PackedInt32Array()
var _watchers: PackedInt32Array = PackedInt32Array()
var _shots: Array[ActionEvent] = []
var _noises: Array[ActionEvent] = []
## Which watchers actually got a round off this pass, in firing order. Needed because each one made
## its own noise from its own tile, and `fired` — a bool — cannot say who.
var _fired: PackedInt32Array = PackedInt32Array()


func _init(
	map: MapData, config: Config, match_state: MatchState, master_seed: int = 0
) -> void:
	md = map
	cfg = config
	state = match_state
	spotting = SpottingParams.from_config(config)
	hits = HitParams.from_config(config)
	sounds = SoundParams.from_config(config)
	_combat_rng = Rng.stream(master_seed, Rng.Stream.COMBAT)
	_crit_rng = Rng.stream(master_seed, Rng.Stream.CRITS)


## Hand over to the next side, and bring every side's knowledge up to date against the new board.
##
## `MatchState.end_turn` cannot do the second half: it holds the board's occupants, not the board,
## and a spotting sweep needs the ground. This is the object that can see both, which is the same
## reason the weave lives here.
##
## The sweep is deliberately kept once the reveals move onto the event stream in 0025. It is
## idempotent, it costs nothing next to a turn change, and it is the thing that catches a contact
## which changed for a reason no event described — a unit removed, a wreck appearing, a rule edited
## between saves.
func end_turn() -> void:
	state.end_turn(cfg)
	refresh_knowledge()
	Victory.tick(md, cfg, state)


## The winning side, or 0 while the match is still on.
func winner() -> int:
	return Victory.evaluate(md, cfg, state)


## Recompute every side's contacts from scratch. Changes knowledge, and nothing else.
func refresh_knowledge() -> void:
	Spotting.recompute_all(md, cfg, spotting, state)


func pathfinder_for(u: UnitState) -> TankPathfinder:
	var key: int = u.movement_class
	if not _pathfinders.has(key):
		_pathfinders[key] = TankPathfinder.new(md, cfg, TraversalGraph.build(md, cfg, key))
	return _pathfinders[key]


## Tiles this unit cannot drive through because something is standing on them. The unit itself is
## excluded, or it would block its own every move.
func blockers_for(unit_index: int) -> PackedByteArray:
	return state.occupancy(md.n, unit_index)


## Cost to reach every tile, -1 where unreachable. The movement overlay, and the cheap answer to
## "is this order hopeless" that saves running a search.
##
## Deliberately not cached here. A cache would need invalidating on every move, every turn change
## and every selection change, and a stale reachable set is a wrong overlay that looks right. The
## caller that wants one keeps it, because the caller is the thing that knows when it went stale.
func reachable(unit_index: int) -> PackedInt32Array:
	var u: UnitState = state.unit(unit_index)
	if u == null:
		return PackedInt32Array()
	return pathfinder_for(u).reachable(u.tile, u.facing, u.mp_left, blockers_for(unit_index))


func legality(
	unit_index: int, goal_tile: int, reach: PackedInt32Array = PackedInt32Array()
) -> int:
	return MoveAction.legality(cfg, state, unit_index, goal_tile, reach)


## What this move would be. Changes nothing.
func plan_move(
	unit_index: int, goal_tile: int, reach: PackedInt32Array = PackedInt32Array()
) -> ActionResult:
	var u: UnitState = state.unit(unit_index)
	if u == null:
		var r := ActionResult.new()
		r.unit = unit_index
		r.status = ActionResult.Status.NO_UNIT
		return r
	return MoveAction.plan(
		md, cfg, state, pathfinder_for(u), unit_index, goal_tile,
		reach, blockers_for(unit_index)
	)


## Resolve the move: plan it, and apply the whole thing. The only mutator in the layer.
##
## By the time this returns the simulation is completely up to date — the unit is at the
## destination, its movement points are spent, and it is marked activated if that spent the last of
## them. Nothing is left for a view to finish.
func resolve_move(
	unit_index: int, goal_tile: int, reach: PackedInt32Array = PackedInt32Array()
) -> ActionResult:
	var r: ActionResult = plan_move(unit_index, goal_tile, reach)
	if r.ok():
		_weave(r, unit_index)
		r.committed = true
	return r


## What a shot at `target` would look like. Pure, non-random, safe on every mouse move.
func preview_fire(unit_index: int, target: int) -> FireForecast:
	return FireAction.preview(md, cfg, spotting, hits, state, unit_index, target)


## Fire. The second of the two mutators, and the first thing in the game to draw from `COMBAT`.
##
## Reveals are rechecked afterwards rather than per shot: a muzzle flash reveals the firer, and a
## destroyed tank stops being a contact and starts being cover. Both are consequences of the whole
## action, not of a particular round in it.
func resolve_fire(unit_index: int, target: int) -> ActionResult:
	var r: ActionResult = FireAction.resolve(
		md, cfg, spotting, hits, state, _combat_rng, _crit_rng, unit_index, target
	)
	if not r.ok():
		return r

	for ev: ActionEvent in r.events:
		EventApplier.apply(cfg, md, state, ev)
	r.committed = true

	_spot_pass(r.events, unit_index, r.mp_after)
	# And the noise, after the reveals rather than before them — a side that the muzzle flash just
	# revealed the firer to gets the tank, not a ripple over it. `u.tile` is read back off the state
	# rather than captured beforehand because firing moves nobody, and reading it here is one fewer
	# thing that can go stale if that ever stops being true.
	_sound_pass(r.events, unit_index, SideSound.Source.FIRE, state.unit(unit_index).tile, r.mp_after)
	return r


## Go on overwatch along a bearing. Costs the whole action and ends the turn — docs/decisions/0003
## and 0030 — which is the price that makes it a decision.
func resolve_overwatch(unit_index: int, aim_dir: int) -> ActionResult:
	var r := ActionResult.new()
	r.unit = unit_index
	r.status = Overwatch.legality(md, cfg, state, unit_index, aim_dir)
	if r.status != ActionResult.Status.OK:
		return r

	r = Overwatch.plan(cfg, state, unit_index, aim_dir)
	if r.ok():
		for ev: ActionEvent in r.events:
			EventApplier.apply(cfg, md, state, ev)
		r.committed = true
	return r


## Lay the gun on an absolute bearing — docs/decisions/0035. Costs nothing and is legal at zero
## movement points, which is the whole reason it exists.
##
## Not woven. Traversing enters no new tile, so there is nothing for a per-tile spotting check to run
## on — and nothing about spotting depends on where a gun points in any case, so the contact lists
## genuinely cannot move. The sweep at the next turn boundary is the backstop if that ever stops being
## true.
func resolve_turret(unit_index: int, bearing: int) -> ActionResult:
	var r: ActionResult = TurretAction.plan(cfg, state, unit_index, bearing)
	if r.ok():
		for ev: ActionEvent in r.events:
			EventApplier.apply(cfg, md, state, ev)
		r.committed = true
	return r


## Walk the planned move, applying each event as it is appended, and splice in what the rest of the
## board does about it — docs/decisions/0025.
##
## **Applying as it walks is the whole design.** By the time the check on tile seven runs, tiles one
## through six have already happened to the `MatchState`, so `Spotting` reads the live board and needs
## no "pretend this unit is over there" parameter. That is what keeps its signature the shape a
## speculative caller wants, and it is what will let an overwatch shot on tile six see the damage the
## shot on tile four did.
##
## The order within a step is fixed and is a rule, not an implementation detail:
##
##     STEP -> spotting recheck, both sides -> (overwatch trigger) -> truncation test
##
## Spotting first, always. A watcher cannot shoot at something it has not seen, and the reveal has to
## precede the tracer in the stream so the presentation layer can put a marker down before a round
## comes out of it.
##
## Both sides every step, because the asymmetry means a mover cresting a ridge can *gain* contacts as
## well as give itself away, and both are things that happened.
func _weave(r: ActionResult, mover: int) -> void:
	var planned: Array[ActionEvent] = r.events
	var woven: Array[ActionEvent] = []
	var mp: int = r.mp_before
	var tile: int = -1
	var facing: int = -1
	var interrupted: bool = false

	for ev: ActionEvent in planned:
		match ev.kind:
			ActionEvent.Kind.BEGIN:
				_emit(woven, ev)
				tile = ev.tile
				facing = ev.facing
			ActionEvent.Kind.TURN:
				_emit(woven, ev)
				mp = ev.mp_left
				facing = ev.facing
			ActionEvent.Kind.TURRET:
				# `facing` deliberately untouched: on a TURRET the field is the turret's bearing, and
				# the tail has to close against the *hull's*.
				_emit(woven, ev)
			ActionEvent.Kind.STEP:
				_emit(woven, ev)
				mp = ev.mp_left
				tile = ev.tile
				facing = ev.facing

				# Spotting first, unconditionally — 0025. A watcher cannot shoot at what it has not
				# seen, and the reveal has to precede the tracer in the stream so the view can put a
				# marker down before a round comes out of it.
				_spot_pass(woven, mover, mp)
				if _overwatch_pass(woven, mover):
					interrupted = true
					break
				if not state.unit(mover).alive:
					break
			_:
				# ACTIVATED and END are the tail, and the tail is rebuilt below against wherever this
				# walk actually stopped. Carrying the planned one through would be a stream that ends
				# somewhere the unit is not.
				pass

	# The engine noise, once, at the tile the walk actually left the unit on — docs/decisions/0037.
	#
	# Here rather than inside the loop for a rule reason, not a cost one. One contact per *step* would
	# lay a row of ripples along the route, which draws the exact line the tank drove; a sound says
	# roughly where something is, and a track is a different and much larger claim. One contact per
	# move, at the end tile, is the claim the layer is entitled to make.
	#
	# This position also gets two things for free. It runs exactly once however the walk ended, and it
	# reads `tile` as the walk left it, so an overwatch truncation puts the noise where the tank
	# actually stopped with no special case for it anywhere. And it sits outside the per-step order
	# documented above rather than perturbing it.
	#
	# A mover killed on the way emits nothing: the wreck is on that tile now, it is cover for both
	# sides and it is not a secret, so a guess about where it might be would be strictly worse
	# information than what the board already shows.
	var moved: UnitState = state.unit(mover)
	if moved != null and moved.alive and sounds.is_noisy_move(moved.mp_moved, moved.mp_max):
		_sound_pass(woven, mover, SideSound.Source.MOVE, tile, mp)

	var tail_from: int = woven.size()
	MoveAction.close_stream(cfg, woven, mover, tile, facing, mp)
	for k: int in range(tail_from, woven.size()):
		EventApplier.apply(cfg, md, state, woven[k])

	r.events = woven
	r.mp_after = mp
	r.interrupted = interrupted


## Everything that shot at the mover on the tile it has just entered. True if the move stops here.
##
## **The mover keeps whatever movement it had left.** Being shot at costs tempo, not the turn — 0021's
## forfeit rule is about *paying* for a whole action, and taking fire is not a payment. The tank stops
## where it stands and can be ordered on again, into the same ambush if the player insists.
func _overwatch_pass(woven: Array[ActionEvent], mover: int) -> bool:
	Overwatch.watchers_against(md, cfg, spotting, state, mover, _watchers)
	if _watchers.is_empty():
		return false

	var fired: bool = false
	_fired.clear()
	for k: int in _watchers.size():
		var watcher: int = _watchers[k]
		# Re-tested per watcher rather than trusted from the sweep above: an earlier watcher in this
		# same pass may have killed the mover, and a corpse is not a target.
		if not Overwatch.triggers(md, cfg, spotting, state, watcher, mover):
			continue

		var exposure: int = Spotting.exposure_between(md, cfg, state, watcher, mover)
		_shots.clear()
		HitResolver.resolve_shot(
			md, cfg, hits, state, _combat_rng, _crit_rng,
			watcher, mover, exposure, 0, true, _shots
		)
		for ev: ActionEvent in _shots:
			_emit(woven, ev)
		fired = true
		_fired.append(watcher)

		if not state.unit(mover).alive:
			break

	# Reaction fire against the mover changes what both sides can see — a wreck is cover now, and the
	# watcher has just revealed itself by firing. Rechecked here rather than only on the next step,
	# because there may not be a next step.
	if fired:
		_spot_pass(woven, mover, state.unit(mover).mp_left)
		# Then the noise each ambusher made, in the order they fired. One pass per watcher rather
		# than one for the volley: two guns firing from two tiles are two noises, and collapsing them
		# would hide the second ambusher behind the first — precisely the thing this layer is for.
		#
		# After the reveals, so a watcher the mover's side has just spotted through its own muzzle
		# flash is drawn as a tank rather than as a guess about one. The watcher that stayed hidden —
		# out of range, or in cover — is the one that gets a ripple, which is the whole ambush.
		var mp: int = state.unit(mover).mp_left
		for k2: int in _fired.size():
			var shooter: int = _fired[k2]
			_sound_pass(woven, shooter, SideSound.Source.FIRE, state.unit(shooter).tile, mp)

	return fired and hits.overwatch_interrupts_move


## Append an event and apply it, in that order and never separately. Every mutation the weave makes
## goes through here, so "the stream is the account of what happened" is true by construction rather
## than by anyone remembering to keep two lists in step.
func _emit(woven: Array[ActionEvent], ev: ActionEvent) -> void:
	woven.append(ev)
	EventApplier.apply(cfg, md, state, ev)


## Bring every side's contacts up to date and record what changed.
##
## `recompute_side` has already mutated by the time this reads its deltas — it is the authority on the
## knowledge model, and splitting "decide" from "apply" here would put the rule in two places. The
## events it produces are therefore the *record* of a change already made, which is exactly why the
## `SPOT` and `LOST` arms of `EventApplier` are idempotent: replaying the finished stream from the
## pre-action state has to reproduce the same knowledge, and replaying it over the live state has to
## do nothing at all.
func _spot_pass(woven: Array[ActionEvent], actor: int, mp: int) -> void:
	for side: int in range(1, state.side_count + 1):
		if not Spotting.recompute_side(md, cfg, spotting, state, side, _gained, _lost):
			continue

		for i: int in _gained.size():
			var target: int = _gained[i]
			var t: UnitState = state.unit(target)
			woven.append(ActionEvent.spot(actor, target, side, t.tile, t.facing, mp))

		var k: SideKnowledge = state.knowledge_for(side)
		for j: int in _lost.size():
			var gone: int = _lost[j]
			woven.append(
				ActionEvent.lost(actor, gone, side, k.ghost_tile(gone), k.ghost_facing(gone), mp)
			)


## Turn a noise into `HEARD` events, one per side that heard it — docs/decisions/0037.
##
## The counterpart to `_spot_pass`, and note what it does *not* share with it. That one appends
## directly, because `Spotting.recompute_side` has already mutated by the time it reads the deltas;
## this one goes through `_emit`, because `Sound` mutates nothing at all and the applier is the sound
## layer's only writer. Append-and-apply therefore stays one path, which is what `_emit` is for.
##
## Always called **after** the spotting pass for the same moment, never before. The suppression rule
## is "a side that can already see it hears nothing", and that has to be evaluated against knowledge
## as it stands once the reveals for this instant have landed — otherwise a tank that gave itself away
## by firing gets a ripple drawn over the muzzle flash that revealed it.
func _sound_pass(
	woven: Array[ActionEvent], noisemaker: int, source: int, true_tile: int, mp: int
) -> void:
	_noises.clear()
	Sound.evaluate(md, sounds, state, noisemaker, source, true_tile, mp, _noises)
	for ev: ActionEvent in _noises:
		_emit(woven, ev)
