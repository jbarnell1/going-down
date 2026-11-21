// AW1: one photographed map (godot/assets/ward/surfaces/) laid in world metres on a box's faces, the picture `tile`
// metres across wherever the box is, so every surface of one kind shows it at one real-world size.
shader_type spatial;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tile = 1.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform float roughness_value = 0.9;
uniform float metal = 0.0;
varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 a = abs(world_normal);
	vec2 uv = a.y >= a.x && a.y >= a.z ? world_position.xz : (a.x >= a.z ? vec2(world_position.z, -world_position.y) : vec2(world_position.x, -world_position.y));
	ALBEDO = texture(albedo_tex, uv / tile).rgb * tint;
	ROUGHNESS = roughness_value;
	METALLIC = metal;
}
