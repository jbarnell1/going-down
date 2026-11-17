// The Minder's card mask, front sheet (client/minder_view.gd): the model's printed card and its glow
// map from assets/entities/minder.glb, the eye holes cut through by alpha (`scissor`). The card is lit
// as the body is (`self_light` times `lit`, which the view copies from the body's energy), and the bare
// card glows by its glow map (the ink cut out) times `color` and `energy`, which the Playroom's view
// moves between lit and count dark (add_glow): faint under the strip lights, bright in the dark, so the
// face is drawn by what does not glow. `haze` is what the distance fades into (dark in count dark).
// Back faces culled, as the model's material: the back of the card is its own sheet on the body.
shader_type spatial;
render_mode diffuse_lambert, cull_back;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, hint_default_white;
uniform sampler2D glow_tex : source_color, filter_nearest_mipmap, hint_default_black;
uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 0.26;
uniform float lit = 1.0;
uniform float self_light = 0.75;
uniform float scissor = 0.5;
uniform float roughness = 0.88;
uniform vec4 haze : source_color = vec4(0.9, 0.9, 0.86, 1.0);
uniform float haze_density = 0.012;

void fragment() {
	vec4 t = texture(albedo_tex, UV);
	if (t.a < scissor) discard;
	ALBEDO = t.rgb;
	ROUGHNESS = roughness;
	SPECULAR = 0.2;
	EMISSION = t.rgb * self_light * lit + texture(glow_tex, UV).rgb * color.rgb * energy;
	float d = length(VERTEX);
	FOG = vec4(haze.rgb, 1.0 - exp(-d * haze_density));
}
