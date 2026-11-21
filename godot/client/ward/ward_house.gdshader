// AW1: every house wall, slab and partition of the Hanging Ward (client/ward/skin.gd house_box), one material at one
// world scale. The mesh tells each face what it is:
//   COLOR.r  1 outside (brick), 0 inside;
//   COLOR.b  the variant: outside, the house's finish (sooted, red, limewashed, black); inside, the room's (its floor's
//            stain, its dado colour, plaster or wallpaper above);
//   UV2.x    height: outside, above the house's floor (the damp plinth); inside, above the storey's floor (skirting,
//            dado, rail, the cornice's soot).
// Up faces inside are floors, down faces ceilings (whitewashed boards), the rest walls.
shader_type spatial;

uniform sampler2D brick_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D plaster_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D floor_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D board_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D paper_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wood_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float brick_tile = 1.0;
uniform float plaster_tile = 1.0;
uniform float floor_tile = 2.0;
uniform float board_tile = 2.0;
uniform float paper_tile = 1.0;
uniform float wood_tile = 1.0;
varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec3 pick(int k, vec3 a, vec3 b, vec3 c, vec3 d) {
	return k == 0 ? a : (k == 1 ? b : (k == 2 ? c : d));
}

void fragment() {
	vec3 n = normalize(world_normal);
	vec3 p = world_position;
	vec2 wall_uv = abs(n.x) > abs(n.z) ? vec2(p.z, -p.y) : vec2(p.x, -p.y);
	int variant = clamp(int(floor(COLOR.b * 4.0)), 0, 3);
	float h = UV2.x;
	vec3 col;
	if (COLOR.r > 0.5) {
		vec2 uv = abs(n.y) > 0.5 ? p.xz : wall_uv;
		vec3 brick = texture(brick_tex, uv / brick_tile).rgb;
		float lime = texture(plaster_tex, uv / (plaster_tile * 1.7)).r;
		col = brick * pick(variant, vec3(0.62, 0.55, 0.52), vec3(0.82, 0.72, 0.66), vec3(0.8, 0.76, 0.72), vec3(0.42, 0.40, 0.40));
		if (variant == 2) {
			// Limewash, flaking where the plaster map is dark: the brick shows through.
			col = mix(col, vec3(0.46, 0.45, 0.41) * (0.5 + lime), 0.62 * smoothstep(0.3, 0.6, lime));
		}
		col *= mix(0.55, 1.0, smoothstep(0.05, 0.5, h));
	} else if (n.y > 0.5) {
		vec2 uv = variant % 2 == 0 ? p.xz : p.zx;
		float grain = texture(floor_tex, uv / floor_tile).r;
		col = grain * pick(variant, vec3(0.62, 0.44, 0.30), vec3(0.36, 0.26, 0.19), vec3(0.50, 0.52, 0.44), vec3(0.58, 0.34, 0.25));
	} else if (n.y < -0.5) {
		float board = texture(board_tex, p.xz / board_tile).r;
		col = board * vec3(0.78, 0.74, 0.66);
	} else {
		float plaster = texture(plaster_tex, wall_uv / plaster_tile).r;
		vec3 upper = plaster * pick(variant, vec3(0.86, 0.80, 0.68), vec3(0.66, 0.74, 0.62), vec3(0.88, 0.74, 0.50), vec3(0.64, 0.68, 0.76));
		if (variant % 2 == 1) {
			// Wallpaper: a faded stripe with a small figure, the paper's own grime over it.
			float grime = texture(paper_tex, wall_uv / paper_tile).r;
			float stripe = smoothstep(0.42, 0.5, fract(wall_uv.x * 3.0)) * (1.0 - smoothstep(0.92, 1.0, fract(wall_uv.x * 3.0)));
			vec2 cell = fract(wall_uv * vec2(3.0, 2.5)) - vec2(0.2, 0.5);
			float figure = 1.0 - smoothstep(0.06, 0.1, length(cell * vec2(1.0, 1.5)));
			vec3 ground = pick(variant, vec3(0.0), vec3(0.62, 0.58, 0.42), vec3(0.0), vec3(0.55, 0.42, 0.40));
			upper = ground * (0.6 + 0.6 * grime) * mix(0.88, 1.0, stripe) * mix(1.0, 0.88, figure);
		}
		vec3 dado = plaster * pick(variant, vec3(0.24, 0.34, 0.27), vec3(0.42, 0.18, 0.15), vec3(0.34, 0.25, 0.18), vec3(0.20, 0.24, 0.32));
		vec3 wood = texture(wood_tex, wall_uv / wood_tile).rgb * 0.55;
		col = h < 0.92 ? dado : upper;
		if (h > 0.9 && h < 0.97) {
			col = wood * (h > 0.955 ? 0.7 : 1.0);
		}
		if (h < 0.17) {
			col = wood * (h > 0.15 ? 0.6 : 0.8);
		}
		// Soot under the ceiling and a little lamp-black at the cornice.
		col *= mix(1.0, 0.72, smoothstep(2.35, 2.95, h));
		if (h > 2.86 && h < 2.91) {
			col *= 0.7;
		}
	}
	ALBEDO = col;
	ROUGHNESS = 0.9;
}
