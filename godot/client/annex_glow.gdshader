// The Annex's ceiling panels and its green emergency signs: unshaded, like glow.gdshader (same
// `color` and `energy` uniforms, so Level dims them the same way), but fading into the Annex's haze
// rather than the Clinic's dark fog. `haze` is black for the emergency signs.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 1.0;
uniform sampler2D tex : source_color, filter_nearest, hint_default_white;
uniform vec4 haze : source_color = vec4(0.62, 0.6, 0.45, 1.0);
uniform float haze_density = 0.03;

void fragment() {
	ALBEDO = texture(tex, UV).rgb * color.rgb * COLOR.rgb * energy;
	float d = length(VERTEX);
	FOG = vec4(haze.rgb * min(energy, 1.0), 1.0 - exp(-d * haze_density));
}
