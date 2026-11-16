// Everything that gives light rather than takes it: ceiling panels, the emergency strips and the red
// door glows, the lift's indicator, lit buttons. Unshaded, so no light variants at all.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 1.0;
uniform sampler2D tex : source_color, filter_nearest, hint_default_white;

void fragment() {
	ALBEDO = texture(tex, UV).rgb * color.rgb * COLOR.rgb * energy;
}
