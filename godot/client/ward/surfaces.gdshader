shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.4, 0.34, 0.3, 1.0);
uniform int surface_kind = 0;
varying vec3 world_position;
varying vec3 world_normal;

float random_at(vec3 point) {
	return fract(sin(dot(point, vec3(73.41, 157.21, 113.12))) * 43758.5453);
}

float grain(vec3 point) {
	vec3 cell = floor(point);
	vec3 blend = fract(point);
	blend = blend * blend * (3.0 - 2.0 * blend);
	float front = mix(mix(random_at(cell), random_at(cell + vec3(1, 0, 0)), blend.x),
		mix(random_at(cell + vec3(0, 0, 1)), random_at(cell + vec3(1, 0, 1)), blend.x), blend.z);
	cell.y += 1.0;
	float back = mix(mix(random_at(cell), random_at(cell + vec3(1, 0, 0)), blend.x),
		mix(random_at(cell + vec3(0, 0, 1)), random_at(cell + vec3(1, 0, 1)), blend.x), blend.z);
	return mix(front, back, blend.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	float broad = grain(world_position * 2.4);
	float fine = grain(world_position * 43.0);
	float shade = 0.68 + 0.37 * broad + 0.23 * fine;
	if (surface_kind == 1) {
		float board_number = floor(world_position.z * 4.4);
		float board_seam = smoothstep(0.0, 0.05, fract(world_position.z * 4.4));
		float end_seam = smoothstep(0.0, 0.018, fract(world_position.x * 0.48 + random_at(vec3(board_number))));
		float fibers = grain(world_position * vec3(3.7, 16.1, 59.0));
		shade = (0.43 + 0.34 * broad + 0.38 * fibers) * (0.52 + 0.48 * board_seam * end_seam);
	} else if (surface_kind == 2) {
		float x = abs(world_normal.x) > 0.5 ? world_position.z : world_position.x;
		float rise = world_position.y * 7.15;
		float transverse = x * 3.5 + 0.5 * mod(floor(rise), 2.0);
		vec2 brick = fract(vec2(transverse, rise));
		float mortar = smoothstep(0.025, 0.055, min(min(brick.x, 1.0 - brick.x), min(brick.y, 1.0 - brick.y)));
		float brick_tint = random_at(vec3(floor(transverse), floor(rise), 2.0));
		shade *= mix(0.49, 0.74 + brick_tint * 0.43, mortar);
	}
	ALBEDO = base_color.rgb * shade;
	ROUGHNESS = 0.88;
}