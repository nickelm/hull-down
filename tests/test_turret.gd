extends TestCase

## The hull/turret split — docs/decisions/0027.
##
## Two claims are worth more than the rest of this file put together. The turret's bearing is
## **absolute**, so a hull that turns underneath it leaves it pointing where it was. And the turret is
## **not in the pathfinding search state**, because its whole track is derivable from the hull's — if
## it ever leaks in, the search goes from 320k states to 2.56M and nothing but a fingerprint
## comparison would notice.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _open(size: int = 20) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, facing: int = Grid.E) -> UnitState:
	var u := UnitState.new()
	u.side = side
	u.tile = md.idx(x, y)
	u.facing = facing
	u.turret = facing
	u.mp_max = 220
	u.mp_left = 220
	return u


func _state(md: MapData) -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 2, 10))
	m.add_unit(_unit(md, 2, 17, 10))
	m.selected = 0
	return m


func _arc() -> int:
	return cfg.i("combat.turret_arc_steps", 3)


# --- the clamp ------------------------------------------------------------------------------------

## Anything the turret can already hold is returned untouched. With an arc of three that is seven of
## the eight bearings, so the drag is the exception and not the rule.
func test_a_bearing_inside_the_arc_is_left_alone() -> void:
	var arc: int = _arc()
	for hull: int in 8:
		for bearing: int in 8:
			if Grid.turn_steps(hull, bearing) > arc:
				continue
			assert_eq(UnitState.clamp_turret(hull, bearing, arc), bearing,
				"a bearing already inside the arc was moved (hull %d, bearing %d)" % [hull, bearing])


## Dragged to the arc's edge and no further. A turret pushed past the limit should end up as close to
## where it was pointing as the hull allows — anywhere else and the drag is losing information the
## player expects to keep.
func test_a_bearing_outside_the_arc_is_dragged_to_its_edge() -> void:
	var arc: int = _arc()
	for hull: int in 8:
		for bearing: int in 8:
			if Grid.turn_steps(hull, bearing) <= arc:
				continue
			var got: int = UnitState.clamp_turret(hull, bearing, arc)
			assert_eq(Grid.turn_steps(hull, got), arc,
				"a dragged turret did not land on the arc's edge (hull %d, bearing %d, got %d)"
					% [hull, bearing, got])


## The short way, never the long way. A turret that traversed the long way round to reach the arc's
## edge would sweep across the arc it was just told it could not leave, which looks like a bug and is
## one.
func test_the_drag_takes_the_short_way_round() -> void:
	var arc: int = 2
	# Hull north, turret pointing SE (3 steps clockwise). The edge it belongs on is E, not NW.
	assert_eq(UnitState.clamp_turret(Grid.N, Grid.SE, arc), Grid.E,
		"a turret three steps clockwise was dragged anticlockwise")
	assert_eq(UnitState.clamp_turret(Grid.N, Grid.SW, arc), Grid.W,
		"a turret three steps anticlockwise was dragged clockwise")


## An exact reversal has no short way — both edges are equally far. What matters is not which one it
## picks but that it picks the same one every time, because a tie broken differently on two runs is a
## determinism bug that only shows up when a tank is ordered to turn completely round.
func test_an_exact_reversal_breaks_its_tie_the_same_way_twice() -> void:
	var arc: int = _arc()
	for hull: int in 8:
		var opposite: int = Grid.opposite(hull)
		var first: int = UnitState.clamp_turret(hull, opposite, arc)
		assert_eq(UnitState.clamp_turret(hull, opposite, arc), first,
			"an exact reversal resolved its tie differently on the second call")
		assert_eq(Grid.turn_steps(hull, first), arc,
			"an exact reversal did not land on the arc's edge")


## An arc of four steps is the whole circle and the clamp must become the identity. This is the
## boundary the arithmetic is most likely to be wrong at, and a turret that snapped when it should
## not have would read as a mysterious aiming failure.
func test_a_full_arc_never_drags() -> void:
	for hull: int in 8:
		for bearing: int in 8:
			assert_eq(UnitState.clamp_turret(hull, bearing, 4), bearing,
				"a full arc dragged a turret (hull %d, bearing %d)" % [hull, bearing])


# --- the turret in the event stream ---------------------------------------------------------------

func _turret_events(r: ActionResult) -> Array[ActionEvent]:
	var out: Array[ActionEvent] = []
	for e: ActionEvent in r.events:
		if e.kind == ActionEvent.Kind.TURRET:
			out.append(e)
	return out


## A route that never pushes the turret past the arc emits no `TURRET` events at all. The common case
## has to cost nothing, or every stream in the game gets longer for a rule that rarely fires.
func test_a_move_within_the_arc_emits_no_turret_events() -> void:
	var md: MapData = _open()
	var m: MatchState = _state(md)
	var r: ActionResult = ActionResolver.new(md, cfg, m).plan_move(0, md.idx(8, 10))
	assert_true(r.ok(), "no route")
	assert_eq(_turret_events(r).size(), 0,
		"a straight drive dragged the turret, which means the arc is not being consulted")


## An east-facing tank ordered due west. The hull comes all the way round to W, which is four steps
## from where the gun was pointing — one more than the arc allows — so the turret has to be dragged.
## Anything less than a reversal stays inside the arc and is the case the test above covers.
func _reversal(md: MapData) -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 15, 10, Grid.E))
	m.add_unit(_unit(md, 2, 18, 2, Grid.E))
	m.selected = 0
	return m


## The drag, end to end: the turret comes round with the hull and ends up inside the arc.
func test_turning_the_hull_far_enough_drags_the_turret() -> void:
	var md: MapData = _open()
	var m: MatchState = _reversal(md)
	var u: UnitState = m.unit(0)

	var r: ActionResult = ActionResolver.new(md, cfg, m).resolve_move(0, md.idx(3, 10))
	assert_true(r.ok(), "no route")
	assert_eq(u.facing, Grid.W, "the hull did not end up heading west")

	assert_gt(float(_turret_events(r).size()), 0.0,
		"a hull that turned right round never dragged the turret")
	assert_le(float(Grid.turn_steps(u.facing, u.turret)), float(_arc()),
		"the turret ended outside the arc its hull allows")

	for e: ActionEvent in _turret_events(r):
		assert_ge(float(e.facing), 0.0, "a TURRET event carries no bearing")
		assert_eq(e.cost, 0, "traversing the turret cost movement points")


## Every `TURRET` event sits immediately after the hull `TURN` that caused it, and names a bearing
## legal for the hull *as of that turn*. Reading the stream in order has to be the same as applying
## it — that is what `EventApplier` is for, and a drag attributed to the wrong hull heading would be
## a stream that only looks right once the move is over.
func test_each_drag_follows_the_hull_turn_that_caused_it() -> void:
	var md: MapData = _open()
	var m: MatchState = _reversal(md)
	var r: ActionResult = ActionResolver.new(md, cfg, m).plan_move(0, md.idx(3, 10))
	assert_true(r.ok(), "no route")

	var drags: int = 0
	for k: int in r.events.size():
		if r.events[k].kind != ActionEvent.Kind.TURRET:
			continue
		drags += 1
		assert_gt(float(k), 0.0, "a TURRET event opened the stream")
		var prev: ActionEvent = r.events[k - 1]
		assert_eq(prev.kind, ActionEvent.Kind.TURN,
			"a turret drag was not preceded by the hull turn that caused it")
		assert_eq(Grid.turn_steps(prev.facing, r.events[k].facing), _arc(),
			"a drag did not land on the edge of the arc the hull had just reached")
	assert_gt(float(drags), 0.0, "the fixture never dragged the turret")


## Traversing is free. If a `TURRET` event ever charged, the movement invariant that every event's
## cost sums to what the search charged would break — and it is the invariant the status line, the
## preview and the simulation all read from.
func test_traversing_the_turret_is_free() -> void:
	var md: MapData = _open()
	var m: MatchState = _reversal(md)
	var before: int = m.unit(0).mp_left
	var r: ActionResult = ActionResolver.new(md, cfg, m).plan_move(0, md.idx(3, 10))
	assert_true(r.ok(), "no route")
	assert_gt(float(_turret_events(r).size()), 0.0, "the fixture never dragged the turret")

	var total: int = 0
	for e: ActionEvent in r.events:
		total += e.cost
	assert_eq(total, r.path.cost, "the turret's swing was charged against the movement budget")
	assert_eq(before - r.mp_after, r.path.cost, "the movement points do not add up to the route")


# --- the turret is not in the search state — the load-bearing claim --------------------------------

## Two plans over the same route, made with the turret starting in different places, must produce
## byte-identical **movement**. If the turret ever entered the pathfinding state this would fail, and
## nothing else in the suite would notice until the search was eight times slower.
func test_the_turret_is_not_part_of_the_route() -> void:
	var md: MapData = _open()
	var goal: int = md.idx(12, 14)

	var fingerprints := PackedInt64Array()
	for bearing: int in 8:
		var m: MatchState = _state(md)
		m.unit(0).facing = Grid.E
		m.unit(0).turret = bearing
		var r: ActionResult = ActionResolver.new(md, cfg, m).plan_move(0, goal)
		assert_true(r.ok(), "no route with the turret at %d" % bearing)

		# Movement only. The TURRET events legitimately differ — that is the drag doing its job.
		var parts := PackedStringArray()
		for e: ActionEvent in r.events:
			if e.kind != ActionEvent.Kind.TURRET:
				parts.append(e.describe())
		fingerprints.append(Rng.fnv1a("\n".join(parts)))

	for k: int in range(1, fingerprints.size()):
		assert_eq(fingerprints[k], fingerprints[0],
			"starting the turret at %d changed the route the hull took" % k)


# --- bearing on a target --------------------------------------------------------------------------

## `can_bear_on` asks about the *hull*, not about where the turret currently points. Traversing is
## free and unlimited inside the arc, so anything in the arc is already aimable — and making it depend
## on the current bearing would mean the answer changed depending on what the tank last looked at.
func test_bearing_on_a_target_depends_on_the_hull_and_not_the_turret() -> void:
	var md: MapData = _open()
	var u: UnitState = _unit(md, 1, 10, 10, Grid.N)
	var arc: int = _arc()

	for turret: int in 8:
		u.turret = turret
		for dir: int in 8:
			assert_eq(u.can_bear_on(dir, cfg), Grid.turn_steps(Grid.N, dir) <= arc,
				"bearing on %d changed with the turret at %d" % [dir, turret])

	assert_false(u.can_bear_on(-1, cfg), "a unit cannot bear on a direction that does not exist")


## A unit deploys with its gun down its hull's heading. A turret left at the constructor's default
## would start off-axis on every unit on the board, and the first thing anyone would do is turn to
## fix it.
func test_a_deployed_unit_points_its_gun_where_its_hull_points() -> void:
	var md: MapData = _open(40)
	md.deploy_zone.fill(0)
	for x: int in range(2, 10):
		for y: int in range(2, 10):
			md.deploy_zone[md.idx(x, y)] = 1

	var m: MatchState = Deployment.deploy(md, cfg, 2)
	assert_gt(float(m.units.size()), 0.0, "nothing deployed")
	for u: UnitState in m.units:
		assert_eq(u.turret, u.facing, "a deployed unit's gun does not point down its hull")
