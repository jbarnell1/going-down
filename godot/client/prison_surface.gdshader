// The Prison hub's walls, floor and ceiling (docs/floors/prison.md, section 4: "Painted concrete,
// grey-green below and cream above"). Painted block walls in two tones split at a dado line, a dark
// skirting, a painted concrete floor and a cream ceiling. Everything from world position, so the
// Level's wall and floor geometry is used as built; its COLOR (the Clinic's corruption) is ignored:
// the hub is clean everywhere. Low detail on purpose: the tape filter softens it further.
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;

// 0 wall, 1 floor, 2 ceiling.
uniform float part = 0.0;
uniform vec4 low_paint : source_color = vec4(0.33, 0.42, 0.37, 1.0);
uniform vec4 high_paint : source_color = vec4(0.83, 0.79, 0.64, 1.0);
uniform vec4 floor_paint : source_color = vec4(0.32, 0.33, 0.31, 1.0);
uniform vec4 ceiling_paint : source_color = vec4(0.74, 0.72, 0.63, 1.0);
uniform float dado = 1.3;
uniform float storey = 3.2;
uniform float self_light = 0.0;

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
	vec3 c;
	vec2 gp;
	float rough = 0.9;
	float spec = 0.25;
	if (part < 0.5) {
		float h = mod(wpos.y + 0.0005, storey);
		float along = abs(wnorm.x) > 0.5 ? wpos.z : wpos.x;
		c = h < dado ? low_paint.rgb : high_paint.rgb;
		// Gloss paint below, flat above.
		if (h < dado) { rough = 0.6; spec = 0.4; }
		// The dado stripe and the skirting, a darker green.
		if (abs(h - dado) < 0.03) c = low_paint.rgb * 0.55;
		if (h < 0.11) c = low_paint.rgb * 0.62;
		// Block courses, 0.2 m tall and 0.4 m long, half-bond, painted over.
		float row = floor(h / 0.2);
		float bx = fract((along + row * 0.2) / 0.4);
		float by = fract(h / 0.2);
		float mortar = max(step(by, 0.05), step(bx, 0.025));
		c *= 1.0 - 0.08 * mortar;
		gp = vec2(along, h);
	} else if (part < 1.5) {
		c = floor_paint.rgb;
		// Worn patches where the paint has gone thin.
		c *= 0.9 + 0.2 * vnoise(wpos.xz * 0.7);
		rough = 0.5;
		spec = 0.45;
		gp = wpos.xz;
	} else {
		c = ceiling_paint.rgb;
		gp = wpos.xz;
	}
	// Grain in coarse pixels (about 6 cm), and slow blotches.
	float g = hash(floor(gp * 16.0)) * 0.5 + vnoise(gp * 1.3) * 0.5;
	c *= 0.93 + 0.13 * g;
	ALBEDO = c;
	ROUGHNESS = rough;
	SPECULAR = spec;
	EMISSION = c * self_light;
}
