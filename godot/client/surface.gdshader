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
// LA1, the Clinic's ceiling (0 leaves a material as it was): `whiten` pulls the texture toward clean pale tiles near
// the lift, fading out with the corruption; `grid_m` draws a suspended ceiling's grid of that pitch (metres) on a
// level face; `self_dirt` is how much of the self light the corruption takes away.
uniform float whiten = 0.0;
uniform float grid_m = 0.0;
uniform float self_dirt = 0.85;
// LA3, the Clinic's walls (0 leaves a material as it was): each 2 m panel of paint (one repeat of the texture) is
// mirrored or not by a hash of where it is, so the scratches stop lining up in a row (a mirrored panel still meets its
// neighbours seamlessly), and a second kind of mark is mixed in: short scuffs at trolley and shoulder height, a few
// near the lift and more with the walk from it.
uniform float wall_vary = 0.0;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void fragment() {
	vec2 uv = UV;
	float t = COLOR.r;
	float dirt = smoothstep(0.2, 0.85, t);
	float scuff = 0.0;
	if (wall_vary > 0.0 && abs(wnorm.y) < 0.5) {
		float panel = floor(uv.x);
		vec2 pid = vec2(panel, floor(dot(wpos.xz, abs(wnorm.xz)) * 0.5 + 0.5));
		if (hash(pid + 3.7) > 0.5) {
			uv.x = panel + 1.0 - fract(uv.x);
		}
		float along = fract(UV.x) * 2.0;
		float up = mod(wpos.y, 3.2);
		for (int k = 0; k < 3; k++) {
			float fk = float(k);
			float pick = hash(pid + vec2(11.3 + fk * 7.1, 5.9));
			if (pick > 0.35 + 0.55 * dirt) {
				continue;
			}
			vec2 c = vec2(0.2 + 1.6 * hash(pid + vec2(fk, 1.3)), mix(0.3, 0.95, hash(pid + vec2(fk, 2.9))));
			if (hash(pid + vec2(fk, 4.4)) > 0.6) {
				c.y = 1.4 + 0.3 * hash(pid + vec2(fk, 6.6));
			}
			float len = 0.12 + 0.3 * hash(pid + vec2(fk, 8.8));
			float slope = (hash(pid + vec2(fk, 9.9)) - 0.5) * 0.25;
			vec2 d = vec2(along, up) - c;
			float across = abs(d.y - d.x * slope);
			float body = (1.0 - smoothstep(0.004, 0.012, across)) * (1.0 - smoothstep(len * 0.4, len * 0.5, abs(d.x)));
			scuff = max(scuff, body * (0.45 + 0.3 * dirt));
		}
	}
	// The unmirrored uv's slopes pick the mip level, so a mirrored panel's edge never shows a seam.
	vec3 base = textureGrad(albedo_tex, uv, dFdx(UV), dFdy(UV)).rgb;
	base *= 1.0 - 0.5 * scuff;
	if (whiten > 0.0) {
		float lum = dot(base, vec3(0.2126, 0.7152, 0.0722));
		vec3 clean = vec3(0.9, 0.92, 0.93) * (0.82 + 0.18 * lum / 0.6);
		base = mix(base, clean, whiten * (1.0 - smoothstep(0.1, 0.7, t)));
	}
	vec3 grimy = base * vec3(0.74, 0.70, 0.52);
	vec3 c = mix(base, grimy, dirt);
	if (grid_m > 0.0 && abs(wnorm.y) > 0.5) {
		vec2 g = abs(fract(wpos.xz / grid_m + 0.5) - 0.5) * grid_m;
		float bar = 1.0 - smoothstep(0.008, 0.016, min(g.x, g.y));
		c = mix(c, c * vec3(0.62, 0.62, 0.6), bar);
	}
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
	EMISSION = c * self_light * (1.0 - dirt * self_dirt);
}
