// Sound, synthesised in code (no audio files). Web Audio starts on the first click, tap or key press,
// as browsers require; with no Web Audio at all every call here quietly does nothing.
//
//   - The Orderly's trolley: a rhythmic two-note metal squeak at walking cadence over a faint wheel
//     rumble, placed at the figure (HRTF panner) and heard from the camera. Its loudness and
//     muffling come from entity.ts audibility(); it is cut within about 50 ms when the figure
//     freezes, because the sudden silence is the scare.
//   - A very quiet fluorescent room tone, so silence has something to be silent against.
//   - A burst of tape hiss when the player is caught (placeholder).
//
// NOTE: these sounds were designed from first principles and checked by numbers (gains over time,
// cut-off time, oscillators running), not by ear.

// ------------------------------------------------------------------------------------------------
// Tuning: what each number does to the sound.

const SQUEAK = {
  /** Squeaks per second. One per step of the walk: ~1.7 reads as a heavy figure pushing at a walk. */
  cadenceHz: 1.7,
  /** The two notes, Hz. They alternate (high, low, high, low), like a wobbly castor catching on
   * each half turn. Further apart sounds more cartoonish; closer sounds like one note. */
  noteHigh: 1880,
  noteLow: 1430,
  /** Length of each squeak, seconds. Longer is whinier; under 0.1 it becomes a click. */
  noteLength: 0.19,
  /** Pitch rise across a squeak, as a fraction: the stick-slip of metal on metal bends upward. */
  glide: 0.045,
  /** Fast pitch wobble (Hz) and its depth (fraction): the scratchy, rough edge of the squeal. */
  roughHz: 34,
  roughDepth: 0.018,
  /** Inharmonic partials (multiples of the note) and their levels: what makes it metal, not a
   * whistle. 2.76 and 5.4 are bell-like ratios. */
  partials: [
    [1, 1],
    [2.76, 0.32],
    [5.4, 0.1],
  ] as const,
  /** Randomness: timing (fraction of a step), pitch (fraction), level (fraction). Keeps it from
   * sounding like a machine. */
  jitterTime: 0.09,
  jitterPitch: 0.03,
  jitterLevel: 0.3,
  /** Chance that a step's squeak is a short double chirp instead, and that it is skipped. */
  chirpChance: 0.12,
  skipChance: 0.08,
  /** Wheel rumble: low-passed brown noise. Level relative to the squeak, cutoff Hz, and the
   * wheel's rotation rate (Hz) that makes it throb, with throb depth 0..1. */
  rumbleLevel: 0.55,
  rumbleCutoff: 170,
  rumbleThrobHz: 5.6,
  rumbleThrobDepth: 0.35,
  /** Overall level of the trolley at audibility gain 1. */
  level: 0.6,
  /** Muffled (no line of sight): low-pass cutoff in Hz. Clear: wide open. */
  muffledCutoff: 650,
  clearCutoff: 16000,
  /** Gain smoothing time constants, seconds: cut (freeze) and rise (released). 0.012 s puts the
   * squeak 98% gone in 50 ms; the rise is softer so it fades in rather than pops. */
  cutTau: 0.012,
  riseTau: 0.05,
};

const ROOM = {
  /** Mains hum of the ballasts: fundamental Hz (twice 60 Hz) and the levels of harmonics 1..3. */
  humHz: 120,
  hum: [0.006, 0.0028, 0.0012],
  /** The tube buzz: a bright band of a buzzy wave, centre Hz and level. */
  buzzHz: 3100,
  buzz: 0.0016,
  /** Air hiss (high-passed noise) level. */
  hiss: 0.0016,
  /** Slow flicker of the buzz (Hz) and depth 0..1. */
  flickerHz: 0.23,
  flickerDepth: 0.5,
};

/** Tape hiss on being caught: level and length. */
const CAUGHT_HISS = { level: 0.22, seconds: 2.0 };

/** Seconds of scheduling look-ahead. */
const LOOKAHEAD = 0.15;

// ------------------------------------------------------------------------------------------------

type Ctx = AudioContext;

interface Vec3 {
  x: number;
  y: number;
  z: number;
}

function noiseBuffer(ctx: Ctx, seconds: number, brown: boolean): AudioBuffer {
  const n = Math.floor(ctx.sampleRate * seconds);
  const buf = ctx.createBuffer(1, n, ctx.sampleRate);
  const d = buf.getChannelData(0);
  let last = 0;
  for (let i = 0; i < n; i++) {
    const w = Math.random() * 2 - 1;
    if (brown) {
      last = (last + 0.02 * w) / 1.02;
      d[i] = last * 3.5;
    } else d[i] = w;
  }
  return buf;
}

function setPos(p: AudioParam | undefined, v: number, t: number): void {
  if (p) p.setTargetAtTime(v, t, 0.02);
}

export interface AudioState {
  /** The audio context exists and is running. */
  running: boolean;
  /** The trolley level being aimed for now (0 = silent). */
  gain: number;
  /** The trolley gain node's actual value at this moment. */
  nodeGain: number;
  /** Played through the low-pass (no line of sight). */
  muffled: boolean;
  /** Squeak notes started so far. */
  notes: number;
  /** Whether the room tone oscillators are running. */
  roomTone: boolean;
}

export class GameAudio {
  private ctx: Ctx | null = null;
  private failed = false;
  // Trolley chain.
  private squeakBus: GainNode | null = null;
  private muffle: BiquadFilterNode | null = null;
  private level: GainNode | null = null;
  private panner: PannerNode | null = null;
  private target = 0;
  private muffled = false;
  private nextNote = 0;
  private noteIndex = 0;
  private notes = 0;
  private silentFor = 0;
  private room = false;
  private hissBuf: AudioBuffer | null = null;

  constructor() {
    if (typeof window === 'undefined') return;
    const go = (): void => this.unlock();
    for (const ev of ['pointerdown', 'keydown', 'touchstart', 'click']) window.addEventListener(ev, go, { capture: true });
  }

  /** Creates (if needed) and resumes the context. Safe to call any number of times. */
  unlock(): void {
    if (this.failed) return;
    try {
      if (!this.ctx) this.build();
      const ctx = this.ctx;
      if (ctx && ctx.state !== 'running') void ctx.resume().catch(() => undefined);
    } catch {
      this.failed = true;
      this.ctx = null;
    }
  }

  private build(): void {
    const AC = (window as unknown as { AudioContext?: typeof AudioContext; webkitAudioContext?: typeof AudioContext }).AudioContext ??
      (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AC) {
      this.failed = true;
      return;
    }
    const ctx = new AC();
    this.ctx = ctx;
    const t = ctx.currentTime;

    // Trolley: notes and rumble -> bus -> muffle -> level -> panner -> out.
    this.squeakBus = ctx.createGain();
    this.muffle = ctx.createBiquadFilter();
    this.muffle.type = 'lowpass';
    this.muffle.frequency.value = SQUEAK.clearCutoff;
    this.muffle.Q.value = 0.7;
    this.level = ctx.createGain();
    this.level.gain.value = 0;
    this.panner = ctx.createPanner();
    this.panner.panningModel = 'HRTF';
    this.panner.distanceModel = 'linear';
    // Loudness over distance comes from audibility(); the panner only gives direction.
    this.panner.rolloffFactor = 0;
    this.squeakBus.connect(this.muffle).connect(this.level).connect(this.panner).connect(ctx.destination);

    const rumble = ctx.createBufferSource();
    rumble.buffer = noiseBuffer(ctx, 3, true);
    rumble.loop = true;
    const rumbleLp = ctx.createBiquadFilter();
    rumbleLp.type = 'lowpass';
    rumbleLp.frequency.value = SQUEAK.rumbleCutoff;
    const rumbleGain = ctx.createGain();
    rumbleGain.gain.value = SQUEAK.rumbleLevel;
    const throb = ctx.createOscillator();
    throb.frequency.value = SQUEAK.rumbleThrobHz;
    const throbDepth = ctx.createGain();
    throbDepth.gain.value = SQUEAK.rumbleLevel * SQUEAK.rumbleThrobDepth;
    throb.connect(throbDepth).connect(rumbleGain.gain);
    rumble.connect(rumbleLp).connect(rumbleGain).connect(this.squeakBus);
    rumble.start(t);
    throb.start(t);

    // Room tone: straight to the output, not positional.
    const roomOut = ctx.createGain();
    roomOut.gain.value = 1;
    roomOut.connect(ctx.destination);
    ROOM.hum.forEach((g, i) => {
      const o = ctx.createOscillator();
      o.frequency.value = ROOM.humHz * (i + 1);
      const og = ctx.createGain();
      og.gain.value = g;
      o.connect(og).connect(roomOut);
      o.start(t);
    });
    const buzz = ctx.createOscillator();
    buzz.type = 'sawtooth';
    buzz.frequency.value = ROOM.humHz;
    const buzzBp = ctx.createBiquadFilter();
    buzzBp.type = 'bandpass';
    buzzBp.frequency.value = ROOM.buzzHz;
    buzzBp.Q.value = 2;
    const buzzGain = ctx.createGain();
    buzzGain.gain.value = ROOM.buzz;
    const flicker = ctx.createOscillator();
    flicker.frequency.value = ROOM.flickerHz;
    const flickerDepth = ctx.createGain();
    flickerDepth.gain.value = ROOM.buzz * ROOM.flickerDepth;
    flicker.connect(flickerDepth).connect(buzzGain.gain);
    buzz.connect(buzzBp).connect(buzzGain).connect(roomOut);
    buzz.start(t);
    flicker.start(t);
    this.hissBuf = noiseBuffer(ctx, 2.5, false);
    const hiss = ctx.createBufferSource();
    hiss.buffer = this.hissBuf;
    hiss.loop = true;
    const hissHp = ctx.createBiquadFilter();
    hissHp.type = 'highpass';
    hissHp.frequency.value = 6000;
    const hissGain = ctx.createGain();
    hissGain.gain.value = ROOM.hiss;
    hiss.connect(hissHp).connect(hissGain).connect(roomOut);
    hiss.start(t);
    this.room = true;
  }

  /**
   * Per frame. `gain`/`muffled` from audibility() (gain already 0 if the figure is frozen or seen);
   * `source` the squeaking wheels; `ear` the camera with its forward and up vectors.
   */
  update(dt: number, gain: number, muffled: boolean, source: Vec3, ear: Vec3, forward: Vec3, up: Vec3): void {
    const want = Math.max(0, Math.min(1, gain));
    const ctx = this.ctx;
    if (!ctx || !this.level || !this.muffle || !this.panner) {
      this.target = want;
      this.muffled = muffled;
      return;
    }
    try {
      const t = ctx.currentTime;
      if (want !== this.target) {
        // A cut is near-instant; a rise is a quick fade.
        this.level.gain.cancelScheduledValues(t);
        this.level.gain.setTargetAtTime(want * SQUEAK.level, t, want < this.target ? SQUEAK.cutTau : SQUEAK.riseTau);
      }
      if (muffled !== this.muffled) this.muffle.frequency.setTargetAtTime(muffled ? SQUEAK.muffledCutoff : SQUEAK.clearCutoff, t, 0.03);
      this.target = want;
      this.muffled = muffled;

      const p = this.panner;
      setPos(p.positionX, source.x, t);
      setPos(p.positionY, source.y, t);
      setPos(p.positionZ, source.z, t);
      const l = ctx.listener;
      if (l.positionX) {
        setPos(l.positionX, ear.x, t);
        setPos(l.positionY, ear.y, t);
        setPos(l.positionZ, ear.z, t);
        setPos(l.forwardX, forward.x, t);
        setPos(l.forwardY, forward.y, t);
        setPos(l.forwardZ, forward.z, t);
        setPos(l.upX, up.x, t);
        setPos(l.upY, up.y, t);
        setPos(l.upZ, up.z, t);
      } else {
        l.setPosition(ear.x, ear.y, ear.z);
        l.setOrientation(forward.x, forward.y, forward.z, up.x, up.y, up.z);
      }

      // Squeaks are scheduled only while it is (or was a moment ago) audible.
      this.silentFor = want > 0 ? 0 : this.silentFor + dt;
      if (this.silentFor > 0.4) {
        this.nextNote = 0;
        return;
      }
      // Released: the first squeak comes at once, so the sound is recognisable straight away.
      if (this.nextNote < t) this.nextNote = t + 0.01;
      while (this.nextNote < t + LOOKAHEAD) {
        this.scheduleStep(this.nextNote);
        const step = 1 / SQUEAK.cadenceHz;
        this.nextNote += step * (1 + (Math.random() * 2 - 1) * SQUEAK.jitterTime);
      }
    } catch {
      /* audio must never break the game */
    }
  }

  private scheduleStep(at: number): void {
    const r = Math.random();
    const high = this.noteIndex++ % 2 === 0;
    if (r < SQUEAK.skipChance) return;
    const base = (high ? SQUEAK.noteHigh : SQUEAK.noteLow) * (1 + (Math.random() * 2 - 1) * SQUEAK.jitterPitch);
    const lvl = 1 + (Math.random() * 2 - 1) * SQUEAK.jitterLevel;
    if (r < SQUEAK.skipChance + SQUEAK.chirpChance) {
      this.note(at, base * 1.06, SQUEAK.noteLength * 0.4, lvl * 0.8);
      this.note(at + SQUEAK.noteLength * 0.55, base, SQUEAK.noteLength * 0.5, lvl * 0.9);
    } else this.note(at, base, SQUEAK.noteLength, lvl);
  }

  /** One squeak: a few inharmonic partials, gliding up, roughened by a fast wobble. */
  private note(at: number, freq: number, len: number, lvl: number): void {
    const ctx = this.ctx;
    if (!ctx || !this.squeakBus) return;
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, at);
    env.gain.linearRampToValueAtTime(0.32 * lvl, at + 0.015);
    env.gain.setValueAtTime(0.32 * lvl, at + len * 0.55);
    env.gain.exponentialRampToValueAtTime(0.001, at + len);
    env.connect(this.squeakBus);
    const rough = ctx.createOscillator();
    rough.frequency.value = SQUEAK.roughHz * (0.85 + Math.random() * 0.3);
    rough.start(at);
    rough.stop(at + len + 0.02);
    for (const [mult, g] of SQUEAK.partials) {
      const o = ctx.createOscillator();
      const f = freq * mult;
      o.frequency.setValueAtTime(f, at);
      o.frequency.linearRampToValueAtTime(f * (1 + SQUEAK.glide), at + len * 0.7);
      o.frequency.linearRampToValueAtTime(f * (1 + SQUEAK.glide * 0.6), at + len);
      const depth = ctx.createGain();
      depth.gain.value = f * SQUEAK.roughDepth;
      rough.connect(depth).connect(o.frequency);
      const pg = ctx.createGain();
      pg.gain.value = g;
      o.connect(pg).connect(env);
      o.start(at);
      o.stop(at + len + 0.02);
    }
    this.notes++;
  }

  /** A burst of hiss (being caught). */
  caughtBurst(): void {
    const ctx = this.ctx;
    if (!ctx || !this.hissBuf) return;
    try {
      const t = ctx.currentTime;
      const src = ctx.createBufferSource();
      src.buffer = this.hissBuf;
      src.loop = true;
      const g = ctx.createGain();
      g.gain.setValueAtTime(CAUGHT_HISS.level, t);
      g.gain.setValueAtTime(CAUGHT_HISS.level, t + CAUGHT_HISS.seconds - 0.05);
      g.gain.linearRampToValueAtTime(0, t + CAUGHT_HISS.seconds);
      src.connect(g).connect(ctx.destination);
      src.start(t);
      src.stop(t + CAUGHT_HISS.seconds + 0.05);
    } catch {
      /* ignore */
    }
  }

  state(): AudioState {
    return {
      running: this.ctx?.state === 'running',
      gain: this.target,
      nodeGain: this.level ? this.level.gain.value / SQUEAK.level : 0,
      muffled: this.muffled,
      notes: this.notes,
      roomTone: this.room && this.ctx?.state === 'running',
    };
  }
}
