// The tape look, in the spirit of src/render/tape.ts: the scene arrives at 480x270, colour lags
// and smears behind brightness, luma is softened, lines wobble, grain, scanlines, lifted blacks,
// head-switching noise at the bottom, a slight barrel and a vignette. Plus the game's three states:
// `darkness` (the lights are out: more grain, a lifted black), `tired` (out of breath: the edge of the
// view closes in) and `glitch` (tearing and snow: being taken, a tape drop-out).
shader_type canvas_item;

uniform vec2 src_size = vec2(480.0, 270.0);
uniform float strength = 1.0;
uniform float darkness = 0.0;
uniform float tired = 0.0;
uniform float glitch = 0.0;
uniform float snow = 0.0;
// The player's brightness (client/brightness.gd): black level and gamma, the very last step.
uniform float bright_lift = 0.0;
uniform float bright_gamma = 1.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
vec3 to_yiq(vec3 c) { return vec3(dot(c, vec3(0.299, 0.587, 0.114)), dot(c, vec3(0.596, -0.274, -0.322)), dot(c, vec3(0.211, -0.523, 0.312))); }
vec3 to_rgb(vec3 y) { return vec3(y.x + 0.956 * y.y + 0.621 * y.z, y.x - 0.272 * y.y - 0.647 * y.z, y.x - 1.106 * y.y + 1.703 * y.z); }

void fragment() {
	vec2 cc = UV - 0.5;
	vec2 uv = 0.5 + cc * (1.0 - 0.035 * strength + 0.07 * strength * dot(cc, cc));
	float line = floor(uv.y * src_size.y);
	float tf = floor(TIME * 30.0);
	// Line wobble, and a torn head-switching strip at the bottom.
	float wob = sin(line * 0.37 + TIME * 2.3) * 0.35 + (hash(vec2(line, tf)) - 0.5) * 0.35;
	float hs = smoothstep(1.0 - 0.026, 1.0, uv.y);
	wob += hs * (8.0 + 6.0 * hash(vec2(tf, 3.0)));
	// Glitch: blocks of lines torn sideways, re-dealt several times a second.
	float gtf = floor(TIME * 12.0);
	float block = floor(line / 9.0);
	float tear = step(1.0 - glitch * 0.6, hash(vec2(block, gtf)));
	wob += tear * (hash(vec2(block, gtf + 7.0)) - 0.5) * 60.0 * glitch;
	uv.x += wob * strength / src_size.x;
	vec2 px = vec2(1.0 / src_size.x, 0.0);
	// Luma: three soft horizontal taps; vertical stays crisp.
	vec3 a = texture(TEXTURE, uv - px * 0.75).rgb;
	vec3 b = texture(TEXTURE, uv).rgb;
	vec3 c = texture(TEXTURE, uv + px * 0.75).rgb;
	float Y = to_yiq(a * 0.25 + b * 0.5 + c * 0.25).x;
	// Ringing: a faint echo trailing right of sharp edges.
	float Yr = to_yiq(texture(TEXTURE, uv - px * 2.5).rgb).x;
	Y += (Y - Yr) * 0.18 * strength;
	// Chroma: lags two pixels behind and smears over six.
	vec3 ch = vec3(0.0);
	for (int i = 0; i < 6; i++) ch += to_yiq(texture(TEXTURE, uv - px * (2.0 + float(i))).rgb);
	ch /= 6.0;
	float blot = (hash(vec2(floor(uv.x * 40.0), line + tf)) - 0.5) * 0.05;
	vec3 col = to_rgb(vec3(Y, ch.y * 0.62 + blot * strength, ch.z * 0.55 - blot * strength));
	// Grain: heavier in the dark.
	col += (hash(uv * src_size + fract(TIME) * 91.0) - 0.5) * (0.07 + 0.09 * darkness) * strength;
	// Scanlines on the source lines.
	float sl = 0.5 + 0.5 * cos(uv.y * src_size.y * 6.2831853);
	col *= 1.0 - 0.14 * sl * strength;
	// Contrast, exposure, lifted blacks.
	col = clamp(col, 0.0, 1.0);
	col = pow(col, vec3(1.0 + 0.3 * strength)) * (1.0 + 0.14 * strength) + vec3(0.04, 0.05, 0.055) * strength + vec3(0.025, 0.02, 0.02) * darkness;
	// Vignette, and the out-of-breath closing in.
	float r = length(cc) * 1.35;
	col *= 1.0 - 0.5 * strength * pow(r, 2.6);
	col *= 1.0 - tired * smoothstep(0.1, 0.95, r * r);
	col = mix(col, vec3(hash(uv * 300.0 + tf)), hs * 0.5 * strength);
	// Glitch snow.
	col = mix(col, vec3(hash(uv * src_size + TIME * 37.0)), glitch * 0.55 * step(0.6, hash(vec2(line, gtf))));
	// Snow: the whole picture is noise (being taken).
	float sn = hash(floor(UV * src_size * vec2(0.5, 1.0)) + fract(TIME * 7.0) * 113.0);
	col = mix(col, vec3(sn * 0.85 + 0.05 * sin(line * 0.5 + TIME * 40.0)), snow);
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) col = vec3(0.02);
	// Last, after everything: the player's brightness (client/brightness.gd apply, the same sum; clamped
	// there). 0 and 1 leave the picture as it is, also with the tape look off (T).
	col = clamp(bright_lift + (1.0 - bright_lift) * pow(clamp(col, 0.0, 1.0), vec3(bright_gamma)), 0.0, 1.0);
	COLOR = vec4(col, 1.0);
}
