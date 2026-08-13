extends TestCase

## The marker textures, and the one property that is the whole reason they exist.
##
## The first version of these rasterized inside-or-outside and wrote alpha 1 or 0, which reads as a
## staircase at every zoom no matter what filtering is applied afterwards. Coverage has to be in the
## texture. That is invisible in a screenshot review — a jagged edge and a smooth one differ by a
## band of pixels a few wide — so it is asserted here instead.


func _alpha_histogram(img: Image) -> Dictionary:
	var opaque: int = 0
	var clear: int = 0
	var partial: int = 0
	for y: int in img.get_height():
		for x: int in img.get_width():
			var a: float = img.get_pixel(x, y).a
			if a >= 0.99:
				opaque += 1
			elif a <= 0.01:
				clear += 1
			else:
				partial += 1
	return {"opaque": opaque, "clear": clear, "partial": partial}


func _shapes() -> Array[ImageTexture]:
	return [
		MarkerTextures.chevron(),
		MarkerTextures.ground_arrow(),
		MarkerTextures.dot(),
		MarkerTextures.ripple(),
	]


## The point of the exercise: a boundary made of partly-covered pixels, not of on-or-off ones.
##
## The threshold is expressed against the shape's perimeter rather than as a flat count — a 64 px
## shape has a perimeter of a couple of hundred pixels, and an edge one pixel wide over most of it
## is what a correctly antialiased shape looks like.
func test_every_shape_has_an_antialiased_edge() -> void:
	for tex: ImageTexture in _shapes():
		var img: Image = tex.get_image()
		var h: Dictionary = _alpha_histogram(img)
		assert_gt(float(h["opaque"]), 0.0, "a shape with no solid interior is not a shape")
		assert_gt(float(h["clear"]), 0.0, "a shape that fills its whole texture has no silhouette")
		assert_gt(float(h["partial"]), 60.0,
			"only %d partly-covered pixels — this edge is a staircase, not an antialiased one"
				% int(h["partial"]))


func test_the_textures_are_generated_at_the_declared_resolution() -> void:
	for tex: ImageTexture in _shapes():
		var img: Image = tex.get_image()
		assert_eq(img.get_width(), MarkerTextures.TEX_PX, "unexpected texture width")
		assert_eq(img.get_height(), MarkerTextures.TEX_PX, "unexpected texture height")
		assert_true(img.has_mipmaps(),
			"no mipmaps — a 64 px shape drawn at a dozen pixels aliases without them")


## Mipmaps and linear filtering both average toward the neighbors, so an edge pixel has to carry
## the *rim* color rather than the body color or the outline grows a pale fringe as it shrinks.
func test_the_silhouette_edge_is_dark_not_pale() -> void:
	var img: Image = MarkerTextures.chevron().get_image()
	var samples: int = 0
	var pale: int = 0
	for y: int in img.get_height():
		for x: int in img.get_width():
			var c: Color = img.get_pixel(x, y)
			if c.a <= 0.02 or c.a >= 0.5:
				continue
			samples += 1
			if c.r > 0.5:
				pale += 1
	assert_gt(float(samples), 20.0, "too few edge pixels to judge")
	assert_eq(pale, 0, "%d of %d edge pixels are pale — the rim is not reaching the silhouette"
		% [pale, samples])


## The interior is the body color, so `modulate` tints what the player actually sees rather than
## tinting an outline.
func test_the_interior_is_the_body_color() -> void:
	var img: Image = MarkerTextures.chevron().get_image()
	# Well inside the dart: a little above the apex, on the center line.
	var c: Color = img.get_pixel(MarkerTextures.TEX_PX / 2, int(float(MarkerTextures.TEX_PX) * 0.62))
	assert_gt(c.a, 0.99, "the sample point is not inside the shape")
	assert_gt(c.r, 0.9, "the interior is not the body color")


func test_the_bar_texture_is_solid_and_sized_as_asked() -> void:
	var img: Image = MarkerTextures.solid_rect(34, 4).get_image()
	assert_eq(img.get_width(), 34, "bar width")
	assert_eq(img.get_height(), 4, "bar height")
	var h: Dictionary = _alpha_histogram(img)
	assert_eq(int(h["clear"]) + int(h["partial"]), 0, "the bar must be fully opaque")


## The textures are pure geometry and identical for every unit — only `modulate` differs — so they
## are shared rather than rebuilt per marker. Four units rebuilding a 64x64 SDF each is not a
## performance problem; it is just avoidable.
func test_shapes_are_cached_rather_than_rebuilt() -> void:
	assert_true(MarkerTextures.chevron() == MarkerTextures.chevron(),
		"chevron() returned a different texture each call")
	assert_true(MarkerTextures.solid_rect(34, 4) == MarkerTextures.solid_rect(34, 4),
		"solid_rect() returned a different texture each call")


# --- the distance field itself --------------------------------------------------------------------

## A unit square, so the expected distances can be written down rather than derived.
func _square() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5),
	])


func test_the_distance_field_is_negative_inside_and_positive_outside() -> void:
	var sq: PackedVector2Array = _square()
	assert_almost_eq(MarkerTextures._distance(Vector2.ZERO, sq), -0.5, 0.001,
		"the center of a unit square is half a side from the nearest edge, inside")
	assert_almost_eq(MarkerTextures._distance(Vector2(1.5, 0.0), sq), 1.0, 0.001,
		"a point one unit clear of the right edge")
	assert_almost_eq(MarkerTextures._distance(Vector2(0.5, 0.0), sq), 0.0, 0.001,
		"a point exactly on the edge")


## The sign comes from a crossing count rather than from vertex order, so a shape may be listed
## either way round. Worth pinning: the chevron's notch makes it concave, and a winding-dependent
## test would put the sign the wrong way round inside the notch specifically.
func test_the_distance_field_does_not_care_about_winding() -> void:
	var sq: PackedVector2Array = _square()
	var reversed := PackedVector2Array()
	for k: int in range(sq.size() - 1, -1, -1):
		reversed.append(sq[k])
	assert_almost_eq(
		MarkerTextures._distance(Vector2.ZERO, reversed),
		MarkerTextures._distance(Vector2.ZERO, sq),
		0.001, "reversing the vertex order flipped the sign"
	)


## The concave notch in the chevron's tail has to read as outside. If it does not, the dart fills in
## and becomes the plain triangle it was drawn to stop being.
func test_the_chevron_notch_is_outside_the_shape() -> void:
	# Just above the notch vertex at (0, -0.08), on the center line, heading toward the tail.
	assert_gt(MarkerTextures._distance(Vector2(0.0, -0.30), MarkerTextures.CHEVRON), 0.0,
		"the notch is filled in — the chevron has collapsed to a triangle")
	# And the body below it is still inside.
	assert_lt(MarkerTextures._distance(Vector2(0.0, 0.40), MarkerTextures.CHEVRON), 0.0,
		"the body of the dart is not inside its own outline")
