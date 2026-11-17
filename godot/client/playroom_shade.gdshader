// The Playroom's lit surfaces (client/playroom_view.gd): padded walls, mats, laminate walkways, the
// ceiling, the furniture and the Minder's body. The light is flat and too bright, so most of it is
// baked in (`self_light`), scaled by `energy`: 1 as built, 0 in count dark (the view sets it every
// frame from the light level and the count-dark flag). The far distance fades into a pale haze.
//
// `mode` says where the colour comes from:
//   0  the texture alone; COLOR.r is the walking distance from the lift (Level's surfaces), which
//      bleaches the colour further in;
//   1  the texture times the vertex colour (furniture and figures, bleached on the CPU); vertex alpha
//      below 1 makes a part glow;
//   2  padded walls: where the texture's alpha is 1 (the padded band) it is tinted by a palette colour
//      that changes every 2 m along the wall; bleached by COLOR.r;
//   3  floor mats: the texture tinted by a palette colour per 1 m square; bleached by COLOR.r.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform float mode = 1.0;
uniform float triplanar = 0.0;
uniform float scissor = 0.0;
uniform float self_light = 0.5;
uniform float energy = 1.0;
uniform float bleach = 0.7;
uniform vec4 haze : source_color = vec4(0.9, 0.9, 0.86, 1.0);
uniform float haze_density = 0.02;
uniform vec4 pal0 : source_color = vec4(0.82, 0.36, 0.32, 1.0);
uniform vec4 pal1 : source_color = vec4(0.92, 0.78, 0.36, 1.0);
uniform vec4 pal2 : source_color = vec4(0.36, 0.55, 0.8, 1.0);
uniform vec4 pal3 : source_color = vec4(0.45, 0.72, 0.45, 1.0);

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec3 palette(float k) {
	float i = mod(k, 4.0);
	return i < 0.5 ? pal0.rgb : (i < 1.5 ? pal1.rgb : (i < 2.5 ? pal2.rgb : pal3.rgb));
}

void fragment() {
	vec2 uv = UV;
	if (triplanar > 0.5) {
		vec3 n = abs(wnorm);
		uv = n.y > 0.5 ? wpos.xz * 0.5 : (n.x > n.z ? wpos.zy * 0.5 : wpos.xy * 0.5);
	}
	vec4 t = texture(albedo_tex, uv);
	if (scissor > 0.0 && t.a < scissor) discard;
	vec3 c = t.rgb;
	float corr = 0.0;
	float glow = 0.0;
	if (mode < 0.5) {
		corr = COLOR.r;
	} else if (mode < 1.5) {
		c *= COLOR.rgb;
		glow = 1.0 - COLOR.a;
	} else if (mode < 2.5) {
		corr = COLOR.r;
		float k = floor((wpos.x + wpos.z) * 0.5 + 0.013);
		c = mix(c, c * palette(k), t.a);
	} else {
		corr = COLOR.r;
		vec2 q = floor(wpos.xz + 0.013);
		c *= palette(q.x + 2.0 * q.y + floor(q.y * 0.5));
	}
	float b = smoothstep(0.25, 1.0, corr) * bleach;
	float l = dot(c, vec3(0.3, 0.59, 0.11));
	c = mix(c, vec3(l) * 0.8 + 0.16, b);
	ALBEDO = c;
	ROUGHNESS = 0.85;
	EMISSION = c * (self_light + glow * 2.5) * energy;
	float d = length(VERTEX);
	FOG = vec4(haze.rgb * energy, 1.0 - exp(-d * haze_density));
}
