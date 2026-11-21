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
uniform sampler2D photo_tex : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform float photo = 0.0;
uniform float photo_scale = 0.5;
uniform float corr_fixed = 0.0;
// Mode 4: the ready-made models' colour maps are darker than the floor's bleached paint; this lifts them to it.
uniform float photo_gain = 1.0;
uniform sampler2D detail_tex : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform float detail_amt = 0.0;
uniform float detail_scale = 0.5;
uniform sampler2D grime_tex : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform float grime_amt = 0.0;
uniform float grime_scale = 0.25;
// 1: the dirt only at hand height and under the ceiling line of each 3.2 m storey (walls), the paint clean between.
uniform float grime_band = 0.0;
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
	vec3 an = abs(wnorm);
	vec2 wuv = an.y > 0.5 ? wpos.xz : (an.x > an.z ? wpos.zy : wpos.xy);
	vec4 t = texture(albedo_tex, uv);
	if (photo > 0.5) {
		t = texture(photo_tex, wuv * photo_scale);
	}
	if (mode > 3.5) {
		t = texture(photo_tex, UV);
		t.rgb *= photo_gain;
	}
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
	} else if (mode < 3.5) {
		corr = COLOR.r;
		vec2 q = floor(wpos.xz);
		c *= palette(q.x + 2.0 * q.y + floor(q.y * 0.5));
	} else {
		corr = corr_fixed;
	}
	if (detail_amt > 0.0) {
		c *= mix(1.0, texture(detail_tex, wuv * detail_scale).r * 2.0, detail_amt);
	}
	if (grime_amt > 0.0) {
		float ga = grime_amt;
		if (grime_band > 0.5) {
			float hy = mod(wpos.y + 0.01, 3.2);
			ga *= clamp(1.0 - smoothstep(0.5, 1.15, hy) + smoothstep(2.65, 3.15, hy), 0.0, 1.0);
		}
		c *= mix(vec3(1.0), texture(grime_tex, wuv * grime_scale).rgb * 2.0, ga);
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
