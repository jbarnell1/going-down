// Wire glass (the Prison hub's doors and the bank's teller windows): a faint green-grey pane with a
// diamond wire mesh, lit like the rest of the room so it picks up the strip light's highlight.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_lambert, specular_schlick_ggx;

uniform vec4 tint : source_color = vec4(0.55, 0.66, 0.63, 0.14);
uniform vec4 wire_color : source_color = vec4(0.12, 0.13, 0.12, 0.45);
// Mesh pitch in metres, measured in world space so every pane matches.
uniform float pitch = 0.07;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	float along = abs(wnorm.x) > 0.5 ? wpos.z : wpos.x;
	vec2 p = vec2(along, wpos.y) / pitch;
	vec2 q = vec2(p.x + p.y, p.x - p.y);
	float w = max(step(fract(q.x), 0.1), step(fract(q.y), 0.1));
	ALBEDO = mix(tint.rgb, wire_color.rgb, w);
	ALPHA = mix(tint.a, wire_color.a, w);
	ROUGHNESS = mix(0.12, 0.7, w);
	SPECULAR = 0.6;
}
