// The player's brightness on the Hanging Ward's picture (client/ward/review.gd): the same last step as
// client/tape.gdshader on the other floors, black level and gamma (client/brightness.gd params).
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float bright_lift = 0.0;
uniform float bright_gamma = 1.0;

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	col = clamp(bright_lift + (1.0 - bright_lift) * pow(clamp(col, 0.0, 1.0), vec3(bright_gamma)), 0.0, 1.0);
	COLOR = vec4(col, 1.0);
}
