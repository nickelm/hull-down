class_name PathMarkers
extends Node3D

## The path preview's decoration: a line along the route, two figures, and an arrow on the ground
## showing which way the tank ends up pointing.
##
## The reachable ring stays in the terrain shader's overlay texture, because a region is exactly
## what one texel per tile expresses well. The route does not: it used to be drawn there too, as a
## flat tint over every tile it entered, and a ten-meter staircase is a poor description of a line.
## docs/decisions/0023 put path decoration in 3D nodes for the parts the overlay cannot express;
## this is now all of them.
##
## The line is a mitred ribbon built by [RoadMeshBuilder], which already solves this exact problem
## for roads — shared cross-sections at the corners so they do not gap, and edge midpoints taken at
## the height of the *higher* of the two tiles so the ribbon rides over a terrace rather than
## sinking through it. Twenty-odd segments rebuilt on hover is microseconds; the whole-map rebuild
## `OverlayLayer` warns about is three orders of magnitude away from that.

## Apparent size of a `fixed_size` sprite goes as texture height times `pixel_size`, so keeping that
## product proportional to the configured size gives one knob per marker.
const SPRITE_UNIT: float = 0.01
const LABEL_FONT_PX: int = 32

var cfg: Config
var view: TerrainView

var _line: MeshInstance3D
var _labels: Array[Label3D] = []
var _arrow: Sprite3D

var _lift: float = 0.22
var _half_w: float = 0.8
var _label_height: float = 4.6
var _line_color: Color = Color(1.0, 0.94, 0.82)
var _line_far_color: Color = Color(0.69, 0.46, 0.23)
var _label_color: Color = Color(1.0, 0.94, 0.82)
var _break_color: Color = Color(0.88, 0.64, 0.36)


func setup(config: Config, terrain: TerrainView) -> void:
	cfg = config
	view = terrain

	# World coordinates go straight through, whatever this ends up parented to.
	top_level = true

	_lift = cfg.f("look.path.line_lift_m", 0.22)
	_half_w = maxf(cfg.f("look.path.line_width_m", 1.6), 0.05) * 0.5
	_label_height = cfg.f("look.path.label_height_m", 4.6)
	_line_color = cfg.color("look.path.line_color", Color(1.0, 0.94, 0.82))
	_line_far_color = cfg.color("look.path.line_far_color", Color(0.69, 0.46, 0.23))
	_label_color = cfg.color("look.path.label_color", Color(1.0, 0.94, 0.82))
	_break_color = cfg.color("look.path.break_label_color", Color(0.88, 0.64, 0.36))

	_line = MeshInstance3D.new()
	_line.name = "PathLine"
	_line.top_level = true
	_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_line.material_override = _line_material()
	_line.visible = false
	add_child(_line)

	_arrow = _make_ground_arrow()
	add_child(_arrow)


## Unshaded, vertex-colored, and deliberately **not** the terrain shader.
##
## The road ribbon borrows that shader precisely so the movement and exposure overlays tint it —
## without which it read as a gray hole down the middle of every region. This is the opposite case:
## the route is drawn on top of the movement overlay and has to stay legible against it, so it is
## the one piece of ground geometry that must not be tinted by it. Unshaded also means the line does
## not dim on a slope facing away from the sun, which for an annotation is what you want.
func _line_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Draw the decoration for a planned move. `near_budget` is what remains of the action in progress,
## so the line changes color at the point on this route where the reachable ring's inner boundary
## is crossed — the same limit, said twice: once as an area, once along the way you would take it.
##
## Runs on hover-tile change rather than per frame, and next to the search that produced the preview
## it is not measurable.
func show_path(result: ActionResult, near_budget: int) -> void:
	clear()
	if result == null or result.path == null or not result.path.found:
		return
	var path: PathResult = result.path
	if path.tiles.size() < 2:
		return

	# Where the route stops being affordable on the action already begun.
	var running: int = 0
	var break_at: int = -1
	var break_cost: int = 0
	for k: int in range(1, path.tiles.size()):
		running += path.tile_cost(k)
		if running > near_budget:
			break_at = k
			break_cost = running
			break

	_build_line(path, break_at)

	if break_at > 0:
		var b: Label3D = _label(0)
		b.global_position = view.tile_center(path.tiles[break_at]) + Vector3.UP * _label_height
		b.text = "%d" % break_cost
		b.modulate = _break_color
		b.visible = true

	var total: Label3D = _label(1)
	total.global_position = view.tile_center(path.destination()) + Vector3.UP * _label_height
	total.text = "%d mp · %s" % [
		path.cost, "this action" if break_at < 0 else "both actions",
	]
	total.modulate = _label_color
	total.visible = true

	_arrow.global_position = view.tile_center(path.destination()) + Vector3.UP * _lift
	_arrow.rotation.y = TankView.facing_yaw(path.final_facing())
	_arrow.visible = true


func clear() -> void:
	if _line != null:
		_line.visible = false
		_line.mesh = null
	for l: Label3D in _labels:
		l.visible = false
	if _arrow != null:
		_arrow.visible = false


# --- the line -------------------------------------------------------------------------------------

## Build the ribbon, in one or two color bands.
##
## `break_at` is the index in `path.tiles` of the first tile that costs more than the action in
## progress can pay for, or -1 if the whole route fits. The two bands share that tile's point, so
## the color changes without a gap.
func _build_line(path: PathResult, break_at: int) -> void:
	var pts: PackedVector3Array = _route_points(path)
	if pts.size() < 2:
		return

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()

	if break_at < 0:
		RoadMeshBuilder._emit_ribbon(verts, norms, cols, pts, _half_w, _line_color)
	else:
		# Tile k sits at point 2 * k — the list alternates center, edge, center, edge, center.
		var split: int = clampi(break_at * 2, 1, pts.size() - 1)
		RoadMeshBuilder._emit_ribbon(
			verts, norms, cols, pts.slice(0, split + 1), _half_w, _line_color
		)
		RoadMeshBuilder._emit_ribbon(
			verts, norms, cols, pts.slice(split), _half_w, _line_far_color
		)

	if verts.is_empty():
		return

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_line.mesh = mesh
	_line.visible = true


## Tile centers with the shared edge midpoints between them, lifted clear of the ground.
##
## The midpoints are what make the line usable on terraced ground: taken at the height of the higher
## of the two tiles, as `RoadMeshBuilder` does, the ribbon steps up onto a terrace at its lip
## instead of disappearing into the wall for half a tile before it. Straight through tile centers
## would also cut the corner on every diagonal.
func _route_points(path: PathResult) -> PackedVector3Array:
	var md: MapData = view.md
	var pts := PackedVector3Array()
	var n: int = path.tiles.size()
	for k: int in n:
		var tile: int = path.tiles[k]
		pts.append(RoadMeshBuilder._tile_center(md, tile, _lift))
		if k >= n - 1:
			continue
		var next: int = path.tiles[k + 1]
		var d: int = Grid.dir_between(md.tx(tile), md.ty(tile), md.tx(next), md.ty(next))
		if d >= 0:
			pts.append(RoadMeshBuilder._edge_midpoint(md, tile, d, _lift))
	return pts


# --- labels and the destination arrow ---------------------------------------------------------

func _label(index: int) -> Label3D:
	while _labels.size() <= index:
		# Label3D needs no generated texture at all — billboarding, fixed size, an outline and the
		# project's default font are all native to it.
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.fixed_size = true
		l.shaded = false
		l.double_sided = true
		l.font_size = LABEL_FONT_PX
		l.outline_size = maxi(LABEL_FONT_PX / 6, 1)
		l.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
		l.pixel_size = cfg.f("look.path.label_px", 15.0) * SPRITE_UNIT / float(LABEL_FONT_PX)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Grow upward from the anchor rather than straddling it. Centered, half the quad hangs back
		# down toward the ground it is annotating, which is half of why it met the terrain at all.
		l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		# The rest of why: a billboarded quad seen at a shallow camera angle *intersects* the ground
		# mesh and is sliced through the middle by it. No height or size cures that — only taking it
		# out of the depth test does. The cost is that it shows through a hill in front, which for a
		# transient preview figure is the right way round, and is the same trade the selection arrow
		# already makes.
		l.no_depth_test = true
		l.render_priority = 2
		l.outline_render_priority = 1
		l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		l.top_level = true
		l.visible = false
		add_child(l)
		_labels.append(l)
	return _labels[index]


## The destination facing arrow. The one marker here that is **not** billboarded — it says which way
## the tank will be pointing, which is a direction on the ground, so it lies in the ground plane and
## turns with the facing.
##
## `axis = AXIS_Y` is what puts the quad in the XZ plane. Which way the texture's own "up" ends up
## pointing under that is the one thing here you cannot settle by reading the documentation; the
## arrow is drawn with its point at the top of the image on the assumption that maps to -Z, which is
## north, which is facing 0. If it comes out square to the route, add a quarter turn here.
func _make_ground_arrow() -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = MarkerTextures.ground_arrow()
	s.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	s.axis = Vector3.AXIS_Y
	s.fixed_size = false
	s.shaded = false
	s.double_sided = true
	# Blended and mip-filtered, to match the coverage `MarkerTextures` rasterized. Discarding on
	# alpha would throw it away and put the staircase back.
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# A real object on the ground, so it is sized in real meters and scales with the world.
	s.pixel_size = cfg.f("look.path.arrow_length_m", 7.0) / float(MarkerTextures.TEX_PX)
	s.modulate = cfg.color("look.path.arrow_color", Color(1.0, 0.94, 0.82))
	s.render_priority = 1
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.top_level = true
	s.visible = false
	return s
