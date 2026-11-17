// The Minder's body (client/minder_view.gd) on the Playroom's light: the model's own maps from
// assets/entities/minder.glb (colour, normal, roughness), its eye holes and ragged edges cut by alpha
// (`scissor`), lit by the real lights and by the baked-in Playroom light like client/playroom_shade.gdshader
// (`self_light` times `energy`: 1 as built, 0 in count dark, set by the Playroom's view). The far
// distance fades into `haze`. Both faces drawn, as the model's material: rags and the card's back are
// single sheets.
shader_type spatial;
render_mode diffuse_lambert, cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, hint_default_white;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D rough_tex : hint_default_white, filter_nearest_mipmap;
uniform float normal_depth = 0.8;
uniform float scissor = 0.5;
uniform float self_light = 0.75;
uniform float energy = 1.0;
uniform float specular = 0.25;
uniform vec4 haze : source_color = vec4(0.9, 0.9, 0.86, 1.0);
uniform float haze_density = 0.012;

void fragment() {
	vec4 t = texture(albedo_tex, UV);
	if (t.a < scissor) discard;
	ALBEDO = t.rgb;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
	// glTF keeps roughness in the green channel.
	ROUGHNESS = texture(rough_tex, UV).g;
	SPECULAR = specular;
	EMISSION = t.rgb * self_light * energy;
	float d = length(VERTEX);
	FOG = vec4(haze.rgb * energy, 1.0 - exp(-d * haze_density));
}
