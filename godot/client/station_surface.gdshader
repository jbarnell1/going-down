// The Reactor's walls, floors and ceilings (client/station_view.gd): CC0 photo maps (godot/assets/reactor,
// SOURCES.md there) laid in world metres, so every wall, floor and ceiling in the station repeats at the same
// real-world scale whatever its cell. A slow world-space variation breaks the repeat. Walls with `dado` carry
// old green paint up to that height, a dark painted line on top and grime at the foot. COLOR.r is how corrupt
// this spot is (0 near the lift, 1 farthest) and COLOR.g a per-face random number, as surface.gdshader.
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D paint_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform sampler2D stain_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float stain_amount = 1.0;
uniform float self_light = 0.0;
// Metres of wall, floor or ceiling one copy of the map covers.
uniform float tile_m = 2.4;
uniform float paint_tile_m = 2.0;
// Height of the painted dado above each floor (0: plain concrete) and the storey height.
uniform float dado = 0.0;
uniform float storey = 3.2;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec3 n = normalize(wnorm);
	bool level_face = abs(n.y) > 0.5;
	// Floor and ceiling: x and z. Walls: along the wall and up.
	vec2 p = level_face ? wpos.xz : vec2(abs(n.x) > abs(n.z) ? wpos.z : wpos.x, wpos.y);
	vec3 base = texture(albedo_tex, p / tile_m * vec2(1.0, -1.0)).rgb;
	float big = vnoise(p * 0.23 + 3.1) * 0.6 + vnoise(p * 0.71 + 9.7) * 0.4;
	base *= 0.86 + 0.28 * big;
	if (!level_face && dado > 0.0) {
		float hy = mod(wpos.y + 0.001, storey);
		if (hy < dado) {
			vec3 paint = texture(paint_tex, p / paint_tile_m * vec2(1.0, -1.0)).rgb;
			base = paint * (0.9 + 0.2 * big);
		}
		float line = step(dado, hy) * step(hy, dado + 0.04);
		base = mix(base, vec3(0.09, 0.15, 0.11), line);
		base *= mix(0.62, 1.0, smoothstep(0.0, 0.5, hy));
	}
	float t = COLOR.r;
	float dirt = smoothstep(0.2, 0.85, t);
	vec3 c = mix(base, base * vec3(0.74, 0.70, 0.52), dirt);
	vec2 sp = level_face ? wpos.xz : vec2(wpos.x + wpos.z, wpos.y);
	vec2 cell = floor(sp / 1.7);
	float pick = hash(cell + COLOR.g);
	vec4 st = texture(stain_tex, fract(sp / 1.7));
	float k = step(1.0 - smoothstep(0.45, 1.0, t) * 0.45, pick) * st.a * stain_amount;
	c = mix(c, c * st.rgb * 1.15, k);
	ALBEDO = c;
	ROUGHNESS = 0.88;
	SPECULAR = 0.3;
	EMISSION = c * self_light * (1.0 - dirt * 0.85);
}
