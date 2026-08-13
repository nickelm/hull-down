extends TestCase

## Stage 4.7. The acceptance check is "woods cluster in valleys and lower slopes rather than
## scattering uniformly" — which is two separate claims, and both are asserted: woods sit low, and
## woods come in patches.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


func _map(master_seed: int) -> MapData:
	return MapGenerator.generate_small(cfg, master_seed)


func _fraction(md: MapData, type_id: int) -> float:
	var count: int = 0
	for i: int in md.n:
		if md.terrain[i] == type_id:
			count += 1
	return float(count) / float(md.n)


## Half the acceptance check: woods belong in the valleys.
func test_woods_sit_lower_than_the_map_average() -> void:
	for master_seed: int in [12345, 777]:
		var md: MapData = _map(master_seed)
		assert_not_null(md, "seed %d was rejected" % master_seed)
		if md == null:
			continue

		var woods_sum: float = 0.0
		var woods_n: int = 0
		var all_sum: float = 0.0
		for i: int in md.n:
			all_sum += float(md.level[i])
			# Any tier. Comparing against WOODS alone would silently measure only the middle third
			# of the forest once the stands are split.
			if TerrainTyper.is_woods(int(md.terrain[i])):
				woods_sum += float(md.level[i])
				woods_n += 1

		assert_gt(float(woods_n), 0.0, "seed %d has no woods at all" % master_seed)
		if woods_n == 0:
			continue
		var woods_mean: float = woods_sum / float(woods_n)
		var all_mean: float = all_sum / float(md.n)
		assert_lt(woods_mean, all_mean,
			"seed %d: woods average level %.1f, the map averages %.1f — woods are not in the valleys"
				% [master_seed, woods_mean, all_mean])


## The other half: patches, not speckle.
##
## Measured as the average size of a connected run of woods. Thresholding a smooth field produces a
## contour with single tiles scattered along both sides of it, which scores near 1; genuine stands
## score in the tens.
func test_woods_form_patches_rather_than_speckle() -> void:
	var md: MapData = _map(12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var seen := PackedByteArray()
	seen.resize(md.n)
	var patches: int = 0
	var total: int = 0
	var largest: int = 0

	var stack := PackedInt32Array()
	for start: int in md.n:
		if seen[start] != 0 or not TerrainTyper.is_woods(int(md.terrain[start])):
			continue
		patches += 1
		var size: int = 0
		stack.clear()
		stack.append(start)
		seen[start] = 1
		while stack.size() > 0:
			var c: int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			size += 1
			for d: int in 8:
				var nb: int = md.neighbor(c, d)
				if nb >= 0 and seen[nb] == 0 and TerrainTyper.is_woods(int(md.terrain[nb])):
					seen[nb] = 1
					stack.append(nb)
		total += size
		largest = maxi(largest, size)

	assert_gt(float(patches), 0.0, "no woods on the map")
	var mean_patch: float = float(total) / float(maxi(patches, 1))

	# Thresholds scale with map area. A stand of woods is a fixed size in meters, so it covers
	# sixteen times as many tiles on the full map as on the quarter-scale one the tests use —
	# comparing raw tile counts would make the same terrain pass at one resolution and fail at the
	# other.
	var area_ratio: float = float(md.n) / 40000.0
	assert_gt(mean_patch, 6.0 * area_ratio,
		"mean woods patch is %.1f tiles across %d patches — that is speckle, not forest"
			% [mean_patch, patches])
	assert_gt(float(largest), 20.0 * area_ratio,
		"the largest wood is only %d tiles on a %d tile map" % [largest, md.n])


## A tight palette needs the map to actually use it. If one type swallows the map, the terrain
## carries no information at a glance.
func test_the_terrain_mix_is_varied() -> void:
	var md: MapData = _map(12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var present: int = 0
	for k: int in cfg.type_count():
		var f: float = _fraction(md, k)
		assert_lt(f, 0.75,
			"'%s' covers %.0f%% of the map" % [cfg.terrain_names[k], f * 100.0])
		if f > 0.02:
			present += 1
	assert_ge(float(present), 4.0, "only %d terrain types are meaningfully present" % present)


## Rivers stay impassable and fords stay drivable, whatever the typing rules decide around them.
func test_water_typing_matches_the_hydrology() -> void:
	var md: MapData = _map(12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var rivers: int = 0
	var fords: int = 0
	for i: int in md.n:
		match int(md.water[i]):
			MapData.Water.RIVER:
				rivers += 1
				assert_eq(int(md.terrain[i]), TerrainTyper.Type.WATER,
					"river tile %d is not typed as water" % i)
				assert_false(md.is_passable(i), "river tile %d is drivable" % i)
			MapData.Water.FORD:
				fords += 1
				assert_eq(int(md.terrain[i]), TerrainTyper.Type.FORD,
					"ford tile %d is not typed as a ford" % i)
				assert_true(md.is_passable(i), "ford tile %d is not drivable" % i)

	assert_gt(float(rivers), 0.0, "no river tiles survived downsampling")
	assert_gt(float(fords), 0.0, "no ford tiles survived downsampling")


## Streams are wet ground, not walls. Marking every tile that contains a trickle impassable would
## wall the map off — at ten-meter tiles a stream is something you drive through.
func test_streams_do_not_block_movement() -> void:
	var md: MapData = _map(12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var streams: int = 0
	for i: int in md.n:
		if md.water[i] == MapData.Water.STREAM:
			streams += 1
			assert_true(md.is_passable(i), "stream tile %d is impassable" % i)
	assert_gt(float(streams), 0.0, "no stream tiles on the map")


## Everything downstream reads move_cost and blocker_h rather than the type, so they must actually
## be populated from terrain.json.
func test_attributes_are_copied_from_the_data_file() -> void:
	var md: MapData = _map(12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var woods_seen: bool = false
	var road_cost: int = int(round(cfg.terrain_move_cost[TerrainTyper.Type.ROAD] * 10.0))
	for i: int in md.n:
		var t: int = int(md.terrain[i])
		# A road is a surface laid over the ground, so the tile keeps its own terrain type
		# (docs/decisions/0011) — but only the *deck* half of the modifier lands on the tile. Where
		# the ground underneath is drivable the tile keeps its own cost, and the discount for
		# travelling along the road is an edge property. Cover is cleared either way.
		if md.has_road(i):
			assert_almost_eq(md.blocker_h[i], 0.0, 0.001,
				"road tile %d still carries the terrain's cover" % i)
			var natural: float = cfg.terrain_move_cost[t]
			if natural < 0.0:
				assert_eq(md.move_cost[i], road_cost,
					"the deck at tile %d did not make impassable ground standable" % i)
			else:
				assert_eq(md.move_cost[i], int(round(natural * 10.0)),
					"road tile %d took a surface discount that belongs on the edge" % i)
			continue

		var expected_cost: float = cfg.terrain_move_cost[t]
		if expected_cost < 0.0:
			assert_lt(float(md.move_cost[i]), 0.0, "tile %d should be impassable" % i)
		else:
			assert_eq(md.move_cost[i], int(round(expected_cost * 10.0)),
				"tile %d has the wrong movement cost for '%s'" % [i, cfg.terrain_names[t]])
		assert_almost_eq(md.blocker_h[i], cfg.terrain_blocker_h[t], 0.001,
			"tile %d has the wrong blocker height" % i)
		if TerrainTyper.is_woods(t):
			woods_seen = true
			assert_gt(md.blocker_h[i], 0.0, "woods must carry cover")

	assert_true(woods_seen, "no woods to check")


## Majority smoothing must not eat the features it is smoothing around.
func test_smoothing_leaves_water_and_fords_alone() -> void:
	var md := MapData.create(12)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	# A lone river tile surrounded by open ground — the exact case a majority vote would erase.
	var wet: int = md.idx(6, 6)
	md.terrain[wet] = TerrainTyper.Type.WATER
	var ford: int = md.idx(3, 3)
	md.terrain[ford] = TerrainTyper.Type.FORD

	TerrainTyper.smooth_majority(md, cfg, 3)

	assert_eq(int(md.terrain[wet]), TerrainTyper.Type.WATER, "smoothing erased an isolated river")
	assert_eq(int(md.terrain[ford]), TerrainTyper.Type.FORD, "smoothing erased a ford")


func test_smoothing_removes_isolated_speckle() -> void:
	var md := MapData.create(12)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	var speck: int = md.idx(6, 6)
	md.terrain[speck] = TerrainTyper.Type.ROCK

	TerrainTyper.smooth_majority(md, cfg, 1)
	assert_eq(int(md.terrain[speck]), TerrainTyper.Type.OPEN,
		"a single rock tile in a field of open ground survived smoothing")


# --- forest tiers ---------------------------------------------------------------------------------

## The tiers must survive majority smoothing.
##
## Smoothing replaces any tile whose neighbors hold a strict majority of one type, three passes
## over, so a dense core assigned *before* it is a minority all along its own edge and gets eaten
## back to ordinary woods almost everywhere. Promotion therefore runs after smoothing — and this is
## the assertion that catches it if that ordering is ever reversed.
func test_all_three_forest_tiers_survive_generation() -> void:
	var md: MapData = _map(12345)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var counts := {
		TerrainTyper.Type.WOODS_LIGHT: 0,
		TerrainTyper.Type.WOODS: 0,
		TerrainTyper.Type.WOODS_HEAVY: 0,
	}
	for i: int in md.n:
		var t: int = int(md.terrain[i])
		if counts.has(t):
			counts[t] = int(counts[t]) + 1

	for t2: int in counts:
		assert_gt(float(int(counts[t2])), 0.0,
			"no '%s' anywhere on the map — the tiers were smoothed away" % cfg.terrain_names[t2])


## Heavy forest is the second source of impassable ground, and it has to stay a minority of the map
## or the connectivity guarantee is being asked to do too much work.
func test_heavy_forest_is_impassable_but_stays_a_minority() -> void:
	var md: MapData = _map(777)
	assert_not_null(md, "generation failed")
	if md == null:
		return

	var heavy: int = 0
	for i: int in md.n:
		if int(md.terrain[i]) != TerrainTyper.Type.WOODS_HEAVY:
			continue
		heavy += 1
		# Unless a road runs over it, in which case the deck makes it standable.
		if not md.has_road(i):
			assert_false(md.is_passable(i), "heavy forest at tile %d is drivable" % i)

	var frac: float = float(heavy) / float(md.n)
	assert_gt(frac, 0.0, "no heavy forest was generated at all")
	assert_lt(frac, 0.12,
		"heavy forest covers %.1f%% of the map, which is a maze rather than a wood" % (frac * 100.0))


## The whole point of the light tier: it is cover a tank can see over.
##
## LOS blocks when a tile's cover clears the observer's eye line, and the eye sits at turret height.
## Light woods is below that, so a belt of it must not shorten the view — while ordinary woods, on
## the identical fixture, must stop it dead.
func test_light_forest_does_not_block_a_turret_but_ordinary_woods_does() -> void:
	var md := MapData.create(24)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)

	var observer: int = md.idx(2, 12)
	var clear: float = Los.clear_range(md, cfg, observer, Grid.E, 20)

	for y: int in md.size:
		var t: int = md.idx(8, y)
		md.terrain[t] = TerrainTyper.Type.WOODS_LIGHT
		md.blocker_h[t] = cfg.terrain_blocker_h[TerrainTyper.Type.WOODS_LIGHT]
	assert_almost_eq(Los.clear_range(md, cfg, observer, Grid.E, 20), clear, 0.001,
		"a belt of light woods shortened the view — it stands above the turret line")

	for y2: int in md.size:
		var t2: int = md.idx(8, y2)
		md.terrain[t2] = TerrainTyper.Type.WOODS
		md.blocker_h[t2] = cfg.terrain_blocker_h[TerrainTyper.Type.WOODS]
	assert_lt(Los.clear_range(md, cfg, observer, Grid.E, 20), clear,
		"a belt of ordinary woods did not block the view")


func test_every_tile_gets_a_valid_type() -> void:
	var md: MapData = _map(777)
	assert_not_null(md, "generation failed")
	if md == null:
		return
	var count: int = cfg.type_count()
	for i: int in md.n:
		assert_in_range(float(md.terrain[i]), 0.0, float(count - 1),
			"tile %d has terrain type %d, out of range" % [i, int(md.terrain[i])])
