// The Minder's mask seen from far off in the dark (client/minder_view.gd): a soft round glow in front
// of the card, facing the camera, added to the picture. The mask is a hand's width across, under three
// pixels of the 480x270 picture at 10 m, so on its own it is a speck; this is the light it sheds in the
// dark, drawn only where the card would be seen: in the dark (`lit` 0, copied from the body's energy),
// from in front (the node's +z is the way the mask faces), and growing from `near` to `far` metres.
// Close up the card's own glow (client/minder_mask.gdshader) draws the face, holes and all.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform vec4 color : source_color = vec4(0.75, 1.0, 0.8, 1.0);
uniform float energy = 1.0;
uniform float lit = 1.0;
uniform float near = 3.0;
uniform float far = 9.0;

varying float k;

void vertex() {
	vec3 at = MODEL_MATRIX[3].xyz;
	vec3 face = normalize(MODEL_MATRIX[2].xyz);
	vec3 to_cam = CAMERA_POSITION_WORLD - at;
	float d = length(to_cam);
	float front = smoothstep(0.1, 0.5, dot(face, to_cam / max(d, 1e-4)));
	k = energy * (1.0 - clamp(lit, 0.0, 1.0)) * front * smoothstep(near, far, d);
	// Turned to face the camera, at the node's own size.
	float s = length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * s, INV_VIEW_MATRIX[1] * s, INV_VIEW_MATRIX[2] * s, MODEL_MATRIX[3]);
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	float g = pow(clamp(1.0 - r, 0.0, 1.0), 2.0);
	ALBEDO = color.rgb * g * k;
}
