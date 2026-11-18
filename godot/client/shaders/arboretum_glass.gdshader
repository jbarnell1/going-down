shader_type spatial;
render_mode cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D grime_mask : filter_linear_mipmap, repeat_enable;

void fragment() {
	float grime = texture(grime_mask, UV).r;
	ALBEDO = COLOR.rgb * mix(0.9, 1.15, grime);
	ALPHA = COLOR.a * mix(0.82, 1.85, grime);
	ROUGHNESS = mix(0.12, 0.75, grime);
	SPECULAR = 0.18;
	EMISSION = vec3(0.01, 0.014, 0.012);
}
