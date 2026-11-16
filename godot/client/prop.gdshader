// Every lit object that is not architecture or a character: props (vertex coloured), the stair, the
// lift's steel and buttons, signs, stains (alpha cut), the painted BANK / DOWN floor. One shader, so
// the browser compiles one set of light variants for all of them.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform float use_vcol = 0.0;
uniform float scissor = 0.0;
uniform float emit = 0.0;
uniform float triplanar = 0.0;

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
	vec4 t = texture(tex, uv) * albedo;
	if (scissor > 0.0 && t.a < scissor) discard;
	vec3 c = t.rgb * mix(vec3(1.0), COLOR.rgb, use_vcol);
	ALBEDO = c;
	EMISSION = c * emit;
}
