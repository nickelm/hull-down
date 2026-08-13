extends TestCase

## Stage 4.6, first half — downsampling, quantization, transition classification, and the codec.
## These are the joints the rest of the game bolts onto, so most of them are exact-value tests
## rather than statistical ones.

var cfg: Config


func setup() -> void:
	cfg = Config.load_default()


# --- downsampling ---------------------------------------------------------------------------------

## Area averaging, not sampling. The zone-balance metric in 4.11 compares mean elevation between
## deployment zones, and a point sample would make it measure the sampling pattern instead.
func test_downsample_preserves_the_mean() -> void:
	var f := HeightField.create(16, 16, 2.5)
	var d: PackedFloat32Array = f.data
	for i: int in d.size():
		d[i] = float(i % 7) * 3.0 + float(i / 16)
	f.data = d

	var before: float = f.total_mass() / float(f.count())
	var out: PackedFloat32Array = Quantizer.downsample(f, 4)
	assert_eq(out.size(), 16, "output size")

	var after: float = 0.0
	for i2: int in out.size():
		after += out[i2]
	after /= float(out.size())
	assert_almost_eq(after, before, 0.0001, "mean elevation changed under downsampling")


func test_downsample_averages_each_block() -> void:
	var f := HeightField.create(4, 4, 1.0)
	var d: PackedFloat32Array = f.data
	# Top-left 2x2 block is 0,1,2,3 -> mean 1.5. Everything else zero.
	d[0] = 0.0
	d[1] = 1.0
	d[4] = 2.0
	d[5] = 3.0
	f.data = d

	var out: PackedFloat32Array = Quantizer.downsample(f, 2)
	assert_almost_eq(out[0], 1.5, 0.0001, "block mean")
	assert_almost_eq(out[1], 0.0, 0.0001, "empty block")


## A river is one to a few cells wide inside a sixteen-cell block, so a majority vote would erase
## every river on the map. Presence is what counts: an obstacle narrower than a tile is still an
## obstacle.
func test_a_single_river_cell_makes_the_tile_a_river() -> void:
	var src := PackedByteArray()
	src.resize(16)
	src[5] = MapData.Water.RIVER

	var out: PackedByteArray = Quantizer.downsample_water(src, 4, 1, 0.25)
	assert_eq(int(out[0]), MapData.Water.RIVER,
		"one river cell in sixteen must still make the tile a river tile")


## Streams get the opposite treatment. The drainage network is dendritic and touches nearly every
## block, so marking a tile wet on a single stream cell soaked a third of the map — and the water
## surface drawn over it hid the terrain underneath.
func test_a_stream_needs_to_cover_much_of_the_tile() -> void:
	var src := PackedByteArray()
	src.resize(16)
	src[5] = MapData.Water.STREAM

	assert_eq(int(Quantizer.downsample_water(src, 4, 1, 0.25)[0]), MapData.Water.NONE,
		"one stream cell in sixteen should not make the whole tile a stream")

	for k: int in 4:
		src[k] = MapData.Water.STREAM
	assert_eq(int(Quantizer.downsample_water(src, 4, 1, 0.25)[0]), MapData.Water.STREAM,
		"a quarter of the block being stream should make the tile a stream")


## Fords outrank rivers: a crossing is the tactically interesting fact about a tile, and it is
## rarer than the river it crosses.
func test_a_ford_outranks_the_river_it_crosses() -> void:
	var src := PackedByteArray()
	src.resize(16)
	for k: int in 8:
		src[k] = MapData.Water.RIVER
	src[9] = MapData.Water.FORD

	assert_eq(int(Quantizer.downsample_water(src, 4, 1, 0.25)[0]), MapData.Water.FORD,
		"a ford cell was outvoted by the river around it")


func test_masked_mean_ignores_dry_cells() -> void:
	var src := PackedFloat32Array()
	src.resize(4)
	src[0] = 10.0
	src[1] = 20.0
	var mask := PackedByteArray()
	mask.resize(4)
	mask[0] = 1
	mask[1] = 1

	var out: PackedFloat32Array = Quantizer.downsample_masked_mean(src, mask, 2, 1)
	assert_almost_eq(out[0], 15.0, 0.0001,
		"the water surface must average only the wet cells, not the dry ground between them")


func test_quantize_rounds_to_the_nearest_level() -> void:
	var src := PackedFloat32Array([0.0, 0.24, 0.26, 0.5, 1.74, -0.6])
	var out: PackedInt32Array = Quantizer.quantize(src, 0.5)
	assert_eq(out[0], 0, "zero")
	assert_eq(out[1], 0, "0.24 m rounds down to level 0")
	assert_eq(out[2], 1, "0.26 m rounds up to level 1")
	assert_eq(out[3], 1, "exactly half a quantum")
	assert_eq(out[4], 3, "1.74 m is level 3")
	assert_eq(out[5], -1, "negative heights quantize too")


# --- transitions ------------------------------------------------------------------------------------

## The spec's thresholds are 1 m and 2 m. At half-meter quanta that is 2 and 4, and the comparison
## is exact integer arithmetic — there is no epsilon and no "almost passable".
func test_transition_classes_at_the_exact_boundaries() -> void:
	var normal_max: int = cfg.i("traversal.normal_max_dl", 2)
	var rough_max: int = cfg.i("traversal.rough_max_dl", 4)

	assert_eq(Quantizer.classify_edge(0, 0, normal_max, rough_max), MapData.Trans.NORMAL, "flat")
	assert_eq(Quantizer.classify_edge(0, 2, normal_max, rough_max), MapData.Trans.NORMAL,
		"exactly 1.0 m is still normal")
	assert_eq(Quantizer.classify_edge(0, 3, normal_max, rough_max), MapData.Trans.ROUGH,
		"just over 1.0 m becomes rough")
	assert_eq(Quantizer.classify_edge(0, 4, normal_max, rough_max), MapData.Trans.ROUGH,
		"exactly 2.0 m is still rough")
	assert_eq(Quantizer.classify_edge(0, 5, normal_max, rough_max), MapData.Trans.BLOCKED,
		"just over 2.0 m is an escarpment")
	# Direction must not matter.
	assert_eq(Quantizer.classify_edge(5, 0, normal_max, rough_max), MapData.Trans.BLOCKED,
		"downhill classifies the same as uphill")


## Only four directions are stored; the other four read the same byte from the neighbor. Symmetry
## is therefore structural, and this test proves the lookup actually does that rather than keeping
## two copies that could drift.
func test_transitions_are_symmetric_from_both_sides() -> void:
	var md: MapData = _synthetic_slope()
	Quantizer.classify_transitions(md, cfg)

	var mismatches: int = 0
	for i: int in md.n:
		for d: int in 8:
			var nb: int = md.neighbor(i, d)
			if nb < 0:
				continue
			if md.transition(i, d) != md.transition(nb, Grid.opposite(d)):
				mismatches += 1
	assert_eq(mismatches, 0, "%d edges disagree depending on which side you ask from" % mismatches)


func test_set_transition_is_visible_from_both_sides() -> void:
	var md: MapData = _synthetic_slope()
	Quantizer.classify_transitions(md, cfg)
	var a: int = md.idx(3, 3)

	md.set_transition(a, Grid.W, MapData.Trans.BLOCKED)
	assert_eq(md.transition(a, Grid.W), MapData.Trans.BLOCKED, "writing a non-canonical direction")
	assert_eq(md.transition(md.neighbor(a, Grid.W), Grid.E), MapData.Trans.BLOCKED,
		"the neighbor must see the same edge")


func test_map_edges_are_blocked() -> void:
	var md: MapData = _synthetic_slope()
	Quantizer.classify_transitions(md, cfg)
	var corner: int = md.idx(0, 0)
	assert_eq(md.transition(corner, Grid.N), MapData.Trans.BLOCKED, "north off the map")
	assert_eq(md.transition(corner, Grid.W), MapData.Trans.BLOCKED, "west off the map")
	assert_false(md.can_move(corner, Grid.N), "you cannot drive off the map")


## A diagonal between two escarpment corners that meet at a point is legal on the graph and absurd
## on the ground.
func test_diagonal_corner_cutting_is_refused() -> void:
	var md := MapData.create(5)
	md.move_cost.fill(10)
	# Raise the two tiles that flank the north-east diagonal from (2,2).
	md.level[md.idx(3, 2)] = 20
	md.level[md.idx(2, 1)] = 20
	Quantizer.classify_transitions(md, cfg)

	var here: int = md.idx(2, 2)
	assert_false(md.can_move(here, Grid.E), "east is a wall")
	assert_false(md.can_move(here, Grid.N), "north is a wall")
	assert_false(md.can_move(here, Grid.NE),
		"the diagonal slips between two walls that meet at a corner")

	# With only one side blocked the diagonal is still refused, because the corner is still sealed.
	md.level[md.idx(2, 1)] = 0
	Quantizer.classify_transitions(md, cfg)
	assert_false(md.can_move(here, Grid.NE), "one blocked flank is enough to seal the corner")


func test_impassable_terrain_blocks_movement_regardless_of_height() -> void:
	var md := MapData.create(5)
	md.move_cost.fill(10)
	Quantizer.classify_transitions(md, cfg)
	var here: int = md.idx(2, 2)
	assert_true(md.can_move(here, Grid.E), "flat passable ground")

	md.move_cost[md.idx(3, 2)] = -10
	assert_false(md.can_move(here, Grid.E), "a flat river tile is still impassable")


func test_reclassify_around_only_touches_one_tile() -> void:
	var md: MapData = _synthetic_slope()
	Quantizer.classify_transitions(md, cfg)
	var before: PackedByteArray = md.trans.duplicate()

	var target: int = md.idx(5, 5)
	md.level[target] += 30
	Quantizer.reclassify_around(md, target, cfg)

	# Every edge touching the moved tile must be re-evaluated...
	for d: int in 8:
		var nb: int = md.neighbor(target, d)
		if nb < 0:
			continue
		var expected: int = Quantizer.classify_edge(
			md.level[target], md.level[nb],
			cfg.i("traversal.normal_max_dl", 2), cfg.i("traversal.rough_max_dl", 4)
		)
		assert_eq(md.transition(target, d), expected, "edge %d after reclassify" % d)

	# ...and a tile well away from it must be untouched.
	var far: int = md.idx(1, 1)
	for slot: int in 4:
		assert_eq(md.trans[far * 4 + slot], before[far * 4 + slot],
			"a distant tile's edges changed")


# --- height helpers --------------------------------------------------------------------------------

func test_levels_convert_to_meters() -> void:
	var md := MapData.create(4)
	md.level[0] = 7
	assert_almost_eq(md.height_m(0), 3.5, 0.0001, "seven half-meter quanta is 3.5 m")

	md.blocker_h[0] = 8.0
	assert_almost_eq(md.blocker_top_m(0), 11.5, 0.0001,
		"the line-of-sight silhouette is ground plus cover")


# --- codec ------------------------------------------------------------------------------------------

func test_codec_round_trips_exactly() -> void:
	var md: MapData = _synthetic_slope()
	Quantizer.classify_transitions(md, cfg)
	md.master_seed = 987654321
	md.terrain[3] = TerrainTyper.Type.WOODS
	md.water[4] = MapData.Water.RIVER
	md.water_level[4] = 11
	md.moisture[5] = 0.375
	md.blocker_h[3] = 8.0
	md.road_links[6] = (1 << Grid.E) | (1 << Grid.W)
	md.deploy_zone[7] = 2
	md.objectives = PackedInt32Array([10, 20, 30])
	md.move_cost[8] = -10

	var path := "user://test_codec_round_trip.hdmap"
	assert_eq(MapCodec.save(md, path), OK, "save failed")

	var back: MapData = MapCodec.load_map(path)
	assert_not_null(back, "load returned nothing")
	assert_eq(back.master_seed, md.master_seed, "seed")
	assert_eq(back.size, md.size, "size")
	assert_almost_eq(back.tile_m, md.tile_m, 0.0001, "tile size")
	assert_almost_eq(back.quant, md.quant, 0.0001, "quantum")
	assert_eq(back.content_hash(), md.content_hash(), "content hash after a round trip")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_content_hash_notices_any_change() -> void:
	var md: MapData = _synthetic_slope()
	Quantizer.classify_transitions(md, cfg)
	var base: String = md.content_hash()

	md.level[0] += 1
	assert_ne(md.content_hash(), base, "a height change did not alter the hash")
	md.level[0] -= 1
	assert_eq(md.content_hash(), base, "the hash did not come back after undoing the change")

	md.terrain[0] = TerrainTyper.Type.WOODS
	assert_ne(md.content_hash(), base, "a terrain change did not alter the hash")


func test_codec_rejects_a_file_that_is_not_a_map() -> void:
	var path := "user://test_codec_garbage.hdmap"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_32(0xDEADBEEF)
	f.store_32(1)
	f.close()

	assert_eq(MapCodec.load_map(path), null, "a file with the wrong magic must not load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# --- fixtures ---------------------------------------------------------------------------------------

## A gentle ramp with a step in the middle, so there is at least one of every transition class.
func _synthetic_slope() -> MapData:
	var md := MapData.create(12)
	md.move_cost.fill(10)
	for y: int in 12:
		for x: int in 12:
			var lv: int = x  # one quantum per tile: normal everywhere
			if x >= 6:
				lv = x + 10  # a five-quantum step at x == 6: an escarpment
			md.level[md.idx(x, y)] = lv
	return md
