// The orientation tape's VCR look (docs/floors/story.md section 2): the game's tape filter
// (tape.gdshader) turned up, for a flat blue and yellow picture. The picture arrives at 480x270.
// Colour lags behind brightness and smears to the right (the yellow bleeds into the blue), lines
// wobble, grain, scanlines, a torn head-switching strip along the bottom, a slight barrel. Plus:
// `band` a tracking band rolling down the picture (its centre, 0 top to 1 bottom; below 0: none),
// `jitter` the picture jumping a few lines on a cut, `tear` the tape tearing (blocks of lines thrown
// sideways and snow). Chroma is kept near full so the blue stays blue.
shader_type canvas_item;

uniform vec2 src_size = vec2(480.0, 270.0);
uniform float strength = 1.0;
uniform float band = -1.0;
uniform float jitter = 0.0;
uniform float tear = 0.0;
uniform float clock = 0.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
vec3 to_yiq(vec3 c) { return vec3(dot(c, vec3(0.299, 0.587, 0.114)), dot(c, vec3(0.596, -0.274, -0.322)), dot(c, vec3(0.211, -0.523, 0.312))); }
vec3 to_rgb(vec3 y) { return vec3(y.x + 0.956 * y.y + 0.621 * y.z, y.x - 0.272 * y.y - 0.647 * y.z, y.x - 1.106 * y.y + 1.703 * y.z); }

void fragment() {
	vec2 cc = UV - 0.5;
	vec2 uv = 0.5 + cc * (1.0 - 0.03 * strength + 0.06 * strength * dot(cc, cc));
	uv.y += jitter / src_size.y;
	float line = floor(uv.y * src_size.y);
	float tf = floor(clock * 30.0);
	// Line wobble, and the torn head-switching strip at the bottom.
	float wob = sin(line * 0.37 + clock * 2.3) * 0.45 + (hash(vec2(line, tf)) - 0.5) * 0.5;
	float hs = smoothstep(1.0 - 0.032, 1.0, uv.y);
	wob += hs * (9.0 + 8.0 * hash(vec2(tf, 3.0)));
	// The tracking band: lines inside it are thrown sideways and wash out.
	float bd = band < 0.0 ? 0.0 : 1.0 - smoothstep(0.0, 0.045, abs(uv.y - band));
	wob += bd * (3.0 + 9.0 * hash(vec2(line, tf + 11.0)));
	// Tearing: blocks of lines torn sideways, re-dealt several times a second.
	float gtf = floor(clock * 15.0);
	float block = floor(line / 7.0);
	float torn = step(1.0 - tear * 0.7, hash(vec2(block, gtf)));
	wob += torn * (hash(vec2(block, gtf + 7.0)) - 0.5) * 70.0 * tear;
	uv.x += wob * strength / src_size.x;
	vec2 px = vec2(1.0 / src_size.x, 0.0);
	// Luma: three soft horizontal taps; vertical stays crisp.
	vec3 a = texture(TEXTURE, uv - px * 0.8).rgb;
	vec3 b = texture(TEXTURE, uv).rgb;
	vec3 c = texture(TEXTURE, uv + px * 0.8).rgb;
	float Y = to_yiq(a * 0.25 + b * 0.5 + c * 0.25).x;
	// Ringing: a faint echo trailing right of sharp edges.
	float Yr = to_yiq(texture(TEXTURE, uv - px * 3.0).rgb).x;
	Y += (Y - Yr) * 0.1 * strength;
	// Chroma: lags behind and smears to the right over several pixels.
	vec3 ch = vec3(0.0);
	for (int i = 0; i < 7; i++) ch += to_yiq(texture(TEXTURE, uv - px * (1.5 + float(i) * 1.1)).rgb);
	ch /= 7.0;
	float blot = (hash(vec2(floor(uv.x * 40.0), line + tf)) - 0.5) * 0.05;
	vec3 col = to_rgb(vec3(Y, ch.y * 0.96 + blot * strength, ch.z * 0.96 - blot * strength));
	// Grain.
	col += (hash(uv * src_size + fract(clock) * 91.0) - 0.5) * 0.08 * strength;
	// The band washes out and sparkles.
	col = mix(col, vec3(0.85) * hash(vec2(floor(uv.x * src_size.x * 0.5), line + tf)), bd * 0.35);
	// Scanlines on the source lines.
	float sl = 0.5 + 0.5 * cos(uv.y * src_size.y * 6.2831853);
	col *= 1.0 - 0.16 * sl * strength;
	col = clamp(col, 0.0, 1.0);
	col = pow(col, vec3(1.0 + 0.15 * strength)) * (1.0 + 0.08 * strength) + vec3(0.02, 0.02, 0.03) * strength;
	// Vignette.
	float r = length(cc) * 1.35;
	col *= 1.0 - 0.35 * strength * pow(r, 2.6);
	col = mix(col, vec3(hash(uv * 300.0 + tf)), hs * 0.55 * strength);
	// Tear snow.
	col = mix(col, vec3(hash(uv * src_size + clock * 37.0)), tear * 0.6 * step(0.55, hash(vec2(line, gtf))));
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) col = vec3(0.02);
	COLOR = vec4(col, 1.0);
}
