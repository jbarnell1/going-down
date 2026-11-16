// Sound, synthesised in code (no audio files). Web Audio starts on the first click, tap or key press,
// as browsers require; with no Web Audio at all every call here quietly does nothing.
//
//   - The Orderly's trolley: a rhythmic two-note metal squeak at walking cadence over a faint wheel
//     rumble, placed at the figure (HRTF panner) and heard from the camera. Its loudness and
//     muffling come from entity.ts audibility(); it is cut within about 50 ms when the figure
//     freezes, because the sudden silence is the scare.
//   - A very quiet fluorescent room tone, so silence has something to be silent against.
//   - A burst of tape hiss when the player is caught (placeholder).
//   - The instrument's ticking: a dry mechanical tick, part Geiger counter, part film camera claw,
//     at the logic's tickHz and loudness. About once a second at rest, racing as a reading builds.
//     Its acceleration is the game's main tension device, so it sits well above everything else.
//   - A soft thunk and a short paper rasp when a reading closes; a longer rasp when the slip prints.
//   - The trolley's cadence, note length and wheel throb follow the Orderly's speed: a slow, drawn-out
//     creak at its creep, a frantic rattle at its run.
//
//   - The elevator (all of it in LIFT below): the call chime, loud and slightly wrong; the machinery
//     of the car coming, a motor drone and cable rattle that grow as it nears; a soft ding per floor on
//     the indicator; the doors' motor whirr and thump; the muffled chime and doors of a false stop one
//     floor up; two warning dings and then the bell before the doors close; the ride between floors, a
//     falling hum with the room tone gone.
//   - The blink: the warning is the chime stuttering and the lights' ballasts crackling; the dark is a
//     relay clunk and the room tone cut; the lights coming back are a ballast ping and the hum returning.
//
// NOTE: these sounds were designed from first principles and checked by numbers (gains over time,
// cut-off time, oscillators running), not by ear. Nobody has listened to the elevator sounds.

// ------------------------------------------------------------------------------------------------
// Tuning: what each number does to the sound.

const SQUEAK = {
  /** Squeaks per second at its run (HUNT_SPEED). One per step: fast enough to sound frantic. */
  cadenceHz: 2.5,
  /** Squeaks per second at its creep (CREEP_SPEED): slow and deliberate, a long gap between steps. */
  cadenceCreepHz: 0.72,
  /** The speeds (m/s) those two cadences belong to; in between it is interpolated. */
  runSpeed: 3.4,
  creepSpeed: 1.3,
  /** Note length multiplier at the creep: each squeak is drawn out into a slow, whining creak. */
  creepNoteStretch: 1.9,
  /** Pitch multiplier at the creep: a touch lower, heavier. */
  creepPitch: 0.9,
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

const TICK = {
  /** Peak level of a tick at loudness 1. The squeak peaks near 0.2 and the room tone near 0.01, so
   * even the rest tick (loudness 0.1) clears the room tone and a racing tick dominates the squeak. */
  level: 0.85,
  /** Length of one tick's sample, seconds. Short is dry and mechanical; longer starts to ring. */
  seconds: 0.045,
  /** The click: noise burst through a resonance at this centre (Hz), decaying with this time
   * constant (s). Around 3 kHz cuts through everything without being shrill. */
  clickHz: 3200,
  clickDecay: 0.0035,
  /** The claw: a short pitched knock (Hz) and its decay (s), level relative to the click. This is
   * the film-camera part; the two variants alternate pitch so the run sounds like a mechanism. */
  clawHz: [1250, 1050] as const,
  clawDecay: 0.009,
  clawLevel: 0.45,
  /** The body: a low thump (Hz), decay (s) and level, so the tick has weight on small speakers. */
  bodyHz: 210,
  bodyDecay: 0.014,
  bodyLevel: 0.35,
  /** Timing randomness as a fraction of the interval: a touch of Geiger irregularity. */
  jitter: 0.22,
  /** Level randomness, fraction. */
  levelJitter: 0.18,
};

const THUNK = {
  /** A soft mechanical thunk when a reading closes: start and end pitch (Hz), length (s), level. */
  fromHz: 140,
  toHz: 55,
  seconds: 0.16,
  level: 0.5,
};

const RASP = {
  /** Paper printing: band-passed noise (centre Hz, Q) chopped by the print head at this rate (Hz). */
  centreHz: 2400,
  q: 1.6,
  chopHz: 38,
  /** Level, and lengths (s) for a closed reading and for the slip. */
  level: 0.22,
  readingSeconds: 0.35,
  slipSeconds: 1.05,
};

/** The elevator and the blink. */
const LIFT = {
  /** The call chime: two notes (Hz), the second detuned flat by `wrongCents` so it sounds slightly
   * off, each about `noteSeconds` long, at `chimeLevel` (loud: the ticking peaks at 0.85). */
  chime: [784, 523.25] as const,
  wrongCents: -38,
  noteSeconds: 0.75,
  chimeLevel: 0.42,
  /** Bell-like partials of each chime note (multiple, level). */
  chimePartials: [
    [1, 1],
    [2.0, 0.28],
    [2.76, 0.12],
  ] as const,
  /** Machinery of the car coming: motor drone (Hz, sawtooth through a low-pass at `droneCutoff`),
   * cable rattle (band-passed noise, centre Hz, level against the drone), and the overall level when
   * the car is far (just called) and when it arrives; in between it rises as level^1.6. */
  droneHz: 46,
  droneCutoff: 240,
  rattleHz: 900,
  rattleLevel: 0.35,
  machineFar: 0.012,
  machineNear: 0.16,
  /** Seconds for the machinery level to follow (smoothing). */
  machineTau: 0.6,
  /** A ding per floor on the indicator: pitch Hz, length s, level far and near. */
  dingHz: 1318,
  dingSeconds: 0.45,
  dingFar: 0.03,
  dingNear: 0.14,
  /** Doors: motor whirr (band-passed noise centre Hz, sweeping by `whirrSweep`) for `doorSeconds`,
   * then a thump (Hz, level). Muffled (false stop above): through a low-pass at `muffledCutoff`, scaled
   * by `muffledLevel`. */
  whirrHz: 520,
  whirrSweep: 1.6,
  whirrLevel: 0.12,
  doorSeconds: 0.9,
  thumpHz: 70,
  thumpLevel: 0.35,
  muffledCutoff: 420,
  muffledLevel: 0.35,
  /** The bell before the doors close: a bright strike (Hz), length s, level; the warning dings before
   * it (at 5 s and 3 s left) are softer copies at `warnLevel`. */
  bellHz: 1046.5,
  bellSeconds: 1.4,
  bellLevel: 0.36,
  warnLevel: 0.14,
  /** The ride down: a hum falling from `rideFromHz` to `rideToHz` over the ride, level, plus rumble. */
  rideFromHz: 96,
  rideToHz: 52,
  rideLevel: 0.12,
  rideRumble: 0.09,
  /** The blink warning: the chime's first note cut into `stutters` fragments over `stutterSeconds`,
   * at `stutterLevel`, over a ballast crackle at `crackleLevel`. */
  stutters: 4,
  stutterSeconds: 0.5,
  stutterLevel: 0.2,
  crackleLevel: 0.1,
  /** The dark: a relay clunk (Hz, level); the room tone falls to `roomDark` of its level. */
  clunkHz: 90,
  clunkLevel: 0.45,
  roomDark: 0.0,
  /** The lights back: a ballast ping (Hz, level). */
  pingHz: 2600,
  pingLevel: 0.05,
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

/**
 * One tick, rendered once into a buffer: a resonant noise click, a short pitched claw knock and a low
 * body thump, all decaying within a few milliseconds.
 */
function tickBuffer(ctx: Ctx, clawHz: number): AudioBuffer {
  const sr = ctx.sampleRate;
  const n = Math.floor(sr * TICK.seconds);
  const buf = ctx.createBuffer(1, n, sr);
  const d = buf.getChannelData(0);
  // A two-pole resonator for the click, run over decaying white noise.
  const w = (2 * Math.PI * TICK.clickHz) / sr;
  const r = 0.985;
  const a1 = 2 * r * Math.cos(w);
  const a2 = -r * r;
  let y1 = 0;
  let y2 = 0;
  let peak = 0;
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    const noise = (Math.random() * 2 - 1) * Math.exp(-t / TICK.clickDecay);
    const y = noise * (1 - r) * 4 + a1 * y1 + a2 * y2;
    y2 = y1;
    y1 = y;
    const click = y + noise * 0.35;
    const claw = Math.sin(2 * Math.PI * clawHz * t) * Math.exp(-t / TICK.clawDecay) * TICK.clawLevel;
    const body = Math.sin(2 * Math.PI * TICK.bodyHz * t) * Math.exp(-t / TICK.bodyDecay) * TICK.bodyLevel;
    const v = click + claw + body;
    d[i] = v;
    peak = Math.max(peak, Math.abs(v));
  }
  // Normalised, so TICK.level is the true peak.
  if (peak > 0) for (let i = 0; i < n; i++) d[i] = (d[i] ?? 0) / peak;
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
  /** The instrument's tick rate (ticks per second) and level (0..1, the logic's loudness) now. */
  tickHz: number;
  tickLevel: number;
  /** Ticks started so far. */
  ticks: number;
  /** Thunks and paper rasps started so far. */
  thunks: number;
  rasps: number;
  /** The trolley's cadence now (squeaks per second, from the Orderly's speed). */
  cadenceHz: number;
  /** Elevator sounds started so far. */
  chimes: number;
  dings: number;
  doorSounds: number;
  bells: number;
  warnDings: number;
  blinkWarnings: number;
  blinkOuts: number;
  /** Machinery level being aimed for (0 silent .. 1 arriving) and whether the ride hum is playing. */
  machine: number;
  riding: boolean;
  /** Room tone level aimed for: 1 normal, 0 gone (ride, blink). */
  room: number;
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
  private throb: OscillatorNode | null = null;
  /** The Orderly's last moving speed: it keeps the cadence across a freeze. */
  private speed = SQUEAK.runSpeed;
  // Ticking.
  private tickBufs: AudioBuffer[] = [];
  private tickHz = 0;
  private tickLevel = 0;
  /** The jitter factor for the gap after the last tick. */
  private nextTick = 1;
  /** When the last tick was scheduled (context seconds), or -1 when not ticking. */
  private lastTick = -1;
  private ticks = 0;
  private thunks = 0;
  private rasps = 0;
  // Elevator.
  private roomOut: GainNode | null = null;
  private roomWant = 1;
  private blinkDark = false;
  private machineGain: GainNode | null = null;
  private machinePanner: PannerNode | null = null;
  private machineWant = 0;
  private rideOn = false;
  private rideNodes: AudioScheduledSourceNode[] = [];
  private rideGain: GainNode | null = null;
  private counts = { chimes: 0, dings: 0, doorSounds: 0, bells: 0, warnDings: 0, blinkWarnings: 0, blinkOuts: 0 };

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
    this.throb = throb;
    this.tickBufs = TICK.clawHz.map((hz) => tickBuffer(ctx, hz));

    // Room tone: straight to the output, not positional.
    const roomOut = ctx.createGain();
    roomOut.gain.value = this.roomWant;
    roomOut.connect(ctx.destination);
    this.roomOut = roomOut;
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

    // The car's machinery: drone and rattle -> gain -> panner at the doors. Silent until called.
    const mg = ctx.createGain();
    mg.gain.value = 0;
    const mp = ctx.createPanner();
    mp.panningModel = 'HRTF';
    mp.distanceModel = 'linear';
    mp.rolloffFactor = 0;
    mg.connect(mp).connect(ctx.destination);
    const drone = ctx.createOscillator();
    drone.type = 'sawtooth';
    drone.frequency.value = LIFT.droneHz;
    const droneLp = ctx.createBiquadFilter();
    droneLp.type = 'lowpass';
    droneLp.frequency.value = LIFT.droneCutoff;
    drone.connect(droneLp).connect(mg);
    const wobble = ctx.createOscillator();
    wobble.frequency.value = 0.7;
    const wobbleDepth = ctx.createGain();
    wobbleDepth.gain.value = 3;
    wobble.connect(wobbleDepth).connect(drone.frequency);
    const rattle = ctx.createBufferSource();
    rattle.buffer = noiseBuffer(ctx, 2, false);
    rattle.loop = true;
    const rattleBp = ctx.createBiquadFilter();
    rattleBp.type = 'bandpass';
    rattleBp.frequency.value = LIFT.rattleHz;
    rattleBp.Q.value = 3;
    const rattleGain = ctx.createGain();
    rattleGain.gain.value = LIFT.rattleLevel;
    rattle.connect(rattleBp).connect(rattleGain).connect(mg);
    drone.start(t);
    wobble.start(t);
    rattle.start(t);
    this.machineGain = mg;
    this.machinePanner = mp;
  }

  /**
   * Per frame. `gain`/`muffled` from audibility() (gain already 0 if the figure is frozen or seen);
   * `source` the squeaking wheels; `ear` the camera with its forward and up vectors.
   */
  update(dt: number, gain: number, muffled: boolean, source: Vec3, ear: Vec3, forward: Vec3, up: Vec3, speed = SQUEAK.runSpeed): void {
    const want = Math.max(0, Math.min(1, gain));
    if (speed > 0.05) this.speed = speed;
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
      this.throb?.frequency.setTargetAtTime(SQUEAK.rumbleThrobHz * (this.speed / SQUEAK.runSpeed), t, 0.1);
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
        const step = 1 / this.cadence();
        this.nextNote += step * (1 + (Math.random() * 2 - 1) * SQUEAK.jitterTime);
      }
    } catch {
      /* audio must never break the game */
    }
  }

  /** 0 at the creep, 1 at the run. */
  private pace(): number {
    return Math.max(0, Math.min(1, (this.speed - SQUEAK.creepSpeed) / (SQUEAK.runSpeed - SQUEAK.creepSpeed)));
  }

  /** Squeaks per second for the Orderly's current speed. */
  private cadence(): number {
    const k = this.pace();
    return SQUEAK.cadenceCreepHz + (SQUEAK.cadenceHz - SQUEAK.cadenceCreepHz) * k;
  }

  private scheduleStep(at: number): void {
    const r = Math.random();
    const high = this.noteIndex++ % 2 === 0;
    if (r < SQUEAK.skipChance) return;
    const k = this.pace();
    const len = SQUEAK.noteLength * (SQUEAK.creepNoteStretch + (1 - SQUEAK.creepNoteStretch) * k);
    const pitch = SQUEAK.creepPitch + (1 - SQUEAK.creepPitch) * k;
    const base = (high ? SQUEAK.noteHigh : SQUEAK.noteLow) * pitch * (1 + (Math.random() * 2 - 1) * SQUEAK.jitterPitch);
    const lvl = 1 + (Math.random() * 2 - 1) * SQUEAK.jitterLevel;
    if (r < SQUEAK.skipChance + SQUEAK.chirpChance) {
      this.note(at, base * 1.06, len * 0.4, lvl * 0.8);
      this.note(at + len * 0.55, base, len * 0.5, lvl * 0.9);
    } else this.note(at, base, len, lvl);
  }

  /**
   * Per frame: the instrument's ticking. `hz` and `loudness` straight from the logic (0 when lowered).
   * Ticks are scheduled slightly ahead; a faster rate pulls the next tick in at once, so the
   * acceleration is heard the moment it happens.
   */
  ticking(hz: number, loudness: number): void {
    this.tickHz = Math.max(0, hz);
    this.tickLevel = Math.max(0, Math.min(1, loudness));
    const ctx = this.ctx;
    if (!ctx || this.tickBufs.length === 0) return;
    try {
      const t = ctx.currentTime;
      if (this.tickHz <= 0 || this.tickLevel <= 0) {
        this.lastTick = -1;
        return;
      }
      // The next tick is always measured from the last one at TODAY's rate, so a faster rate is heard
      // at once. Raised just now: the first tick comes promptly.
      const interval = 1 / this.tickHz;
      let next = this.lastTick < 0 ? t + 0.03 : this.lastTick + interval * this.nextTick;
      if (next < t) next = t + 0.005;
      while (next < t + LOOKAHEAD) {
        this.playTick(next, this.tickLevel);
        this.lastTick = next;
        this.nextTick = 1 + (Math.random() * 2 - 1) * TICK.jitter;
        next = this.lastTick + interval * this.nextTick;
      }
    } catch {
      /* audio must never break the game */
    }
  }

  private playTick(at: number, loudness: number): void {
    const ctx = this.ctx;
    const buf = this.tickBufs[this.ticks % this.tickBufs.length];
    if (!ctx || !buf) return;
    const src = ctx.createBufferSource();
    src.buffer = buf;
    const g = ctx.createGain();
    g.gain.value = TICK.level * loudness * (1 + (Math.random() * 2 - 1) * TICK.levelJitter);
    src.connect(g).connect(ctx.destination);
    src.start(at);
    this.ticks++;
  }

  /** A reading closed: a soft thunk and a short rasp of paper. */
  readingClosed(): void {
    const ctx = this.ctx;
    if (!ctx) return;
    try {
      const t = ctx.currentTime + 0.01;
      const o = ctx.createOscillator();
      o.frequency.setValueAtTime(THUNK.fromHz, t);
      o.frequency.exponentialRampToValueAtTime(THUNK.toHz, t + THUNK.seconds);
      const g = ctx.createGain();
      g.gain.setValueAtTime(0, t);
      g.gain.linearRampToValueAtTime(THUNK.level, t + 0.006);
      g.gain.exponentialRampToValueAtTime(0.001, t + THUNK.seconds);
      o.connect(g).connect(ctx.destination);
      o.start(t);
      o.stop(t + THUNK.seconds + 0.02);
      this.thunks++;
      this.rasp(t + 0.12, RASP.readingSeconds);
    } catch {
      /* ignore */
    }
  }

  /** The slip prints: a longer rasp. */
  slipPrinted(): void {
    const ctx = this.ctx;
    if (!ctx) return;
    try {
      this.rasp(ctx.currentTime + 0.01, RASP.slipSeconds);
    } catch {
      /* ignore */
    }
  }

  private rasp(at: number, seconds: number): void {
    const ctx = this.ctx;
    if (!ctx || !this.hissBuf) return;
    const src = ctx.createBufferSource();
    src.buffer = this.hissBuf;
    src.loop = true;
    const bp = ctx.createBiquadFilter();
    bp.type = 'bandpass';
    bp.frequency.value = RASP.centreHz;
    bp.Q.value = RASP.q;
    // The print head: the level chopped by a square wave between nearly silent and full.
    const chop = ctx.createGain();
    chop.gain.value = 0.5;
    const head = ctx.createOscillator();
    head.type = 'square';
    head.frequency.value = RASP.chopHz;
    const depth = ctx.createGain();
    depth.gain.value = 0.5;
    head.connect(depth).connect(chop.gain);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, at);
    env.gain.linearRampToValueAtTime(RASP.level, at + 0.02);
    env.gain.setValueAtTime(RASP.level, at + seconds - 0.05);
    env.gain.linearRampToValueAtTime(0, at + seconds);
    src.connect(bp).connect(chop).connect(env).connect(ctx.destination);
    src.start(at, Math.random() * 2);
    head.start(at);
    src.stop(at + seconds + 0.02);
    head.stop(at + seconds + 0.02);
    this.rasps++;
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

  // ---------------------------------------------------------------------------------------------
  // The elevator and the blink.

  /** Runs `fn` with the context and a start time just ahead, swallowing any audio error. */
  private play(fn: (ctx: Ctx, t: number) => void): void {
    const ctx = this.ctx;
    if (!ctx) return;
    try {
      fn(ctx, ctx.currentTime + 0.01);
    } catch {
      /* audio must never break the game */
    }
  }

  /** A struck bell-ish note: partials decaying exponentially, into `out`. */
  private strike(ctx: Ctx, at: number, hz: number, seconds: number, level: number, out: AudioNode, partials: readonly (readonly [number, number])[] = LIFT.chimePartials): void {
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, at);
    env.gain.linearRampToValueAtTime(level, at + 0.008);
    env.gain.exponentialRampToValueAtTime(0.0008, at + seconds);
    env.connect(out);
    for (const [mult, g] of partials) {
      const o = ctx.createOscillator();
      o.frequency.value = hz * mult;
      const pg = ctx.createGain();
      pg.gain.value = g;
      o.connect(pg).connect(env);
      o.start(at);
      o.stop(at + seconds + 0.02);
    }
  }

  /** A low-pass into the output for muffled sounds (heard through a floor), or the output itself. */
  private outFor(ctx: Ctx, muffled: boolean): AudioNode {
    if (!muffled) return ctx.destination;
    const lp = ctx.createBiquadFilter();
    lp.type = 'lowpass';
    lp.frequency.value = LIFT.muffledCutoff;
    const g = ctx.createGain();
    g.gain.value = LIFT.muffledLevel;
    lp.connect(g).connect(ctx.destination);
    return lp;
  }

  /** The call chime: loud, two notes, the second one flat. Muffled: a false stop one floor up. */
  callChime(muffled = false): void {
    this.play((ctx, t) => {
      const out = this.outFor(ctx, muffled);
      const [a, b] = LIFT.chime;
      this.strike(ctx, t, a, LIFT.noteSeconds * 1.4, LIFT.chimeLevel, out);
      this.strike(ctx, t + LIFT.noteSeconds * 0.55, b * 2 ** (LIFT.wrongCents / 1200), LIFT.noteSeconds * 1.8, LIFT.chimeLevel, out);
      this.counts.chimes++;
    });
  }

  /** One floor on the indicator: a soft ding, louder the nearer the car (`near` 0 far .. 1 here). */
  floorDing(near: number): void {
    this.play((ctx, t) => {
      const k = Math.max(0, Math.min(1, near));
      this.strike(ctx, t, LIFT.dingHz, LIFT.dingSeconds, LIFT.dingFar + (LIFT.dingNear - LIFT.dingFar) * k, ctx.destination, [
        [1, 1],
        [2.4, 0.15],
      ]);
      this.counts.dings++;
    });
  }

  /** The doors opening or closing: a motor whirr, then a thump as they meet (softer opening). */
  doors(open: boolean, muffled = false): void {
    this.play((ctx, t) => {
      if (!this.hissBuf) return;
      const out = this.outFor(ctx, muffled);
      const src = ctx.createBufferSource();
      src.buffer = this.hissBuf;
      src.loop = true;
      const bp = ctx.createBiquadFilter();
      bp.type = 'bandpass';
      bp.Q.value = 4;
      const f0 = open ? LIFT.whirrHz : LIFT.whirrHz * LIFT.whirrSweep;
      const f1 = open ? LIFT.whirrHz * LIFT.whirrSweep : LIFT.whirrHz;
      bp.frequency.setValueAtTime(f0, t);
      bp.frequency.linearRampToValueAtTime(f1, t + LIFT.doorSeconds);
      const env = ctx.createGain();
      env.gain.setValueAtTime(0, t);
      env.gain.linearRampToValueAtTime(LIFT.whirrLevel, t + 0.12);
      env.gain.setValueAtTime(LIFT.whirrLevel, t + LIFT.doorSeconds - 0.15);
      env.gain.linearRampToValueAtTime(0, t + LIFT.doorSeconds);
      src.connect(bp).connect(env).connect(out);
      src.start(t, Math.random());
      src.stop(t + LIFT.doorSeconds + 0.05);
      const end = t + LIFT.doorSeconds;
      const o = ctx.createOscillator();
      o.frequency.setValueAtTime(open ? LIFT.thumpHz * 1.5 : LIFT.thumpHz, end);
      o.frequency.exponentialRampToValueAtTime(LIFT.thumpHz * 0.6, end + 0.15);
      const g = ctx.createGain();
      g.gain.setValueAtTime(0, end);
      g.gain.linearRampToValueAtTime(open ? LIFT.thumpLevel * 0.35 : LIFT.thumpLevel, end + 0.005);
      g.gain.exponentialRampToValueAtTime(0.001, end + 0.18);
      o.connect(g).connect(out);
      o.start(end);
      o.stop(end + 0.2);
      this.counts.doorSounds++;
    });
  }

  /** A softer warning ding before the bell. */
  bellWarning(): void {
    this.play((ctx, t) => {
      this.strike(ctx, t, LIFT.bellHz, LIFT.bellSeconds * 0.5, LIFT.warnLevel, ctx.destination, [
        [1, 1],
        [2.0, 0.3],
      ]);
      this.counts.warnDings++;
    });
  }

  /** The bell: the doors close now. */
  bell(): void {
    this.play((ctx, t) => {
      this.strike(ctx, t, LIFT.bellHz, LIFT.bellSeconds, LIFT.bellLevel, ctx.destination, [
        [1, 1],
        [2.0, 0.4],
        [3.0, 0.15],
      ]);
      this.counts.bells++;
    });
  }

  /** The car's machinery while it comes: `level` 0 silent .. 1 arriving; `at` the doors. Per frame. */
  machinery(level: number, at: Vec3): void {
    const want = Math.max(0, Math.min(1, level));
    const ctx = this.ctx;
    if (!ctx || !this.machineGain || !this.machinePanner) {
      this.machineWant = want;
      return;
    }
    try {
      const t = ctx.currentTime;
      if (want !== this.machineWant) {
        const g = want <= 0 ? 0 : LIFT.machineFar + (LIFT.machineNear - LIFT.machineFar) * want ** 1.6;
        this.machineGain.gain.setTargetAtTime(g, t, want <= 0 ? 0.15 : LIFT.machineTau);
      }
      this.machineWant = want;
      setPos(this.machinePanner.positionX, at.x, t);
      setPos(this.machinePanner.positionY, at.y, t);
      setPos(this.machinePanner.positionZ, at.z, t);
    } catch {
      /* ignore */
    }
  }

  /** The ride between floors: a falling hum over `seconds`, and the room tone goes. Off: it stops. */
  ride(on: boolean, seconds = 6): void {
    if (on === this.rideOn) return;
    this.rideOn = on;
    this.setRoom(on ? 0 : this.blinkDark ? LIFT.roomDark : 1);
    this.play((ctx, t) => {
      if (!on) {
        this.rideGain?.gain.setTargetAtTime(0, t, 0.2);
        for (const n of this.rideNodes) n.stop(t + 1);
        this.rideNodes = [];
        this.rideGain = null;
        return;
      }
      const g = ctx.createGain();
      g.gain.setValueAtTime(0, t);
      g.gain.linearRampToValueAtTime(LIFT.rideLevel, t + 0.6);
      g.connect(ctx.destination);
      const o = ctx.createOscillator();
      o.type = 'triangle';
      o.frequency.setValueAtTime(LIFT.rideFromHz, t);
      o.frequency.exponentialRampToValueAtTime(LIFT.rideToHz, t + seconds);
      o.connect(g);
      const o2 = ctx.createOscillator();
      o2.frequency.setValueAtTime(LIFT.rideFromHz * 1.5, t);
      o2.frequency.exponentialRampToValueAtTime(LIFT.rideToHz * 1.5, t + seconds);
      const g2 = ctx.createGain();
      g2.gain.value = 0.3;
      o2.connect(g2).connect(g);
      const rum = ctx.createBufferSource();
      rum.buffer = noiseBuffer(ctx, 2, true);
      rum.loop = true;
      const rg = ctx.createGain();
      rg.gain.value = LIFT.rideRumble / LIFT.rideLevel;
      rum.connect(rg).connect(g);
      o.start(t);
      o2.start(t);
      rum.start(t);
      this.rideGain = g;
      this.rideNodes = [o, o2, rum];
    });
  }

  /** The blink is coming: the chime stutters and the ballasts crackle. */
  blinkWarning(): void {
    this.play((ctx, t) => {
      const frag = LIFT.stutterSeconds / LIFT.stutters;
      for (let i = 0; i < LIFT.stutters; i++) {
        const at = t + i * frag;
        // Each fragment a clipped, slightly lower restart of the chime's first note.
        const env = ctx.createGain();
        env.gain.setValueAtTime(0, at);
        env.gain.linearRampToValueAtTime(LIFT.stutterLevel, at + 0.005);
        env.gain.setValueAtTime(LIFT.stutterLevel, at + frag * 0.5);
        env.gain.linearRampToValueAtTime(0, at + frag * 0.6);
        env.connect(ctx.destination);
        const o = ctx.createOscillator();
        o.frequency.value = LIFT.chime[0] * (1 - 0.03 * i);
        o.connect(env);
        o.start(at);
        o.stop(at + frag);
      }
      if (this.hissBuf) {
        const src = ctx.createBufferSource();
        src.buffer = this.hissBuf;
        const hp = ctx.createBiquadFilter();
        hp.type = 'highpass';
        hp.frequency.value = 3000;
        const chop = ctx.createGain();
        chop.gain.value = 0;
        // Crackle: random on/off gates over the warning.
        for (let k = 0; k < 14; k++) chop.gain.setValueAtTime(Math.random() < 0.5 ? LIFT.crackleLevel : 0, t + (k * LIFT.stutterSeconds) / 14);
        chop.gain.setValueAtTime(0, t + LIFT.stutterSeconds + 0.05);
        src.connect(hp).connect(chop).connect(ctx.destination);
        src.start(t, Math.random());
        src.stop(t + LIFT.stutterSeconds + 0.1);
      }
      this.counts.blinkWarnings++;
    });
  }

  /** The lights fail (true) or come back (false). */
  blink(dark: boolean): void {
    if (dark === this.blinkDark) return;
    this.blinkDark = dark;
    this.setRoom(this.rideOn ? 0 : dark ? LIFT.roomDark : 1);
    this.play((ctx, t) => {
      if (dark) {
        const o = ctx.createOscillator();
        o.type = 'square';
        o.frequency.setValueAtTime(LIFT.clunkHz, t);
        o.frequency.exponentialRampToValueAtTime(LIFT.clunkHz * 0.5, t + 0.08);
        const lp = ctx.createBiquadFilter();
        lp.type = 'lowpass';
        lp.frequency.value = 400;
        const g = ctx.createGain();
        g.gain.setValueAtTime(LIFT.clunkLevel, t);
        g.gain.exponentialRampToValueAtTime(0.001, t + 0.12);
        o.connect(lp).connect(g).connect(ctx.destination);
        o.start(t);
        o.stop(t + 0.14);
        this.counts.blinkOuts++;
      } else {
        this.strike(ctx, t, LIFT.pingHz, 0.25, LIFT.pingLevel, ctx.destination, [[1, 1]]);
      }
    });
  }

  private setRoom(level: number): void {
    const was = this.roomWant;
    this.roomWant = level;
    const ctx = this.ctx;
    if (!ctx || !this.roomOut) return;
    try {
      this.roomOut.gain.setTargetAtTime(level, ctx.currentTime, level < was ? 0.01 : 0.15);
    } catch {
      /* ignore */
    }
  }

  /** Stops everything the elevator keeps playing (a new run). */
  resetLift(): void {
    this.ride(false);
    this.blink(false);
    this.machinery(0, { x: 0, y: 0, z: 0 });
  }

  state(): AudioState {
    return {
      running: this.ctx?.state === 'running',
      gain: this.target,
      nodeGain: this.level ? this.level.gain.value / SQUEAK.level : 0,
      muffled: this.muffled,
      notes: this.notes,
      roomTone: this.room && this.ctx?.state === 'running',
      tickHz: this.tickHz,
      tickLevel: this.tickLevel,
      ticks: this.ticks,
      thunks: this.thunks,
      rasps: this.rasps,
      cadenceHz: this.cadence(),
      ...this.counts,
      machine: this.machineWant,
      riding: this.rideOn,
      room: this.roomWant,
    };
  }
}
