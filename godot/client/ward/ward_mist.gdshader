// AW1: the mist below the Ward's decks: a thin, slowly drifting layer, thicker in patches, fading out at its edges, so
// the drop reads as depth rather than a black void. Drawn unlit (it is the faint light the lamps leave in the haze).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

uniform vec3 mist_color : source_color = vec3(0.3, 0.36, 0.42);
uniform float strength = 0.4;
uniform vec2 centre = vec2(0.0);
uniform float radius = 60.0;
varying vec3 world_position;

float random_at(vec2 point) {
	return fract(sin(dot(point, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 f = fract(point);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(random_at(cell), random_at(cell + vec2(1.0, 0.0)), f.x),
		mix(random_at(cell + vec2(0.0, 1.0)), random_at(cell + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 q = world_position.xz * 0.045 + vec2(TIME * 0.006, TIME * 0.004);
	float patches = noise(q) * 0.6 + noise(q * 2.7 + 13.0) * 0.4;
	float edge = 1.0 - smoothstep(radius * 0.6, radius, length(world_position.xz - centre));
	// Its own fade with distance stands in for the fog it is drawn outside of (fog_disabled: the haze is the fog's light).
	float far = 1.0 - smoothstep(25.0, 70.0, length(world_position - CAMERA_POSITION_WORLD));
	ALBEDO = mist_color * (0.8 + 0.4 * patches);
	ALPHA = strength * smoothstep(0.25, 0.8, patches) * edge * mix(0.35, 1.0, far);
}
