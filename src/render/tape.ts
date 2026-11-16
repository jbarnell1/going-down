// The tape look: the scene is drawn small (270 lines) into an offscreen target, then put on screen
// through one full-screen shader that makes it read as a worn VHS copy of a camcorder recording.
// Everything the shader does is driven by one settings object per strength level, so a designer can
// tune it without touching GLSL. fx level 0 is the clean render (a plain nearest-neighbour blit).
//
// The scene target keeps light in linear half-float, so its mip chain doubles as a free bloom source:
// one sample at a coarse mip gives the glow around the ceiling panels with no blur loop.

import * as THREE from 'three';

export type FxLevel = 0 | 1 | 2;

export interface TapeSettings {
  /** Luma softening: spread of the 3 horizontal taps, in source pixels. Vertical stays crisp. */
  lumaSoft: number;
  /** How far colour lags behind brightness to the right, in source pixels. */
  chromaShift: number;
  /** Mip level the colour is read from: higher smears colour wider. */
  chromaBlur: number;
  /** Colour saturation after the tape (1 = as rendered). */
  saturation: number;
  /** Extra saturation factor for cool colours (blues, cyans): tape and cheap camcorders lose them first. */
  coolSaturation: number;
  /** Edge ringing: a faint light/dark echo trailing to the right of sharp edges, in luma. */
  ringing: number;
  /** Blotchy colour noise in the chroma channel. */
  chromaNoise: number;
  /** Fine animated luma grain. */
  grain: number;
  /** Darkening between source lines (fades out on screens too small to show lines). */
  scanlines: number;
  /** Slow horizontal wobble of lines, in source pixels. */
  wobble: number;
  /** Mean seconds between tracking rolls (0 = never). */
  trackingEvery: number;
  /** How hard a tracking roll tears the band it passes through. */
  trackingStrength: number;
  /** Expected dropout streaks per second. */
  dropoutRate: number;
  /** Height of the head-switching strip at the bottom, as a fraction of the picture. */
  headSwitch: number;
  /** Lifted black level and its colour (sRGB 0..1). */
  lift: [number, number, number];
  /** Midtone contrast (a power curve): above 1 sinks the mids so the whites stand out and clip. */
  contrast: number;
  /** Exposure gain before clipping; above 1 blows out the whites. */
  exposure: number;
  /** Glow added around light brighter than the threshold (linear light). */
  bloom: number;
  bloomThreshold: number;
  /** Colour cast multiplied over the whole picture. */
  cast: [number, number, number];
  /** Levels per channel after the ordered dither (0 = full depth). */
  levels: number;
  /** Corner darkening. */
  vignette: number;
  /** Barrel bulge; corners stay in frame. */
  barrel: number;
}

const DEFAULT: TapeSettings = {
  lumaSoft: 0.75,
  chromaShift: 2.0,
  chromaBlur: 1.6,
  saturation: 0.55,
  coolSaturation: 0.5,
  ringing: 0.22,
  chromaNoise: 0.05,
  grain: 0.05,
  scanlines: 0.08,
  wobble: 0.35,
  trackingEvery: 40,
  trackingStrength: 0.7,
  dropoutRate: 0.35,
  headSwitch: 0.024,
  lift: [0.04, 0.05, 0.055],
  contrast: 1.4,
  exposure: 1.14,
  bloom: 0.3,
  bloomThreshold: 1.0,
  cast: [0.99, 1.02, 0.91],
  levels: 40,
  vignette: 0.42,
  barrel: 0.05,
};

const HEAVY: TapeSettings = {
  ...DEFAULT,
  lumaSoft: 1.1,
  chromaShift: 3.2,
  chromaBlur: 2.2,
  saturation: 0.45,
  coolSaturation: 0.4,
  ringing: 0.35,
  chromaNoise: 0.11,
  grain: 0.1,
  scanlines: 0.12,
  wobble: 1.1,
  trackingEvery: 9,
  trackingStrength: 1.0,
  dropoutRate: 2.5,
  headSwitch: 0.03,
  lift: [0.07, 0.075, 0.08],
  contrast: 1.5,
  exposure: 1.22,
  bloom: 0.45,
  levels: 24,
  vignette: 0.6,
  barrel: 0.07,
};

/** Tunable settings per level. Level 0 is never read: it draws the clean picture. */
export const TAPE_LEVELS: Record<FxLevel, TapeSettings> = { 0: DEFAULT, 1: DEFAULT, 2: HEAVY };

const VERT = /* glsl */ `
in vec3 position;
out vec2 vUv;
void main() {
  vUv = position.xy * 0.5 + 0.5;
  gl_Position = vec4(position.xy, 0.0, 1.0);
}`;

// Linear -> sRGB, the same curve three uses on its own output.
const SRGB = /* glsl */ `
vec3 toSrgb(vec3 c) {
  c = max(c, 0.0);
  return mix(pow(c, vec3(1.0 / 2.4)) * 1.055 - 0.055, c * 12.92, step(c, vec3(0.0031308)));
}`;

const BLIT_FRAG = /* glsl */ `
precision highp float;
uniform sampler2D tSrc;
uniform vec2 uSrc;
in vec2 vUv;
out vec4 outColor;
${SRGB}
void main() {
  ivec2 p = ivec2(min(floor(vUv * uSrc), uSrc - 1.0));
  outColor = vec4(toSrgb(texelFetch(tSrc, p, 0).rgb), 1.0);
}`;

const TAPE_FRAG = /* glsl */ `
precision highp float;
uniform sampler2D tSrc;
uniform vec2 uSrc;      // scene target size (px)
uniform vec2 uOut;      // screen size (px)
uniform float uTime;    // seconds, wrapped
uniform float uFrame;   // a new random seed per frame
uniform float uMotion;  // 0 with prefers-reduced-motion
uniform float uLumaSoft, uChromaShift, uChromaBlur, uSat, uCoolSat, uRing, uChromaNoise, uGrain, uScan, uWobble;
uniform float uHead, uContrast, uExposure, uBloom, uBloomThresh, uLevels, uVignette, uBarrel;
uniform vec3 uLift, uCast;
uniform vec3 uRoll;     // band centre (0 bottom .. 1 top), strength, half-height
uniform vec4 uDrop;     // row (0..1), x start, length, strength
uniform float uGlitch;  // 0..1
uniform float uTired;   // 0..1 darkening of the edge of the view when out of breath (0: no change)
in vec2 vUv;
out vec4 outColor;
${SRGB}

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

const mat3 TO_YIQ = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
const mat3 TO_RGB = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);

float bayer4(vec2 p) {
  ivec2 q = ivec2(mod(p, 4.0));
  int i = q.x + q.y * 4;
  int b[16] = int[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
  return (float(b[i]) + 0.5) / 16.0;
}

void main() {
  float aspect = uOut.x / uOut.y;
  // Slight barrel: bulge the middle, keep the corners where they were.
  vec2 cc = vUv - 0.5;
  vec2 ca = cc * vec2(aspect, 1.0);
  float r2 = dot(ca, ca);
  float rMax = 0.25 * (aspect * aspect + 1.0);
  vec2 uv = 0.5 + cc * (1.0 + uBarrel * r2) / (1.0 + uBarrel * rMax);

  float row = floor(clamp(uv.y, 0.0, 0.9999) * uSrc.y);
  float t = uTime;
  float g = uGlitch;
  float jitterClock = floor(t * 30.0);

  // Horizontal displacement of this line, in source pixels.
  float dx = 0.0;
  dx += uWobble * (sin(row * 0.021 + t * 0.9) * 0.6 + sin(row * 0.0067 - t * 0.31) * 0.4) * uMotion;
  float bd = (uv.y - uRoll.x) / max(uRoll.z, 0.001);
  float band = uRoll.y * exp(-bd * bd) * uMotion;
  float lineRnd = hash12(vec2(row, jitterClock));
  dx += band * (4.0 + lineRnd * 10.0);
  // Head switching: the last lines of the field skew right and jitter.
  float head = uHead > 0.0 ? smoothstep(uHead, uHead * 0.25, uv.y) : 0.0;
  dx += head * (5.0 + 6.0 * hash12(vec2(row, jitterClock * uMotion)));
  // Glitch: blocks of lines torn sideways, re-dealt several times a second.
  float blk = floor(row / 6.0);
  float gClock = floor(t * 14.0);
  dx += g * uMotion * (hash12(vec2(blk, gClock)) * 2.0 - 1.0) * 30.0 * step(0.5, hash12(vec2(blk + 7.0, gClock)));

  float px = 1.0 / uSrc.x;
  float v = (row + 0.5) / uSrc.y;
  float x = uv.x + dx * px;

  // Luma: three taps across the line, linear filtered horizontally only (v sits on the row centre).
  vec3 l0 = textureLod(tSrc, vec2(x - uLumaSoft * px, v), 0.0).rgb;
  vec3 l1 = textureLod(tSrc, vec2(x, v), 0.0).rgb;
  vec3 l2 = textureLod(tSrc, vec2(x + uLumaSoft * px, v), 0.0).rgb;
  vec3 sharp = toSrgb((l0 + 2.0 * l1 + l2) * 0.25);
  vec3 echo = toSrgb(textureLod(tSrc, vec2(x - 2.5 * px, v), 0.0).rgb);
  // Chroma: from a blurred mip, lagging to the right of the luma.
  float shift = uChromaShift * (1.0 + g * 3.0);
  vec3 soft = toSrgb(textureLod(tSrc, vec2(x - shift * px, uv.y), uChromaBlur).rgb);

  const vec3 LUMA = vec3(0.299, 0.587, 0.114);
  float y = dot(sharp, LUMA);
  y += uRing * (y - dot(echo, LUMA));
  vec3 yiq = vec3(y, (TO_YIQ * soft).yz);
  float sat = uSat * (1.0 - 0.7 * g);
  // Cool hues (negative I) fade further towards grey.
  yiq.y *= yiq.y < 0.0 ? uCoolSat : 1.0;
  yiq.z *= mix(1.0, uCoolSat, smoothstep(0.0, -0.08, yiq.y));
  vec2 cn = vec2(hash12(vec2(floor(gl_FragCoord.x / 6.0), row + uFrame)), hash12(vec2(row * 1.7, floor(gl_FragCoord.x / 9.0) + uFrame))) - 0.5;
  yiq.yz = yiq.yz * sat + cn * uChromaNoise;
  vec3 col = TO_RGB * yiq;

  // Contrast and overexposure; near the clip the colour bleaches out to flat white.
  col = pow(max(col, 0.0), vec3(uContrast)) * uExposure;
  // Bloom: a coarse mip of the linear scene, only what is brighter than the threshold.
  vec3 glow = textureLod(tSrc, uv, 4.0).rgb + textureLod(tSrc, uv, 2.5).rgb;
  col += max(glow * 0.5 - uBloomThresh, 0.0) * uBloom;
  float Y = dot(col, vec3(0.299, 0.587, 0.114));
  col = mix(col, vec3(Y), smoothstep(0.8, 1.05, Y) * 0.7);
  col = clamp(col, 0.0, 1.0);
  col *= uCast;
  col = uLift + col * (1.0 - uLift);

  // Tape noise.
  float n = hash12(vec2(floor(gl_FragCoord.x * 0.5), gl_FragCoord.y) + uFrame * 17.0) - 0.5;
  col += n * uGrain * (1.0 - 0.4 * Y);
  // Tracking band: lines in it go noisy and pale.
  col += band * (hash12(vec2(floor(gl_FragCoord.x / 3.0), row + uFrame)) - 0.35) * 0.45;
  // Head-switching strip: noisy and a little washed.
  col = mix(col, vec3(0.5 + n), head * 0.25);
  // Dropout streak: a short bright scratch along one line, with a fading tail.
  if (uDrop.w > 0.0 && abs(row - floor(uDrop.x * uSrc.y)) < 0.5) {
    float s = (uv.x - uDrop.y) / uDrop.z;
    if (s > 0.0 && s < 1.0) col = mix(col, vec3(0.85 + n * 0.3), uDrop.w * (1.0 - s * s));
  }
  // Glitch snow.
  col = mix(col, vec3(hash12(gl_FragCoord.xy + uFrame * 31.0)), g * 0.35 * step(0.35, hash12(vec2(row, gClock + 3.0))));

  // Scanlines, only where a source line is tall enough on screen to show them without moire.
  float rowPx = uOut.y / uSrc.y;
  float f = fract(uv.y * uSrc.y);
  col *= 1.0 - uScan * smoothstep(1.8, 2.6, rowPx) * (0.5 + 0.5 * cos(6.2831853 * f));

  col *= 1.0 - uVignette * r2 / rMax * (0.6 + 0.4 * r2 / rMax);
  // Out of breath: the edge of the view darkens and closes in. Exactly nothing on a full tank.
  col *= 1.0 - uTired * smoothstep(0.04, 0.9, r2 / rMax);

  if (uLevels > 0.0) {
    float b = bayer4(gl_FragCoord.xy);
    col = floor(col * uLevels + b) / uLevels;
  }
  outColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}`;

/**
 * Pushes the ceiling light panels (the mesh named 'lights') above white in the scene target, so the
 * tape's clip and bloom make them glare. Gain 1 restores them exactly, for the clean render.
 */
export function setLightGain(scene: THREE.Scene, gain: number): void {
  const mesh = scene.getObjectByName('lights') as THREE.Mesh | undefined;
  const mat = mesh?.material as THREE.MeshBasicMaterial | undefined;
  if (!mesh || !mat?.color) return;
  const base = (mesh.userData.baseColour as THREE.Color | undefined) ?? mat.color.clone();
  mesh.userData.baseColour = base;
  mat.color.copy(base).multiplyScalar(gain);
}

/** Darkening at the very corners of the view when completely out of breath (0..1). Kept subtle. */
const TIRED_EDGE = 0.85;

/** Most screens get one output pixel per CSS pixel; very large windows are capped. */
const MAX_OUT_HEIGHT = 1080;

export class Tape {
  readonly target: THREE.WebGLRenderTarget;
  private level: FxLevel;
  private readonly quad: THREE.Mesh;
  private readonly cam = new THREE.Camera();
  private readonly scene = new THREE.Scene();
  private readonly blit: THREE.RawShaderMaterial;
  private readonly tape: THREE.RawShaderMaterial;
  private reducedMotion = false;
  private readonly t0 = performance.now();
  private roll = { start: -1, dur: 0, strength: 0 };
  private nextRoll: number;
  private drop = { until: 0, y: 0, x: 0, len: 0, s: 0 };
  private glitchStart = 0;
  private glitchUntil = 0;
  private glitchStrength = 0;
  private frame = 0;
  /** 0..1: the lights have failed. Adds tape noise and lifts the blacks, at every fx level. */
  private dark = 0;
  /** 0..1: how out of breath the player is (the edge of the view darkens), at every fx level. */
  private tiredK = 0;

  constructor(
    private readonly renderer: THREE.WebGLRenderer,
    level: FxLevel,
    private readonly internalHeight = 270,
    /** Forces the 8-bit path that devices without float render targets take, so a test can cover it. */
    forceLdr = false,
  ) {
    this.level = level;
    const halfFloat = !forceLdr && renderer.capabilities.isWebGL2 && (renderer.extensions.has('EXT_color_buffer_half_float') || renderer.extensions.has('EXT_color_buffer_float'));
    this.target = new THREE.WebGLRenderTarget(16, 16, {
      type: halfFloat ? THREE.HalfFloatType : THREE.UnsignedByteType,
      magFilter: THREE.LinearFilter,
      minFilter: THREE.LinearMipmapLinearFilter,
      generateMipmaps: true,
      depthBuffer: true,
    });
    const common = { tSrc: { value: this.target.texture }, uSrc: { value: new THREE.Vector2(16, 16) } };
    this.blit = new THREE.RawShaderMaterial({ glslVersion: THREE.GLSL3, vertexShader: VERT, fragmentShader: BLIT_FRAG, uniforms: common, depthTest: false, depthWrite: false });
    this.tape = new THREE.RawShaderMaterial({
      glslVersion: THREE.GLSL3,
      vertexShader: VERT,
      fragmentShader: TAPE_FRAG,
      depthTest: false,
      depthWrite: false,
      uniforms: {
        ...common,
        uOut: { value: new THREE.Vector2(16, 16) },
        uTime: { value: 0 },
        uFrame: { value: 0 },
        uMotion: { value: 1 },
        uLumaSoft: { value: 0 },
        uChromaShift: { value: 0 },
        uChromaBlur: { value: 0 },
        uSat: { value: 1 },
        uCoolSat: { value: 1 },
        uRing: { value: 0 },
        uChromaNoise: { value: 0 },
        uGrain: { value: 0 },
        uScan: { value: 0 },
        uWobble: { value: 0 },
        uHead: { value: 0 },
        uContrast: { value: 1 },
        uExposure: { value: 1 },
        uBloom: { value: 0 },
        uBloomThresh: { value: 1 },
        uLevels: { value: 0 },
        uVignette: { value: 0 },
        uBarrel: { value: 0 },
        uLift: { value: new THREE.Vector3() },
        uCast: { value: new THREE.Vector3(1, 1, 1) },
        uRoll: { value: new THREE.Vector3(0, 0, 0.06) },
        uDrop: { value: new THREE.Vector4() },
        uGlitch: { value: 0 },
        uTired: { value: 0 },
      },
    });
    this.quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.blit);
    this.quad.frustumCulled = false;
    this.scene.add(this.quad);

    const mq = typeof matchMedia === 'function' ? matchMedia('(prefers-reduced-motion: reduce)') : null;
    if (mq) {
      this.reducedMotion = mq.matches;
      mq.addEventListener?.('change', (e) => { this.reducedMotion = e.matches; });
    }
    this.nextRoll = this.scheduleRoll(0);
  }

  get fx(): FxLevel {
    return this.level;
  }

  setFx(level: number): FxLevel {
    this.level = level >= 2 ? 2 : level >= 1 ? 1 : 0;
    this.nextRoll = this.scheduleRoll(this.now());
    return this.level;
  }

  get motion(): boolean {
    return !this.reducedMotion;
  }

  /** Sizes the screen (one pixel per CSS pixel, capped) and the scene target (fixed height). */
  setSize(cssWidth: number, cssHeight: number): void {
    const aspect = cssWidth / Math.max(1, cssHeight);
    const outH = Math.max(1, Math.min(Math.round(cssHeight), MAX_OUT_HEIGHT));
    const outW = Math.max(1, Math.round(outH * aspect));
    this.renderer.setSize(outW, outH, false);
    const srcW = Math.max(1, Math.round(this.internalHeight * aspect));
    this.target.setSize(srcW, this.internalHeight);
    (this.blit.uniforms.uSrc!.value as THREE.Vector2).set(srcW, this.internalHeight);
    (this.tape.uniforms.uOut!.value as THREE.Vector2).set(outW, outH);
  }

  /** A burst of interference: `ms` long, `strength` 0..1. Works at every fx level, fx 0 included. */
  glitch(ms: number, strength = 1): void {
    const now = this.now();
    this.glitchStart = now;
    this.glitchUntil = now + Math.max(0, ms) / 1000;
    this.glitchStrength = Math.min(1, Math.max(0, strength));
    if (this.motion && this.glitchStrength > 0.3) {
      this.roll = { start: now, dur: Math.max(0.6, ms / 1000), strength: this.glitchStrength };
    }
  }

  /** The lights failing (a blink): 0 none .. 1 the full dark. More grain and a lifted black. */
  setDarkness(k: number): void {
    this.dark = Math.max(0, Math.min(1, k));
  }

  get darkness(): number {
    return this.dark;
  }

  /**
   * How out of breath the player is, 0..1 (sim/stamina.ts exertion): the edge of the view darkens,
   * at most TIRED_EDGE at the corners. 0 draws exactly as without it (the reference pictures).
   */
  setTired(k: number): void {
    this.tiredK = Math.max(0, Math.min(1, k));
  }

  /** The edge darkening in force now (0 none .. TIRED_EDGE at the corners). */
  get tired(): number {
    return this.tiredK === 0 ? 0 : TIRED_EDGE * this.tiredK ** 1.4;
  }

  /**
   * Draws the scene into the small target, then the target to the screen. `overlay` (the instrument
   * in the hand) is drawn into the same target over the scene with the depth cleared, so it goes
   * through the tape look too and never sinks into a wall.
   */
  render(scene: THREE.Scene, camera: THREE.Camera, overlay?: { scene: THREE.Scene; camera: THREE.Camera } | null): void {
    const r = this.renderer;
    r.setRenderTarget(this.target);
    r.render(scene, camera);
    if (overlay) {
      const auto = r.autoClear;
      r.autoClear = false;
      r.clearDepth();
      r.render(overlay.scene, overlay.camera);
      r.autoClear = auto;
    }
    r.setRenderTarget(null);
    const now = this.now();
    const g = this.glitchAt(now);
    if (this.level === 0 && g === 0 && this.dark === 0 && this.tiredK === 0) {
      this.quad.material = this.blit;
    } else {
      this.quad.material = this.tape;
      this.update(now, g);
    }
    r.render(this.scene, this.cam);
    this.frame++;
  }

  private now(): number {
    return (performance.now() - this.t0) / 1000;
  }

  private scheduleRoll(now: number): number {
    const every = TAPE_LEVELS[this.level].trackingEvery;
    if (this.level === 0 || every <= 0) return Infinity;
    // Never sooner than a third of the mean; mostly around it.
    return now + every * (0.35 + -Math.log(1 - Math.random() * 0.95) * 0.65);
  }

  private glitchAt(now: number): number {
    if (now >= this.glitchUntil) return 0;
    const len = this.glitchUntil - this.glitchStart;
    const p = (now - this.glitchStart) / Math.max(len, 1e-3);
    // Hits at once, flickers, and falls off over the last third.
    const env = p < 0.66 ? 1 : 1 - (p - 0.66) / 0.34;
    return this.glitchStrength * env * (0.65 + 0.35 * Math.random());
  }

  private update(now: number, g: number): void {
    const s = this.level === 0 ? ZERO : TAPE_LEVELS[this.level];
    const u = this.tape.uniforms;
    const motion = this.motion;
    u.uTime!.value = now % 1000;
    u.uFrame!.value = this.frame % 997;
    u.uMotion!.value = motion ? 1 : 0;
    u.uLumaSoft!.value = s.lumaSoft;
    u.uChromaShift!.value = s.chromaShift;
    u.uChromaBlur!.value = s.chromaBlur;
    u.uSat!.value = s.saturation;
    u.uCoolSat!.value = s.coolSaturation;
    u.uRing!.value = s.ringing;
    u.uChromaNoise!.value = s.chromaNoise;
    u.uGrain!.value = s.grain + g * 0.12 + this.dark * 0.2;
    u.uScan!.value = s.scanlines;
    u.uWobble!.value = s.wobble;
    u.uHead!.value = s.headSwitch;
    u.uContrast!.value = s.contrast;
    u.uExposure!.value = s.exposure;
    u.uBloom!.value = s.bloom;
    u.uBloomThresh!.value = s.bloomThreshold;
    u.uLevels!.value = s.levels;
    u.uVignette!.value = s.vignette;
    u.uBarrel!.value = s.barrel;
    (u.uLift!.value as THREE.Vector3).fromArray(s.lift).addScalar(this.dark * 0.025);
    (u.uCast!.value as THREE.Vector3).fromArray(s.cast);
    u.uGlitch!.value = g;
    u.uTired!.value = this.tired;

    // Tracking roll: a band that climbs the picture from the bottom, strongest midway, then settles.
    if (motion && now >= this.nextRoll && this.roll.start < 0) {
      this.roll = { start: now, dur: 1.4 + Math.random() * 1.6, strength: s.trackingStrength * (0.6 + 0.4 * Math.random()) };
    }
    const roll = u.uRoll!.value as THREE.Vector3;
    if (this.roll.start >= 0) {
      const p = (now - this.roll.start) / this.roll.dur;
      if (p >= 1) {
        this.roll.start = -1;
        this.nextRoll = this.scheduleRoll(now);
        roll.set(0, 0, 0.06);
      } else {
        roll.set(-0.1 + p * 1.25, this.roll.strength * Math.sin(Math.PI * Math.min(1, p * 1.3)) ** 0.7, 0.035 + 0.03 * Math.sin(Math.PI * p));
      }
    } else {
      roll.set(0, 0, 0.06);
    }

    // Dropout streaks: rare, one or two frames each.
    const drop = u.uDrop!.value as THREE.Vector4;
    if (now < this.drop.until) {
      drop.set(this.drop.y, this.drop.x, this.drop.len, this.drop.s);
    } else if (motion && s.dropoutRate > 0 && Math.random() < s.dropoutRate / 60) {
      this.drop = { until: now + 0.02 + Math.random() * 0.04, y: 0.05 + Math.random() * 0.9, x: Math.random() * 0.9, len: 0.03 + Math.random() * 0.12, s: 0.5 + Math.random() * 0.4 };
      drop.set(this.drop.y, this.drop.x, this.drop.len, this.drop.s);
    } else {
      drop.set(0, 0, 0, 0);
    }
  }
}

/** Glitch on top of the clean picture (fx 0): no grade, no noise, only the interference. */
const ZERO: TapeSettings = {
  lumaSoft: 0,
  chromaShift: 0,
  chromaBlur: 0,
  saturation: 1,
  coolSaturation: 1,
  ringing: 0,
  chromaNoise: 0,
  grain: 0,
  scanlines: 0,
  wobble: 0,
  trackingEvery: 0,
  trackingStrength: 0,
  dropoutRate: 0,
  headSwitch: 0,
  lift: [0, 0, 0],
  contrast: 1,
  exposure: 1,
  bloom: 0,
  bloomThreshold: 10,
  cast: [1, 1, 1],
  levels: 0,
  vignette: 0,
  barrel: 0,
};
