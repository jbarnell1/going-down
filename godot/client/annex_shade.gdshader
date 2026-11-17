// The Annex's lit surfaces: walls, carpet, ceiling tiles, props, stairs, posters and signs. The light
// in the Annex is flat and even, so most of it is baked in (`self_light`), scaled by `energy`, which
// Level.update_lights sets like a ceiling panel's (1 as built, falling to 0 in a blink or the dark).
// The far distance fades into a pale yellow haze instead of the Clinic's dark fog: an office that goes
// on for ever. Vertex alpha below 1 makes a part glow (monitor screens, a copier's lamp).
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0);
uniform float use_vcol = 0.0;
uniform float triplanar = 0.0;
uniform float scissor = 0.0;
uniform float self_light = 0.4;
uniform float energy = 1.0;
uniform vec4 haze : source_color = vec4(0.62, 0.6, 0.45, 1.0);
uniform float haze_density = 0.03;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv = UV;
	if (triplanar > 0.5) {
		vec3 n = abs(wnorm);
		uv = n.y > 0.5 ? wpos.xz * 0.5 : (n.x > n.z ? wpos.zy * 0.5 : wpos.xy * 0.5);
	}
	vec4 t = texture(albedo_tex, uv) * tint;
	if (scissor > 0.0 && t.a < scissor) discard;
	vec3 c = t.rgb * mix(vec3(1.0), COLOR.rgb, use_vcol);
	float glow = use_vcol * (1.0 - COLOR.a);
	ALBEDO = c;
	ROUGHNESS = 0.9;
	EMISSION = c * (self_light + glow * 2.5) * energy;
	float d = length(VERTEX);
	FOG = vec4(haze.rgb * energy, 1.0 - exp(-d * haze_density));
}
