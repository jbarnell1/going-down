// The Reactor's growths (client/station_dress.gd): wet red-brown and bruise-purple lumpy flesh with pale veins that
// glow faintly (the concept, .local/monster-concepts/meshy/reactor-growth-c-front.png). COLOR.r is the
// lobe's tone (0 dark, 1 pale), COLOR.g how deep in the cluster this spot is (darker), COLOR.b unused. The veins
// glow a little on their own so the masses still read under the emergency lamps; the glow breathes slowly.
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;

uniform vec4 dark : source_color = vec4(0.3, 0.11, 0.09, 1.0);
uniform vec4 pale : source_color = vec4(0.55, 0.26, 0.2, 1.0);
uniform vec4 bruise : source_color = vec4(0.38, 0.22, 0.4, 1.0);
uniform vec4 vein : source_color = vec4(0.86, 0.72, 0.68, 1.0);
uniform vec4 vein_glow : source_color = vec4(1.0, 0.55, 0.42, 1.0);
uniform float vein_energy = 0.55;
// The Meshy pieces: their own colour map (use_tex 1), tinted from the seed; veins drawn over them too.
uniform sampler2D tex : source_color, filter_linear_mipmap, hint_default_white;
uniform float use_tex = 0.0;
uniform vec4 tint : source_color = vec4(1.0);
// Never a black cut-out: a faint glow of its own colour and a warm wet rim, in either power state.
uniform float self_glow = 0.35;
uniform float rim_glow = 0.7;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }

float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x), mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x), mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

void fragment() {
	float mottle = noise3(wpos * 7.0) * 0.6 + noise3(wpos * 19.0) * 0.4;
	vec3 c = mix(dark.rgb, pale.rgb, clamp(COLOR.r * 0.8 + mottle * 0.35 - 0.1, 0.0, 1.0));
	// Bruise-purple patches across the red-brown.
	float purple = smoothstep(0.55, 0.75, noise3(wpos * 2.3 + 11.0));
	c = mix(c, bruise.rgb * (0.7 + mottle * 0.6), purple * 0.8);
	c *= mix(1.0, 0.45, COLOR.g);
	if (use_tex > 0.5) {
		c = texture(tex, UV).rgb * tint.rgb * (0.85 + mottle * 0.3);
	}
	// Ridged noise for the veins: thin bright lines where the noise crosses its middle.
	float v1 = 1.0 - abs(noise3(wpos * 5.0) * 2.0 - 1.0);
	float v2 = 1.0 - abs(noise3(wpos * 11.0 + 4.0) * 2.0 - 1.0);
	float veins = smoothstep(0.95, 0.99, v1) + smoothstep(0.96, 0.995, v2) * 0.5;
	c = mix(c, vein.rgb * 0.7, clamp(veins, 0.0, 1.0) * 0.55);
	ALBEDO = c;
	ROUGHNESS = mix(0.18, 0.42, mottle);
	SPECULAR = 0.65;
	float breathe = 0.8 + 0.2 * sin(TIME * 0.7 + wpos.x * 0.3 + wpos.z * 0.2);
	float deep = use_tex > 0.5 ? 0.0 : COLOR.g;
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.5);
	EMISSION = vein_glow.rgb * veins * vein_energy * breathe * (1.0 - deep * 0.6) * (use_tex > 0.5 ? 0.6 : 1.0)
		+ (c * self_glow + vec3(0.07, 0.022, 0.02)) * (1.0 - deep * 0.5) + vec3(0.55, 0.22, 0.18) * rim * rim_glow * breathe;
}
