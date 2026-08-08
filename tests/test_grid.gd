extends TestCase

## Grid indexing and the direction tables. Everything downstream indexes through these, so an
## error here is an error everywhere.


func test_index_round_trip() -> void:
	var bad: int = 0
	for i: int in Grid.COUNT:
		if Grid.idx(Grid.tx(i), Grid.ty(i)) != i:
			bad += 1
	assert_eq(bad, 0, "idx/tx/ty round trip failed on %d of %d tiles" % [bad, Grid.COUNT])


func test_index_matches_row_major() -> void:
	assert_eq(Grid.idx(0, 0), 0, "origin index")
	assert_eq(Grid.idx(Grid.SIZE - 1, 0), Grid.SIZE - 1, "end of first row")
	assert_eq(Grid.idx(0, 1), Grid.SIZE, "start of second row")
	assert_eq(Grid.idx(Grid.SIZE - 1, Grid.SIZE - 1), Grid.COUNT - 1, "last tile")


func test_direction_tables_are_unit_steps() -> void:
	assert_eq(Grid.DX.size(), 8, "DX size")
	assert_eq(Grid.DY.size(), 8, "DY size")
	for d: int in 8:
		var dx: int = Grid.DX[d]
		var dy: int = Grid.DY[d]
		assert_true(dx >= -1 and dx <= 1, "DX[%d] out of range" % d)
		assert_true(dy >= -1 and dy <= 1, "DY[%d] out of range" % d)
		assert_false(dx == 0 and dy == 0, "direction %d is a null step" % d)
		var diagonal: bool = dx != 0 and dy != 0
		assert_eq(int(Grid.IS_DIAG[d]) == 1, diagonal, "IS_DIAG[%d] disagrees with the step" % d)

	# All eight steps must be distinct.
	var seen: Dictionary = {}
	for d: int in 8:
		var key: int = Grid.DX[d] * 4 + Grid.DY[d]
		assert_false(seen.has(key), "directions %s and %d are the same step" % [str(seen.get(key)), d])
		seen[key] = d


func test_opposite_is_an_involution() -> void:
	for d: int in 8:
		assert_eq(Grid.opposite(Grid.opposite(d)), d, "opposite is not its own inverse at %d" % d)
		assert_eq(Grid.DX[Grid.opposite(d)], -Grid.DX[d], "opposite(%d) does not negate DX" % d)
		assert_eq(Grid.DY[Grid.opposite(d)], -Grid.DY[d], "opposite(%d) does not negate DY" % d)


func test_turn_steps_symmetric_and_bounded() -> void:
	for a: int in 8:
		for b: int in 8:
			var t: int = Grid.turn_steps(a, b)
			assert_eq(t, Grid.turn_steps(b, a), "turn_steps(%d,%d) is not symmetric" % [a, b])
			assert_in_range(float(t), 0.0, 4.0, "turn_steps(%d,%d) out of range" % [a, b])
			if a == b:
				assert_eq(t, 0, "turning to the current facing must be free")
	assert_eq(Grid.turn_steps(0, 4), 4, "a 180 degree turn is four steps")
	assert_eq(Grid.turn_steps(0, 7), 1, "wrapping the short way round")


func test_canonical_direction_tables_agree() -> void:
	for slot: int in Grid.CANON.size():
		var d: int = Grid.CANON[slot]
		assert_eq(Grid.CANON_SLOT[d], slot, "CANON/CANON_SLOT disagree at slot %d" % slot)
	# Exactly four directions are canonical; their opposites are not.
	var canonical: int = 0
	for d: int in 8:
		if Grid.CANON_SLOT[d] >= 0:
			canonical += 1
			assert_eq(Grid.CANON_SLOT[Grid.opposite(d)], -1,
				"direction %d and its opposite are both canonical" % d)
	assert_eq(canonical, 4, "expected exactly four canonical directions")


func test_neighbour_respects_bounds() -> void:
	# Every direction from the top-left corner that goes north or west must fall off the map.
	var corner: int = Grid.idx(0, 0)
	assert_eq(Grid.neighbour(corner, Grid.N), -1, "north from the top edge")
	assert_eq(Grid.neighbour(corner, Grid.W), -1, "west from the left edge")
	assert_eq(Grid.neighbour(corner, Grid.NW), -1, "north-west from the corner")
	assert_eq(Grid.neighbour(corner, Grid.E), Grid.idx(1, 0), "east from the corner")
	assert_eq(Grid.neighbour(corner, Grid.S), Grid.idx(0, 1), "south from the corner")

	# The east step must never wrap onto the next row.
	var row_end: int = Grid.idx(Grid.SIZE - 1, 5)
	assert_eq(Grid.neighbour(row_end, Grid.E), -1, "east from the right edge wrapped")


func test_octile_matches_brute_force() -> void:
	# Reference: shortest 8-connected path cost with orthogonal 10 and diagonal 14, no terrain.
	var bad: int = 0
	for ax: int in 12:
		for ay: int in 12:
			for bx: int in 12:
				for by: int in 12:
					var dx: int = absi(ax - bx)
					var dy: int = absi(ay - by)
					var diag: int = mini(dx, dy)
					var straight: int = maxi(dx, dy) - diag
					var reference: int = diag * 14 + straight * 10
					if Grid.octile(ax, ay, bx, by) != reference:
						bad += 1
	assert_eq(bad, 0, "octile disagreed with the brute-force cost on %d pairs" % bad)


func test_dir_between() -> void:
	assert_eq(Grid.dir_between(5, 5, 5, 4), Grid.N, "north")
	assert_eq(Grid.dir_between(5, 5, 6, 5), Grid.E, "east")
	assert_eq(Grid.dir_between(5, 5, 6, 6), Grid.SE, "south-east")
	assert_eq(Grid.dir_between(5, 5, 4, 4), Grid.NW, "north-west")
	# Distance does not matter, only the sign of each component.
	assert_eq(Grid.dir_between(0, 0, 40, 40), Grid.SE, "long diagonal still reads as south-east")
	assert_eq(Grid.dir_between(5, 5, 5, 5), -1, "no direction to the tile you are on")


func test_distance_is_metres() -> void:
	assert_almost_eq(Grid.dist_m(Grid.idx(0, 0), Grid.idx(1, 0)), Grid.TILE_M, 0.001,
		"one tile east is one tile width")
	assert_almost_eq(Grid.dist_m(Grid.idx(0, 0), Grid.idx(3, 4)), 50.0, 0.001,
		"3-4-5 triangle at 10 m tiles")
	# The map is 2 km square, so the diagonal is 2000 * sqrt(2).
	assert_almost_eq(
		Grid.dist_m(Grid.idx(0, 0), Grid.idx(Grid.SIZE - 1, Grid.SIZE - 1)),
		float(Grid.SIZE - 1) * Grid.TILE_M * sqrt(2.0), 0.01,
		"map diagonal"
	)


func test_centre_world_places_tiles_on_the_quantum() -> void:
	var p: Vector3 = Grid.centre_world(Grid.idx(0, 0), 0)
	assert_almost_eq(p.x, 5.0, 0.001, "tile centre x")
	assert_almost_eq(p.z, 5.0, 0.001, "tile centre z")
	assert_almost_eq(p.y, 0.0, 0.001, "level 0 is y = 0")
	var q: Vector3 = Grid.centre_world(Grid.idx(2, 3), 7)
	assert_almost_eq(q.x, 25.0, 0.001, "tile centre x at (2,3)")
	assert_almost_eq(q.z, 35.0, 0.001, "tile centre z at (2,3)")
	assert_almost_eq(q.y, 3.5, 0.001, "level 7 is 3.5 m")
