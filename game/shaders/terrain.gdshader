shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// Terrain surface: flat-shaded vertex colour, plus the overlays.
//
// The overlays are a single 200x200 texture rather than geometry. Repainting the movement or
// visibility overlay is then one PackedByteArray write and an ImageTexture.update() - a millisecond
// or two for the whole map, against thirty to eighty to rebuild an overlay mesh. That difference is
// what buys the 50 ms budget in 4.12.
//
//   R = movement range      G = exposure (0 masked, 128 hull down, 255 exposed)
//   B = highlight (hover, path preview)   A = unused
//
// Overlays are drawn as REGION OUTLINES, not as a tint over the ground. A flat tint recolours the
// terrain, so a blue movement range reads as a lake and a red exposure region reads as red rock -
// the overlay competes with the thing it is annotating. An outline sits on the boundary and leaves
// the ground its own colour, and an emissive one stays legible whatever the sun is doing to that
// face. That is the whole difference in look between this and the first version.
//
// A texel of the overlay is exactly one tile, so a fragment is on a region's border when its own
// texel is inside the region, the neighbouring texel in some direction is outside, and the fragment
// is within `border_width_m` of *that* edge. Region membership only ever changes across orthogonal
// tile edges, so four neighbour samples are sufficient and there are no corner cases to handle.

uniform sampler2D overlay_tex : filter_nearest, source_color;
uniform float map_extent_m = 2000.0;
uniform float tile_m = 10.0;

uniform float border_width_m : hint_range(0.0, 5.0) = 1.4;
uniform float glow_width_m : hint_range(0.0, 10.0) = 3.5;
uniform float fill_strength : hint_range(0.0, 1.0) = 0.10;
uniform float emission_strength : hint_range(0.0, 4.0) = 1.6;
uniform float glow_strength : hint_range(0.0, 2.0) = 0.30;
uniform float path_fill_strength : hint_range(0.0, 1.0) = 0.30;

uniform vec3 move_colour : source_color = vec3(1.0, 0.70, 0.24);
uniform vec3 exposed_colour : source_color = vec3(1.0, 0.33, 0.21);
uniform vec3 hull_down_colour : source_color = vec3(0.37, 0.84, 0.41);
uniform vec3 hover_colour : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 path_colour : source_color = vec3(1.0, 0.94, 0.82);

// Grid lines make tile boundaries readable when the camera is low, and fade out from height so
// they do not turn the map into graph paper from above.
uniform float grid_strength : hint_range(0.0, 1.0) = 0.16;

varying vec3 world_pos;
varying vec3 world_normal;
// Vertex colour is forwarded explicitly rather than read as COLOR in fragment. Relying on the
// fragment-stage built-in gave every face pure white - geometry correct, terrain invisible - and
// an explicit varying is unambiguous and free.
varying vec3 vertex_colour;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vertex_colour = COLOR.rgb;
}

// Distance in metres to each of the four tile edges, as (west, east, north, south). Grid +Y is
// world +Z, so north is the low-Z side.
vec4 edge_distances(vec2 cell) {
	return vec4(cell.x, 1.0 - cell.x, cell.y, 1.0 - cell.y) * tile_m;
}

// How strongly this fragment sits on the border of a region.
//
// `here` and the four neighbour values are region membership, 0 or 1. `d` holds the distances to
// the four tile edges. The antialiasing width comes from fwidth() of a world-space metre quantity,
// which is metres-per-pixel at this fragment - so the line holds `width` metres on the ground and
// stays one crisp pixel wide whether the camera is at 30 m or 900 m.
float region_edge(float here, vec4 nb, vec4 d, float width) {
	if (here < 0.5 || width <= 0.0) {
		return 0.0;
	}
	float aa = max(fwidth(d.x + d.z), 0.001);
	vec4 band = 1.0 - smoothstep(vec4(width - aa), vec4(width + aa), d);
	vec4 open = (1.0 - nb) * band;
	return max(max(open.x, open.y), max(open.z, open.w));
}

// The outward bleed: fragments just *outside* a region, fading away from its border. Gives the
// outline something to sit in so it reads as a glow rather than as a decal.
float region_glow(float here, vec4 nb, vec4 d, float width) {
	if (here > 0.5 || width <= 0.0) {
		return 0.0;
	}
	vec4 band = 1.0 - smoothstep(vec4(0.0), vec4(width), d);
	vec4 open = nb * band;
	return max(max(open.x, open.y), max(open.z, open.w));
}

void fragment() {
	vec3 albedo = vertex_colour;

	// Grid lines on the horizontal faces only - drawing them down a vertical wall looks like a
	// texture rather than a boundary. NORMAL is in view space here, so the world-space copy is
	// what answers "is this face pointing up".
	float upness = abs(world_normal.y);
	vec2 cell = fract(world_pos.xz / tile_m);
	if (grid_strength > 0.0 && upness > 0.5) {
		vec2 edge = min(cell, 1.0 - cell);
		float line = 1.0 - smoothstep(0.0, 0.06, min(edge.x, edge.y));
		float fade = 1.0 - clamp((length(world_pos - CAMERA_POSITION_WORLD) - 120.0) / 260.0, 0.0, 1.0);
		albedo = mix(albedo, albedo * 0.72, line * grid_strength * fade);
	}

	vec2 uv = world_pos.xz / map_extent_m;
	float texel = tile_m / map_extent_m;

	vec4 c = texture(overlay_tex, uv);
	vec4 nw = texture(overlay_tex, uv + vec2(-texel, 0.0));
	vec4 ne = texture(overlay_tex, uv + vec2(texel, 0.0));
	vec4 nn = texture(overlay_tex, uv + vec2(0.0, -texel));
	vec4 ns = texture(overlay_tex, uv + vec2(0.0, texel));

	// Off the edge of the map the sampler clamps, which would report a border region as continuing
	// forever and suppress its outline. Treat anything outside the texture as empty instead.
	vec4 inside = vec4(
		step(0.0, uv.x - texel), step(uv.x + texel, 1.0),
		step(0.0, uv.y - texel), step(uv.y + texel, 1.0)
	);

	vec4 d = edge_distances(cell);

	// Movement range: one region, from the R channel.
	float mv = step(0.5, c.r);
	vec4 mv_nb = vec4(step(0.5, nw.r), step(0.5, ne.r), step(0.5, nn.r), step(0.5, ns.r)) * inside;
	float mv_edge = region_edge(mv, mv_nb, d, border_width_m);
	float mv_glow = region_glow(mv, mv_nb, d, glow_width_m);

	// Exposure is a three-state value packed into one channel, so it is decoded by range and then
	// outlined as two independent regions. The seam between exposed and hull-down gets a line from
	// both sides, which is correct - that boundary is the crest, and it is the thing worth seeing.
	float ex = step(0.75, c.g);
	vec4 ex_nb = vec4(step(0.75, nw.g), step(0.75, ne.g), step(0.75, nn.g), step(0.75, ns.g)) * inside;
	float ex_edge = region_edge(ex, ex_nb, d, border_width_m);
	float ex_glow = region_glow(ex, ex_nb, d, glow_width_m);

	float hd = step(0.25, c.g) * (1.0 - ex);
	vec4 hd_nb = vec4(
		step(0.25, nw.g) * (1.0 - step(0.75, nw.g)),
		step(0.25, ne.g) * (1.0 - step(0.75, ne.g)),
		step(0.25, nn.g) * (1.0 - step(0.75, nn.g)),
		step(0.25, ns.g) * (1.0 - step(0.75, ns.g))
	) * inside;
	float hd_edge = region_edge(hd, hd_nb, d, border_width_m);
	float hd_glow = region_glow(hd, hd_nb, d, glow_width_m);

	// Hover is a single tile and the path preview is a one-tile-wide ribbon. Outlining a line
	// gives two parallel lines and reads worse than filling it, so the path stays a fill and only
	// the hovered tile is outlined.
	float hov = step(0.9, c.b);
	vec4 hov_nb = vec4(step(0.9, nw.b), step(0.9, ne.b), step(0.9, nn.b), step(0.9, ns.b)) * inside;
	float hov_edge = region_edge(hov, hov_nb, d, border_width_m);
	float path = step(0.1, c.b) * (1.0 - hov);

	// Fills are deliberately faint - they say "this region is here" without repainting the ground.
	albedo = mix(albedo, move_colour, mv * fill_strength);
	albedo = mix(albedo, exposed_colour, ex * fill_strength);
	albedo = mix(albedo, hull_down_colour, hd * fill_strength);
	albedo = mix(albedo, path_colour, path * path_fill_strength);

	vec3 emis =
		move_colour * mv_edge
		+ exposed_colour * ex_edge
		+ hull_down_colour * hd_edge
		+ hover_colour * hov_edge;
	vec3 halo =
		move_colour * mv_glow
		+ exposed_colour * ex_glow
		+ hull_down_colour * hd_glow;

	ALBEDO = albedo;
	EMISSION = emis * emission_strength + halo * glow_strength;
	ROUGHNESS = 1.0;
}
