class_name Palette
extends RefCounted

## Terrain colors, pulled out of terrain.json into flat arrays the mesh builder can index without
## a dictionary lookup per vertex.
##
## The one color that is not per-terrain is the cliff. Escarpment walls get their own color so a
## player can read impassable edges straight off the terrain without an overlay — which is most of
## what makes the fly-over in 4.9 legible.

var ground: PackedColorArray = PackedColorArray()
var wall: PackedColorArray = PackedColorArray()
var cliff: Color = Color(0.37, 0.35, 0.31)
var water: Color = Color(0.23, 0.37, 0.48)


static func from_config(cfg: Config) -> Palette:
	var p := Palette.new()
	var n: int = cfg.type_count()
	p.ground.resize(n)
	p.wall.resize(n)
	# Colors are authored as sRGB hex in terrain.json because that is what a human can read and
	# pick. The renderer works in linear, and vertex colors handed to a shader are taken as linear
	# as they stand — so the conversion has to happen here, once, rather than being approximated in
	# the shader on every fragment.
	for k: int in n:
		var c: Color = cfg.terrain_colors[k].srgb_to_linear()
		p.ground[k] = c
		# Vertical faces are darkened rather than left to the light, because the mesh is flat-shaded
		# from a single directional source and a wall facing away from it would otherwise read as
		# the same tone as the ground above it.
		p.wall[k] = c.darkened(0.30)
	p.cliff = cfg.cliff_color.srgb_to_linear()
	var water_type: int = cfg.type_by_name("water")
	if water_type >= 0:
		p.water = cfg.terrain_colors[water_type].srgb_to_linear()
	return p


## Slight per-tile tonal variation so a large field of one terrain type does not read as a flat
## sheet of color. Deterministic from the tile index — no RNG, and identical every time the mesh
## is rebuilt.
static func jitter(c: Color, tile: int, amount: float) -> Color:
	var h: int = Rng.fnv1a("t%d" % tile)
	var t: float = float((h >> 8) & 0xFFFF) / 65535.0
	var d: float = (t - 0.5) * 2.0 * amount
	return Color(
		clampf(c.r + d, 0.0, 1.0), clampf(c.g + d, 0.0, 1.0), clampf(c.b + d, 0.0, 1.0), c.a
	)
