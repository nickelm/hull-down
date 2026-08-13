extends TestCase

## 2e-ii — the utility policy, the intent layer, and the promises the batch runner leans on:
## deterministic decisions, coordinated axes, a hard candidate cap, and a 30-unit turn inside the
## second. docs/decisions/0039.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _flat(size: int = 24) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, type_name: String = "medium") -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), type_name)
	u.side = side
	u.facing = Grid.E
	u.turret = Grid.E
	return u


func _resolver(md: MapData, m: MatchState, seed_value: int = 4242) -> ActionResolver:
	var r := ActionResolver.new(md, cfg, m, seed_value)
	r.refresh_knowledge()
	return r


# --- shooting --------------------------------------------------------------------------------------


func test_a_clean_kill_in_reach_is_taken() -> void:
	var md: MapData = _flat()
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12))
	m.add_unit(_unit(md, 2, 10, 12))
	var resolver: ActionResolver = _resolver(md, m)

	var policy: UtilityPolicy = UtilityPolicy.new(7)
	var order: AiOrder = policy.decide(AiView.create(resolver, 1), 0)

	assert_eq(order.kind, AiOrder.Kind.FIRE, "a 60 m flank shot at a seen enemy was not taken")
	assert_eq(order.target, 1, "the shot was aimed at the wrong unit")


func test_no_shot_is_forced_when_nothing_is_seen() -> void:
	var md: MapData = _flat(64)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 32))
	m.add_unit(_unit(md, 2, 62, 32))
	md.objectives = PackedInt32Array([md.idx(32, 32)])
	var resolver: ActionResolver = _resolver(md, m)

	var policy: UtilityPolicy = UtilityPolicy.new(7)
	var order: AiOrder = policy.decide(AiView.create(resolver, 1), 0)
	assert_eq(order.kind, AiOrder.Kind.MOVE,
		"with nothing seen and an objective ahead, the answer should be to advance")


# --- movement --------------------------------------------------------------------------------------


func test_a_turn_advances_the_force_toward_its_objective() -> void:
	var md: MapData = _flat(64)
	md.objectives = PackedInt32Array([md.idx(56, 32)])
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 28))
	m.add_unit(_unit(md, 1, 4, 32))
	m.add_unit(_unit(md, 1, 4, 36))
	m.add_unit(_unit(md, 2, 62, 2))
	var resolver: ActionResolver = _resolver(md, m)

	var before: float = 0.0
	for k: int in 3:
		before += md.dist_m(m.unit(k).tile, md.objectives[0])

	AiRunner.run_turn(resolver, UtilityPolicy.new(7))

	var after: float = 0.0
	for k2: int in 3:
		after += md.dist_m(m.unit(k2).tile, md.objectives[0])

	assert_lt(after, before, "a turn with an open road to the objective closed no distance")
	assert_true(m.all_activated(), "the advance left units undecided")


func test_the_same_seed_plays_the_same_turn() -> void:
	var results: Array = []
	for _run: int in 2:
		var md: MapData = _flat(64)
		md.objectives = PackedInt32Array([md.idx(56, 32)])
		var m: MatchState = MatchState.create(2)
		m.add_unit(_unit(md, 1, 4, 28))
		m.add_unit(_unit(md, 1, 6, 40))
		m.add_unit(_unit(md, 2, 60, 30))
		var resolver: ActionResolver = _resolver(md, m)
		AiRunner.run_turn(resolver, UtilityPolicy.new(2024))
		var tiles := PackedInt32Array()
		for u: UnitState in m.units:
			tiles.append(u.tile)
		results.append(tiles)

	assert_eq(results[0], results[1], "one seed produced two different turns")


# --- the intent layer ------------------------------------------------------------------------------


func test_intent_splits_the_force_across_the_objectives() -> void:
	var md: MapData = _flat(64)
	md.objectives = PackedInt32Array([md.idx(10, 10), md.idx(32, 50), md.idx(54, 10)])
	var m: MatchState = MatchState.create(2)
	for k: int in 6:
		m.add_unit(_unit(md, 1, 4, 8 + k * 8))
	m.add_unit(_unit(md, 2, 62, 62))
	var resolver: ActionResolver = _resolver(md, m)
	var view: AiView = AiView.create(resolver, 1)

	var intent := AiIntent.new()
	intent.refresh(view)

	var counts := PackedInt32Array([0, 0, 0])
	for i: int in view.my_units():
		counts[int(intent.assignment[i])] += 1
	for o: int in 3:
		assert_eq(counts[o], 2,
			"six units over three objectives should split two per axis, axis %d got %d"
				% [o, counts[o]])


func test_intent_is_sticky_across_turns() -> void:
	var md: MapData = _flat(64)
	md.objectives = PackedInt32Array([md.idx(10, 10), md.idx(54, 54)])
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 4))
	m.add_unit(_unit(md, 1, 4, 60))
	m.add_unit(_unit(md, 2, 62, 32))
	var resolver: ActionResolver = _resolver(md, m)
	var view: AiView = AiView.create(resolver, 1)

	var intent := AiIntent.new()
	intent.refresh(view)
	var was: Dictionary = intent.assignment.duplicate()

	# Drive unit 0 across the map: nearest-objective logic would now flip its axis.
	m.unit(0).tile = md.idx(50, 50)
	intent.refresh(view)

	assert_eq(int(intent.assignment[0]), int(was[0]),
		"an axis assignment flapped when the unit's nearest objective changed")


func test_a_dead_units_slot_is_freed() -> void:
	var md: MapData = _flat(64)
	md.objectives = PackedInt32Array([md.idx(10, 32), md.idx(54, 32)])
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 30))
	m.add_unit(_unit(md, 1, 4, 34))
	m.add_unit(_unit(md, 2, 62, 32))
	var resolver: ActionResolver = _resolver(md, m)
	var view: AiView = AiView.create(resolver, 1)

	var intent := AiIntent.new()
	intent.refresh(view)
	m.unit(0).alive = false
	intent.refresh(view)

	assert_false(intent.assignment.has(0), "a wreck still holds an axis assignment")


# --- the acceptance budget -------------------------------------------------------------------------


## 2e-ii's hard number: a 30-unit side resolves its whole turn under one second. Flat ground and
## full movement allowances make this the expensive case — every unit has ~1,500 reachable tiles
## to sample from and open lines to everything.
func test_a_thirty_unit_turn_resolves_under_a_second() -> void:
	var md: MapData = _flat(64)
	md.objectives = PackedInt32Array([md.idx(56, 16), md.idx(56, 32), md.idx(56, 48)])
	var m: MatchState = MatchState.create(2)
	for k: int in 30:
		m.add_unit(_unit(md, 1, 2 + (k % 3) * 2, 2 + (k / 3) * 6))
	for e: int in 4:
		m.add_unit(_unit(md, 2, 60, 8 + e * 14))
	var resolver: ActionResolver = _resolver(md, m)

	var t0: int = Time.get_ticks_usec()
	AiRunner.run_turn(resolver, UtilityPolicy.new(7))
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0

	assert_lt(ms, 1000.0, "a 30-unit turn took %.0f ms against a 1000 ms budget" % ms)
	assert_true(m.all_activated(), "the timed turn did not finish")


# --- the data --------------------------------------------------------------------------------------


func test_the_ai_weights_are_mounted_and_read() -> void:
	assert_true(cfg.has("ai.weights.progress_per_tile"), "ai.json is not mounted under 'ai'")
	assert_true(cfg.has("ai.candidates.max_per_unit"), "the candidate cap is missing")
	assert_true(cfg.has("ai.tie_break_epsilon"), "the tie-break epsilon is missing")
	assert_gt(float(cfg.i("ai.candidates.max_per_unit", 0)), 1.0,
		"a candidate cap below two cannot even compare staying with going")
	assert_gt(cfg.f("ai.weights.kill", 0.0), cfg.f("ai.weights.fire_threshold", 0.0),
		"a certain kill scores below the firing threshold — the AI would never shoot")
