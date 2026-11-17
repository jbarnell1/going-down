// The Playroom's unshaded pieces (client/playroom_view.gd): the white strip lights, and what stays
// lit in count dark (the glow-in-the-dark ceiling stars, the glowing lines on the mats, the EXIT sign,
// the Minder's card mask). Like annex_glow.gdshader (same `color` and `energy` uniforms), with an
// alpha cut-out and the vertex colour. `haze` is what the distance fades into: the view darkens it
// with the lights, so a glow in count dark fades into black.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 1.0;
uniform sampler2D tex : source_color, filter_nearest, hint_default_white;
uniform float scissor = 0.0;
uniform vec4 haze : source_color = vec4(0.9, 0.9, 0.86, 1.0);
uniform float haze_density = 0.02;

void fragment() {
	vec4 t = texture(tex, UV);
	if (scissor > 0.0 && t.a < scissor) discard;
	ALBEDO = t.rgb * color.rgb * COLOR.rgb * energy;
	float d = length(VERTEX);
	FOG = vec4(haze.rgb, 1.0 - exp(-d * haze_density));
}
