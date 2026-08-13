extends TestCase

## Stage 4.13. The acceptance check is that a hull-down band appears just behind each crest, which
## is asserted here on a synthetic ridge rather than eyeballed on a real map.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _flat(size: int = 24) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _hull_h() -> float:
	return cfg.f("visibility.hull_h_m", 1.4)


func _turret_h() -> float:
	return cfg.f("visibility.turret_h_m", 2.6)


# --- the three states --------------------------------------------------------------------------

func test_flat_ground_is_all_exposed() -> void:
	var md: MapData = _flat()
	var observer: int = md.idx(2, 12)
	for x: int in range(3, md.size):
		assert_eq(Los.classify(md, cfg, observer, md.idx(x, 12)), Los.Exposure.EXPOSED,
			"tile (%d,12) should be exposed across flat ground" % x)


## A wall taller than the turret hides everything behind it.
func test_a_wall_masks_what_is_behind_it() -> void:
	var md: MapData = _flat()
	# Twelve quanta is six meters, well above turret height.
	for y: int in md.size:
		md.level[md.idx(8, y)] = 12
	Quantizer.classify_transitions(md, cfg)

	var observer: int = md.idx(2, 12)
	assert_eq(Los.classify(md, cfg, observer, md.idx(6, 12)), Los.Exposure.EXPOSED,
		"ground in front of the wall should be visible")
	assert_eq(Los.classify(md, cfg, observer, md.idx(12, 12)), Los.Exposure.MASKED,
		"ground behind a six-meter wall should be masked")
	assert_eq(Los.classify(md, cfg, observer, md.idx(20, 12)), Los.Exposure.MASKED,
		"ground far behind the wall should still be masked")


## The state the game is named after.
##
## A crest that rises between hull height and turret height masks the hull and leaves the turret
## clear — so a tank sitting just behind it can see and shoot while showing only its turret. The
## band has to be somewhere: if this fails, hull down does not exist on any map.
func test_a_crest_produces_a_hull_down_band() -> void:
	var md: MapData = _flat(40)
	# Observer on the far side at ground level; a low ridge at x = 20.
	var crest_q: int = int(round((_hull_h() + (_turret_h() - _hull_h()) * 0.5) / md.quant))
	for y: int in md.size:
		md.level[md.idx(20, y)] = crest_q
	Quantizer.classify_transitions(md, cfg)

	var observer: int = md.idx(2, 20)
	var states := PackedInt32Array()
	for x: int in range(21, 34):
		states.append(Los.classify(md, cfg, observer, md.idx(x, 20)))

	var hull_down: int = 0
	for s: int in states:
		if s == Los.Exposure.HULL_DOWN:
			hull_down += 1
	assert_gt(float(hull_down), 0.0,
		"a crest of %.2f m produced no hull-down band behind it" % (float(crest_q) * md.quant))

	# And it has to be *behind* the crest, not scattered: the first tile past the crest is the most
	# sheltered ground there is.
	assert_ne(states[0], Los.Exposure.EXPOSED,
		"the tile immediately behind the crest is fully exposed")


func test_a_tile_is_visible_to_itself() -> void:
	var md: MapData = _flat()
	var t: int = md.idx(5, 5)
	assert_eq(Los.classify(md, cfg, t, t), Los.Exposure.EXPOSED, "a tank cannot hide from itself")


## Woods are opaque. Without this, cover does nothing and the terrain types are decoration.
func test_woods_block_line_of_sight() -> void:
	var md: MapData = _flat()
	var observer: int = md.idx(2, 12)
	var target: int = md.idx(16, 12)
	assert_eq(Los.classify(md, cfg, observer, target), Los.Exposure.EXPOSED, "clear to start with")

	for y: int in md.size:
		var t: int = md.idx(8, y)
		md.terrain[t] = TerrainTyper.Type.WOODS
		md.blocker_h[t] = cfg.terrain_blocker_h[TerrainTyper.Type.WOODS]
	assert_eq(Los.classify(md, cfg, observer, target), Los.Exposure.MASKED,
		"a belt of woods did not block the view")


## A tank standing in woods is not hidden from itself by its own trees — cover between you and the
## target is what matters, not cover on the target's own tile.
func test_cover_on_the_target_tile_does_not_hide_it() -> void:
	var md: MapData = _flat()
	var target: int = md.idx(10, 12)
	md.terrain[target] = TerrainTyper.Type.WOODS
	md.blocker_h[target] = 8.0
	assert_ne(Los.classify(md, cfg, md.idx(2, 12), target), Los.Exposure.MASKED,
		"a tile was masked by the cover standing on it")


# --- the sweep ---------------------------------------------------------------------------------

## The radial sweep is the interactive path and Los.classify is the authoritative one. They are
## different algorithms and must agree, or the overlay is lying about what the rules say.
func test_the_sweep_agrees_with_single_rays() -> void:
	var md: MapData = _flat(32)
	# Some relief to disagree over.
	for y: int in md.size:
		for x: int in md.size:
			md.level[md.idx(x, y)] = int(4.0 + 3.0 * sin(float(x) * 0.4) * cos(float(y) * 0.3))
	Quantizer.classify_transitions(md, cfg)

	var observer: int = md.idx(16, 16)
	var out := PackedByteArray()
	VisionField.compute(md, cfg, observer, out, 14)

	var checked: int = 0
	var disagree: int = 0
	for y2: int in range(4, 28, 3):
		for x2: int in range(4, 28, 3):
			var t: int = md.idx(x2, y2)
			if Grid.dist_m(observer, t) > 14.0 * md.tile_m:
				continue
			checked += 1
			if out[t] != Los.classify(md, cfg, observer, t):
				disagree += 1

	assert_gt(float(checked), 20.0, "not enough tiles were compared")
	# The sweep samples along rays and a single ray samples along the line between two tiles, so
	# they can differ on tiles a ray clips only at a corner. A systematic disagreement is the
	# problem; a few tiles is geometry.
	assert_lt(float(disagree), float(checked) * 0.15,
		"the sweep and single-ray tests disagree on %d of %d tiles" % [disagree, checked])


func test_the_sweep_covers_everything_in_range() -> void:
	var md: MapData = _flat(32)
	var observer: int = md.idx(16, 16)
	var out := PackedByteArray()
	VisionField.compute(md, cfg, observer, out, 12)

	# Flat ground: every tile inside the radius must have been reached and classified exposed.
	var missed: int = 0
	for y: int in range(10, 23):
		for x: int in range(10, 23):
			var t: int = md.idx(x, y)
			if Grid.dist_m(observer, t) > 11.0 * md.tile_m:
				continue
			if out[t] != Los.Exposure.EXPOSED:
				missed += 1
	assert_eq(missed, 0, "%d tiles inside the radius were left unclassified on flat ground" % missed)


func test_the_observer_sees_its_own_tile() -> void:
	var md: MapData = _flat()
	var observer: int = md.idx(10, 10)
	var out := PackedByteArray()
	VisionField.compute(md, cfg, observer, out, 8)
	assert_eq(int(out[observer]), Los.Exposure.EXPOSED, "the observer's own tile is not exposed")


func test_exposure_maps_to_distinct_overlay_values() -> void:
	var buf := PackedByteArray([
		Los.Exposure.MASKED, Los.Exposure.HULL_DOWN, Los.Exposure.EXPOSED
	])
	var ch: PackedByteArray = VisionField.to_channel(buf)
	assert_eq(int(ch[0]), 0, "masked should paint nothing")
	assert_lt(float(ch[1]), float(ch[2]), "hull down and exposed must be distinguishable")
	# The shader decodes by range: above three quarters exposed, above a quarter hull down.
	assert_gt(float(ch[2]), 191.0, "exposed must decode as exposed in the shader")
	assert_in_range(float(ch[1]), 64.0, 191.0, "hull down must decode as hull down in the shader")


# --- clear range -------------------------------------------------------------------------------

func test_clear_range_is_unlimited_on_flat_open_ground() -> void:
	var md: MapData = _flat(40)
	var reach: float = Los.clear_range(md, cfg, md.idx(2, 20), Grid.E, 30)
	assert_gt(reach, 25.0 * md.tile_m,
		"the view stopped after %.0f m on perfectly flat ground" % reach)


func test_clear_range_stops_at_a_wall() -> void:
	var md: MapData = _flat(40)
	for y: int in md.size:
		md.level[md.idx(12, y)] = 20
	Quantizer.classify_transitions(md, cfg)

	var reach: float = Los.clear_range(md, cfg, md.idx(2, 20), Grid.E, 30)
	assert_lt(reach, 12.0 * md.tile_m,
		"the view ran %.0f m past a wall ten tiles away" % reach)
	assert_gt(reach, 0.0, "the view was blocked immediately on open ground")
