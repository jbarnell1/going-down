// Walls, floors and ceilings. COLOR.r is how corrupt this spot is (0 near the lift, 1 farthest),
// COLOR.g a per-face random number. Clean: the texture as painted. Corrupt: grime, a sick yellow
// cast, and rust stains blotched in from a world-space projection.
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D stain_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float stain_amount = 1.0;
uniform float self_light = 0.0;
uniform float tile_wear = 0.0;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
	float t = COLOR.r;
	float dirt = smoothstep(0.2, 0.85, t);
	vec3 grimy = base * vec3(0.74, 0.70, 0.52);
	vec3 c = mix(base, grimy, dirt);
	// Stains: wall plane coordinates (along the wall, height) or floor coordinates.
	vec2 sp = abs(wnorm.y) > 0.5 ? wpos.xz : vec2(wpos.x + wpos.z, wpos.y);
	vec2 cell = floor(sp / 1.7);
	float pick = hash(cell + COLOR.g);
	vec2 suv = fract(sp / 1.7);
	vec4 st = texture(stain_tex, suv);
	float k = step(1.0 - smoothstep(0.45, 1.0, t) * 0.45, pick) * st.a * stain_amount;
	c = mix(c, c * st.rgb * 1.15, k);
	float roughness = 0.85;
	if (tile_wear > 0.0) {
		// The four 50 cm ceramic tiles across the texture. Lock wear to the tile,
		// with more visible heel scuffs and worn glaze further from the lift.
		vec2 tile = wpos.xz * 2.0;
		vec2 id = floor(tile);
		float grade = tile_wear * smoothstep(0.12, 0.82, t);
		float choice = hash(id + vec2(1.8, 3.3));
		vec2 centre = vec2(0.24, 0.33) + vec2(choice, hash(id + 19.3)) * 0.38;
		float angle = hash(id + 71.2) * 6.283185;
		vec2 along = vec2(cos(angle), sin(angle));
		vec2 off = fract(tile) - centre;
		vec2 scuff = vec2(dot(off, along), dot(off, vec2(-along.y, along.x)));
		float rubbed = 1.0 - smoothstep(0.38, 1.0, length(scuff / vec2(0.27, 0.075)));
		float drag = 1.0 - smoothstep(0.0, 0.026, abs(scuff.y + scuff.x * scuff.x * 1.3));
		drag *= 1.0 - smoothstep(0.10, 0.25, abs(scuff.x + 0.035));
		float heel = (rubbed * 0.13 + drag * 0.28) * step(0.32, choice) * grade;
		c *= (1.0 - heel) * (1.0 + (choice - 0.5) * (0.035 + grade * 0.12));
		roughness = mix(0.65, 0.94, clamp(grade * 0.65 + heel, 0.0, 1.0));
	}
	ALBEDO = c;
	ROUGHNESS = roughness;
	SPECULAR = 0.3;
	EMISSION = c * self_light * (1.0 - dirt * 0.85);
}
