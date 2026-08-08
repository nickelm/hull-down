shader_type spatial;
render_mode cull_disabled, diffuse_lambert, depth_draw_never, blend_mix;

// Water surface.
//
// Not one global plane. Rivers run downhill across tens of metres of relief, and a single plane
// would either flood the lowlands or hang in the air over the uplands — so the water is per-tile
// quads at each tile's own surface level, stepped exactly like the terrain under it. At this art
// style a stepped river reads as a river.

uniform vec3 shallow : source_color = vec3(0.32, 0.52, 0.62);
uniform vec3 deep : source_color = vec3(0.13, 0.28, 0.44);
uniform float alpha : hint_range(0.0, 1.0) = 0.78;
uniform float ripple_speed = 0.06;
uniform float ripple_scale = 0.9;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Fresnel: water seen edge-on reflects the sky and reads pale, water seen from above reads as
	// its own colour. Cheap, and it is most of what makes a flat quad look wet.
	float facing = 1.0 - abs(dot(normalize(VIEW), NORMAL));
	vec3 col = mix(deep, shallow, pow(facing, 2.0));

	// Two crossed sine waves standing in for a normal map. No texture, in keeping with the rest of
	// the look.
	float t = TIME * ripple_speed;
	float r = sin((world_pos.x + t * 9.0) * ripple_scale)
		* sin((world_pos.z - t * 7.0) * ripple_scale * 1.3);
	col += r * 0.03;

	ALBEDO = col;
	ALPHA = alpha;
	ROUGHNESS = 0.12;
	SPECULAR = 0.6;
}
