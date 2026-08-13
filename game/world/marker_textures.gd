class_name MarkerTextures
extends RefCounted

## Procedural textures for the on-map markers, rasterized from a signed distance field.
##
## The project has no texture assets and should not gain any for four solid shapes, so these are
## built in code the way `OverlayLayer` builds its data texture. What is different here is *how*:
## the first version tested each pixel for inside-or-outside and wrote alpha 1 or 0, which combined
## with `ALPHA_CUT_DISCARD` and `TEXTURE_FILTER_NEAREST` to produce a staircase at every zoom. There
## is no filtering fix for that on its own — a hard-edged texture magnified smoothly is a blurry
## staircase — so the edge has to carry coverage in the first place.
##
## Distance to the polygon gives that for nothing. Alpha is a `smoothstep` across about one texel of
## the boundary, and the dark rim is a second band of the same field, so the outline is antialiased
## on both of its edges rather than being a ring of hard pixels inside a soft one.
##
## Callers pair these with `alpha_cut = ALPHA_CUT_DISABLED` and
## `texture_filter = TEXTURE_FILTER_LINEAR_WITH_MIPMAPS`. `ALPHA_CUT_DISCARD` would throw the
## coverage away again and put the staircase straight back.

## Everything is generated at this resolution whatever size it is displayed at. Mipmaps take it down
## for the small cases; a marker is never big enough on screen to want more.
const TEX_PX: int = 64

## Rim and edge widths, in texels of the generated image rather than of the screen.
const RIM_TEXELS: float = 3.0
const EDGE_TEXELS: float = 1.2

const BODY := Color(1, 1, 1, 1)
const RIM := Color(0.05, 0.06, 0.07, 1)

## A dart pointing down: apex at the bottom, shoulders above it, and a notch pulled into the tail so
## it reads as a pointer rather than as a triangle. Normalized to [-1, 1] with -1 at the top of the
## image, because that is how `_polygon` maps pixels.
##
## `static var` and not `const`: a `Packed*Array` is not a constant expression in GDScript, exactly
## as CLAUDE.md records for the direction tables in `Grid`. Treat as read-only.
static var CHEVRON := PackedVector2Array([
	Vector2(0.0, 0.95),
	Vector2(0.86, -0.52),
	Vector2(0.0, -0.08),
	Vector2(-0.86, -0.52),
])

## A stemmed arrow pointing up the image, which lies along -Z — north, which is facing 0 — once the
## sprite is laid into the ground plane with `axis = AXIS_Y`. Read-only, as above.
static var GROUND_ARROW := PackedVector2Array([
	Vector2(0.0, -0.94),
	Vector2(0.80, 0.04),
	Vector2(0.30, 0.04),
	Vector2(0.30, 0.90),
	Vector2(-0.30, 0.90),
	Vector2(-0.30, 0.04),
	Vector2(-0.80, 0.04),
])

## A pennant on a pole — the objective marker, docs/decisions/0040 and 0044. One simple outline:
## up the left of the pole, out to the pennant's tip, back to the pole, down its right side. The
## pole is ~8 texels wide, comfortably past the `RIM_TEXELS + EDGE_TEXELS` floor below which a
## shape never reaches its body color (see `ripple`). Read-only, as above.
static var FLAG := PackedVector2Array([
	Vector2(-0.61, 0.95),
	Vector2(-0.61, -0.92),
	Vector2(0.82, -0.66),
	Vector2(-0.37, -0.40),
	Vector2(-0.37, 0.95),
])

static var _cache: Dictionary = {}


static func chevron() -> ImageTexture:
	return _polygon("chevron", CHEVRON)


static func flag() -> ImageTexture:
	return _polygon("flag", FLAG)


static func ground_arrow() -> ImageTexture:
	return _polygon("ground_arrow", GROUND_ARROW)


## A dot, for anything that wants one. Built from the same field so it antialiases identically.
static func dot() -> ImageTexture:
	var key := "dot"
	if _cache.has(key):
		return _cache[key]
	var img: Image = Image.create(TEX_PX, TEX_PX, true, Image.FORMAT_RGBA8)
	var texel: float = 2.0 / float(TEX_PX)
	for y: int in TEX_PX:
		for x: int in TEX_PX:
			var p := Vector2(
				(float(x) + 0.5) * texel - 1.0,
				(float(y) + 0.5) * texel - 1.0
			)
			_write(img, x, y, p.length() - (1.0 - EDGE_TEXELS * texel), texel)
	img.generate_mipmaps()
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## Concentric rings — the sound contact's symbol, docs/decisions/0033 and 0037.
##
## A **ripple, not a silhouette and not a wedge.** Not a silhouette because the moment a sound contact
## looks like a dim tank, players read it as a ghost with a rendering bug, aim at it, and stop trusting
## the layer; not a wedge because a wedge points, and the sound layer stores no bearing to point along.
## Rings say "from somewhere around here" and nothing else, which is exactly the claim it can make.
##
## Drawn at the full extent of the image on purpose. The caller sizes the quad to the contact's error
## radius, so the outermost ring lands on the edge of the region the tank could actually be in — the
## marker's size *is* the uncertainty rather than a legend the player has to learn.
##
## Built from `abs(distance to a circle)`, which is the same field `dot()` uses folded about each
## radius, so every ring gets the identical two-sided antialiasing and the identical rim treatment. A
## polygon could not express this: `_polygon` takes a simple closed outline and a set of nested rings
## is neither simple nor closed.
## Two rings by default rather than more, and the reason is the rim. `_write` fades an edge pixel from
## the rim color to the body color over `RIM_TEXELS` inward, so a band thinner than about
## `RIM_TEXELS + EDGE_TEXELS` never reaches the body color anywhere — it comes out uniformly dark, and
## `modulate` then multiplies a tint into near-black. Rings thick enough to have an interior are rings
## few enough to fit.
static func ripple(rings: int = 2) -> ImageTexture:
	var n: int = clampi(rings, 1, 4)
	var key: String = "ripple_%d" % n
	if _cache.has(key):
		return _cache[key]

	var img: Image = Image.create(TEX_PX, TEX_PX, true, Image.FORMAT_RGBA8)
	var texel: float = 2.0 / float(TEX_PX)
	var half: float = (RIM_TEXELS + EDGE_TEXELS) * texel
	# The outermost ring's outer edge lands just inside the image, so the rim is not clipped by the
	# quad — which matters more here than elsewhere, because this quad is sized to the error radius and
	# a clipped outer ring would understate exactly the thing the marker exists to state.
	var outer: float = 1.0 - half - EDGE_TEXELS * texel

	for y: int in TEX_PX:
		for x: int in TEX_PX:
			var p := Vector2(
				(float(x) + 0.5) * texel - 1.0,
				(float(y) + 0.5) * texel - 1.0
			)
			var radial: float = p.length()
			# Distance to the *nearest* ring, so rings never interfere with one another.
			var d: float = INF
			for k: int in n:
				var radius: float = outer * float(k + 1) / float(n)
				d = minf(d, absf(radial - radius) - half)
			_write(img, x, y, d, texel)

	img.generate_mipmaps()
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## A solid white rectangle. Color comes from `modulate` and length from `region_rect`, so nothing
## built here is ever regenerated when a bar changes.
static func solid_rect(w: int, h: int) -> ImageTexture:
	var key: String = "rect_%dx%d" % [w, h]
	if _cache.has(key):
		return _cache[key]
	var img: Image = Image.create(maxi(w, 1), maxi(h, 1), false, Image.FORMAT_RGBA8)
	img.fill(BODY)
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


static func _polygon(key: String, poly: PackedVector2Array) -> ImageTexture:
	if _cache.has(key):
		return _cache[key]

	var img: Image = Image.create(TEX_PX, TEX_PX, true, Image.FORMAT_RGBA8)
	var texel: float = 2.0 / float(TEX_PX)
	for y: int in TEX_PX:
		for x: int in TEX_PX:
			var p := Vector2(
				(float(x) + 0.5) * texel - 1.0,
				(float(y) + 0.5) * texel - 1.0
			)
			_write(img, x, y, _distance(p, poly), texel)

	img.generate_mipmaps()
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## Turn a signed distance into a pixel: coverage on the outside edge, and a rim band just inside it.
##
## The rim is drawn by interpolating the *color* rather than by compositing a second shape, so the
## outer edge fades from rim color to nothing. Fading from body color instead is what produces a
## pale fringe around a dark outline.
static func _write(img: Image, x: int, y: int, d: float, texel: float) -> void:
	var aa: float = EDGE_TEXELS * texel
	var coverage: float = clampf(0.5 - d / aa, 0.0, 1.0)
	if coverage <= 0.0:
		img.set_pixel(x, y, Color(0, 0, 0, 0))
		return
	var inner: float = clampf(0.5 - (d + RIM_TEXELS * texel) / aa, 0.0, 1.0)
	var c: Color = RIM.lerp(BODY, inner)
	c.a = coverage
	img.set_pixel(x, y, c)


## Signed distance from `p` to a simple polygon, negative inside.
##
## The winding is not assumed: the sign comes from a crossing count rather than from the order the
## vertices happen to be in, so a shape can be listed either way round and a concave notch — which
## is what makes the chevron a chevron — costs nothing extra.
static func _distance(p: Vector2, poly: PackedVector2Array) -> float:
	var n: int = poly.size()
	var d: float = (p - poly[0]).length_squared()
	var s: float = 1.0
	var j: int = n - 1
	for i: int in n:
		var e: Vector2 = poly[j] - poly[i]
		var w: Vector2 = p - poly[i]
		var b: Vector2 = w - e * clampf(w.dot(e) / maxf(e.dot(e), 1e-12), 0.0, 1.0)
		d = minf(d, b.length_squared())

		var c1: bool = p.y >= poly[i].y
		var c2: bool = p.y < poly[j].y
		var c3: bool = e.x * w.y > e.y * w.x
		if (c1 and c2 and c3) or (not c1 and not c2 and not c3):
			s = -s
		j = i
	return s * sqrt(d)
