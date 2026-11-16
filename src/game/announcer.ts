// The elevator's voice: a relentlessly cheerful corporate announcer (docs/VOICE.md). The lines are
// recorded ahead of time (assets_src/voice/) in more than one voice and shipped as
// public/assets/voice/<voice>/<id>.mp3, with a manifest of voices, ids, moments and subtitles. The voice
// is a setting and can change at any time: the next line simply comes from the other folder, and the
// old voice's decoded audio is dropped the next time a line is fetched. Everything here is lazy and forgiving: the manifest and each
// line are fetched the first time they are needed, a missing file is noted and skipped, and no call
// ever throws into the game.
//
//   - One line at a time. A new line waits its turn (first come, first served) unless it outranks the
//     one playing by two priority steps or more, which cuts the old line off (a wipe over a call).
//     Waiting lines expire, so a stale "your car has arrived" is never heard ten seconds late.
//   - The speaker. The clean recording goes through an elevator-speaker chain built here: band-limited,
//     a nasal honk, soft distortion, a short metallic echo, crackle and dropouts. Depth makes the
//     speaker worse (narrower band, more drive, crackle and dropouts); the performance never changes.
//     Inside the car it is close and loud; out on the floor it comes from the speaker above the
//     landing doors, panned to its direction and dulled a little with distance, but never much
//     quieter (at least VOICE.farMin of its near level): the recordings are all at -16 LUFS and a
//     line should sound about as loud wherever you are. A compressor on each line's bus evens out
//     the rest. The moments that matter to everyone (taken, wipe, banked, blackout, lights) are
//     always heard at the in-car level, wherever the listener is.
//   - Variety: each moment's lines are dealt from a shuffled deck, so a moment never repeats its
//     last line and goes through all of its lines before any comes round again.
//   - The slip: at most once per run, from floor 2 on, at a quiet moment (no blink coming or on, the
//     instrument not recording, nothing else playing), delivered quietly; then a pause; then the
//     cheerful resume line as if nothing happened.
//   - Subtitles: the line's words in the camcorder's pixel font at the bottom of the picture while it
//     plays. On by default; ?subs=0 turns them off (main.ts also leaves them off in the clean ?fx=0 render).
//
// NOTE: the speaker chain was designed from first principles and checked by numbers (node settings,
// timings), not by ear. Nobody has listened to it.

import { GLYPHS } from '../render/pixelFont';

interface Vec3 {
  x: number;
  y: number;
  z: number;
}

/** What the announcer needs to know about this frame. */
export interface AnnouncerFrame {
  depth: number;
  /** The listener is inside the car (close speaker) or out on the floor (the landing speaker, far). */
  inCar: boolean;
  ear: Vec3;
  /** The camera's forward direction (the up direction is taken as world up). */
  forward: Vec3;
  /** The speaker above the landing doors. */
  speaker: Vec3;
  /** Nothing tense is happening: no blink warning or dark, not recording, not caught. */
  quiet: boolean;
}

/** The run events the announcer listens to (a loose shape: it ignores fields it does not use). */
export interface AnnouncerEvent {
  type: string;
  reason?: string;
  depth?: number;
  outcome?: string;
  playerId?: string | null;
  blackout?: boolean;
}

interface LineInfo {
  id: string;
  moment: string;
  plain: string;
}

interface Manifest {
  voices?: { id: string; name: string }[];
  default?: string;
  moments: Record<string, { priority: number }>;
  lines: LineInfo[];
}

interface Item {
  id: string;
  moment: string;
  priority: number;
  queuedAt: number;
  expires: number;
}

interface Playing {
  item: Item;
  plain: string;
  src: AudioBufferSourceNode;
  nodes: AudioNode[];
  close: GainNode;
  far: GainNode;
  farLp: BiquadFilterNode;
  pan: StereoPannerNode;
  /** The gain the line is heard at now (the close or the far path) and the far path's low-pass (0 when close). */
  level: number;
  lowpass: number;
  startedAt: number;
  endsAt: number;
  done: boolean;
}

export interface AnnouncerState {
  /** The manifest has loaded. */
  ready: boolean;
  /** The line playing now (or being fetched to play), else null. */
  playing: string | null;
  loading: string | null;
  /** Waiting lines, in the order they will play. */
  queue: string[];
  /** Lines started this run, oldest first. */
  played: string[];
  slipPlayed: boolean;
  /** When the slip is due (performance.now ms), once floor 2 is reached; null before or after. */
  slipAt: number | null;
  /** Every line started (this page), with real start and end times in ms; end is null while playing. */
  history: { id: string; moment: string; voice: string; file: string; start: number; end: number | null; depth: number; mode: 'car' | 'landing'; level: number; lowpass: number }[];
  /** The line playing now: the gain it is heard at and the far path's low-pass (Hz, 0 when heard close); null when none. */
  level: { gain: number; lowpass: number } | null;
  /** The in-car level, for comparison. */
  closeLevel: number;
  /** The voice asked for (setting) and the one in use (the manifest's default if that one is not shipped). */
  voice: string;
  voiceInUse: string;
  /** Audio files decoded and kept, as <voice>/<id>. */
  cached: string[];
  /** Ids asked for that have no file (or are unknown). */
  missing: string[];
  /** The subtitle on screen now ('' when none) and whether subtitles are on. */
  subtitle: string;
  subsOn: boolean;
  /** The speaker chain used for the line started last. */
  speaker: { depth: number; highpass: number; lowpass: number; drive: number; crackle: number; dropout: number } | null;
  mode: 'car' | 'landing';
}

// ------------------------------------------------------------------------------------------------
// Tuning.

const VOICE = {
  /** Level of a line in the car (the recordings are at -16 LUFS; the call chime peaks near 0.42). */
  closeLevel: 0.6,
  /**
   * Level of a line from the landing speaker at `farRef` metres; it falls off as ref / (ref + d), but
   * never below `farMin` of this (behind your head included), so distance dulls a line a little and
   * never loses it: a line heard far from the lift is still about as loud as one heard in the car.
   */
  farLevel: 0.75,
  farRef: 3,
  farMin: 0.55,
  /** The landing speaker's dulling with distance: low-pass Hz at the speaker and the floor it falls to. */
  farLpNear: 3200,
  farLpMin: 1400,
  farLpPerMetre: 90,
  /** How far the landing speaker pans at most (-1..1). */
  panWidth: 0.8,
  /** The slip is quiet. */
  slipLevel: 0.45,
  /** Pause after the slip before the resume line, ms (the docs' [long pause] is about 2.5 s). */
  slipPauseMs: 2300,
  /** The slip comes this long after floor 2 is first reached, ms (random in between), once quiet. */
  slipMinMs: 25_000,
  slipMaxMs: 70_000,
  /** A breath between lines, ms. */
  gapMs: 350,
  /** How long a waiting line stays worth saying, ms. */
  expireMs: 8000,
  expireLongMs: 15_000,
  /** The boarding line waits for the first click or tap that starts the sound. */
  expireBoardMs: 30_000,
  /** At most this many lines wait. */
  queueMax: 3,
};

/** Moments everyone must hear the same, wherever they are: always at the in-car level. */
const ALWAYS_CLOSE = new Set(['taken', 'wipe', 'banked', 'blackout', 'lights']);

/** The voice bus's compressor: evens loud and quiet lines (and loud and quiet words) out. */
const COMPRESS = { threshold: -22, knee: 10, ratio: 3, attack: 0.004, release: 0.2, makeup: 1.45 };

/** The speaker at depth 1 (`k` 0) and at its worst (`k` 1, depth 1 + SPEAKER.worstAfter). */
const SPEAKER = {
  worstAfter: 6,
  highpass: [330, 700] as const,
  lowpass: [3800, 2100] as const,
  honkHz: 1700,
  honkDb: [5, 8] as const,
  /** Soft-clip drive. */
  drive: [1.8, 6] as const,
  /** The metallic echo: delay s, feedback, wet level, through a band-pass at this centre. */
  echoS: 0.043,
  echoFeedback: [0.25, 0.36] as const,
  echoWet: [0.2, 0.32] as const,
  echoHz: 2100,
  /** Crackle: pops per second and their level. */
  crackleHz: [1.5, 14] as const,
  crackleLevel: [0.012, 0.06] as const,
  /** Dropouts: chance per 120 ms slice that the line cuts to `dropGain`, from k 0.2 on. */
  dropout: [0, 0.16] as const,
  dropGain: 0.06,
};

const lerp = (r: readonly [number, number], k: number): number => r[0] + (r[1] - r[0]) * k;
const clamp = (v: number, a: number, b: number): number => Math.max(a, Math.min(b, v));

// ------------------------------------------------------------------------------------------------
// Subtitles in the pixel font (with the few marks speech needs that the OSD font lacks).

const EXTRA: Record<string, string[]> = {
  ',': ['00000', '00000', '00000', '00000', '01100', '00100', '01000'],
  '!': ['00100', '00100', '00100', '00100', '00100', '00000', '00100'],
  '?': ['01110', '10001', '00001', '00010', '00100', '00000', '00100'],
};

function glyph(ch: string): string[] | undefined {
  return EXTRA[ch] ?? GLYPHS[ch];
}

function drawLine(g: CanvasRenderingContext2D, text: string, x: number, y: number): void {
  for (let i = 0; i < text.length; i++) {
    const rows = glyph(text[i] ?? ' ');
    if (!rows) continue;
    for (let r = 0; r < 7; r++) {
      const row = rows[r] ?? '';
      for (let c = 0; c < 5; c++) if (row[c] === '1') g.fillRect(x + i * 6 + c, y + r, 1, 1);
    }
  }
}

/** Upper case (the font's lower case is incomplete), unknown characters dropped, wrapped to `width`. */
export function subtitleRows(plain: string, width = 38): string[] {
  const text = plain.toUpperCase().replace(/[’‘]/g, "'").replace(/…/g, '...');
  const clean = [...text].filter((ch) => ch === ' ' || glyph(ch)).join('');
  const rows: string[] = [];
  let row = '';
  for (const word of clean.split(/\s+/).filter(Boolean)) {
    if (row && row.length + 1 + word.length > width) {
      rows.push(row);
      row = word;
    } else row = row ? `${row} ${word}` : word;
  }
  if (row) rows.push(row);
  return rows;
}

class Subtitles {
  readonly el: HTMLDivElement;
  private readonly canvas: HTMLCanvasElement;
  text = '';

  constructor(parent: HTMLElement) {
    this.el = document.createElement('div');
    this.el.id = 'subs';
    this.el.hidden = true;
    this.el.style.cssText = 'position:fixed;left:0;right:0;bottom:9%;display:flex;justify-content:center;pointer-events:none;z-index:7;';
    this.canvas = document.createElement('canvas');
    this.canvas.style.cssText = 'display:block;image-rendering:pixelated;';
    this.el.append(this.canvas);
    parent.append(this.el);
    window.addEventListener('resize', () => this.draw());
  }

  show(plain: string): void {
    this.text = plain;
    this.el.hidden = false;
    this.draw();
  }

  hide(): void {
    this.text = '';
    this.el.hidden = true;
  }

  private draw(): void {
    if (this.el.hidden) return;
    const rows = subtitleRows(this.text);
    const w = Math.max(10, ...rows.map((r) => r.length * 6 - 1)) + 6;
    const h = rows.length * 10 + 4;
    const c = this.canvas;
    c.width = w;
    c.height = h;
    const scale = clamp(Math.floor((window.innerWidth * 0.92) / w), 1, 4);
    c.style.width = `${w * scale}px`;
    c.style.height = `${h * scale}px`;
    const g = c.getContext('2d');
    if (!g) return;
    g.clearRect(0, 0, w, h);
    g.fillStyle = 'rgba(0,0,0,0.45)';
    g.fillRect(0, 0, w, h);
    rows.forEach((r, i) => {
      const x = Math.floor((w - (r.length * 6 - 1)) / 2);
      const y = 2 + i * 10;
      g.fillStyle = 'rgba(0,0,0,0.7)';
      drawLine(g, r, x + 1, y + 1);
      g.fillStyle = '#f4f4ec';
      drawLine(g, r, x, y);
    });
  }
}

// ------------------------------------------------------------------------------------------------

export class Announcer {
  private manifest: Manifest | null = null;
  private manifestLoad: Promise<void> | null = null;
  private readonly buffers = new Map<string, Promise<AudioBuffer | null>>();
  private readonly decoded = new Map<string, AudioBuffer>();
  private queue: Item[] = [];
  /** Requests made before the manifest arrived: moments (or ids) with when they were made. */
  private early: { moment?: string; id?: string; at: number }[] = [];
  private current: Playing | null = null;
  private loading: Item | null = null;
  private gapUntil = 0;
  private played: string[] = [];
  private lastOf = new Map<string, string>();
  /** Per moment, the lines still to be dealt before the deck is shuffled again. */
  private decks = new Map<string, string[]>();
  /** Whether the wait now under way has had its blackout (the lights coming back replace the arrival line). */
  private blackoutOn = false;
  private slipDone = false;
  private slipAt: number | null = null;
  private resumeAfterSlip = false;
  private readonly history: AnnouncerState['history'] = [];
  private readonly missing = new Set<string>();
  private frame: AnnouncerFrame = { depth: 1, inCar: true, ear: { x: 0, y: 0, z: 0 }, forward: { x: 0, y: 0, z: -1 }, speaker: { x: 0, y: 0, z: 0 }, quiet: true };
  private subs: Subtitles | null = null;
  private voice = 'bella';
  private cacheVoice = '';
  private noise: AudioBuffer | null = null;
  private speakerInfo: AnnouncerState['speaker'] = null;

  constructor(
    private readonly context: () => AudioContext | null,
    /** Where lines go (the game's master volume), or null for the context's own output. */
    private readonly output: () => AudioNode | null,
    private readonly base: string,
    private readonly parent: HTMLElement,
    subsOn: boolean,
    voice = 'bella',
  ) {
    this.voice = voice;
    this.setSubtitles(subsOn);
  }

  // ---- settings ------------------------------------------------------------------------------

  /** The voice for the next line (a line already playing finishes in its own voice). */
  setVoice(voice: string): void {
    this.voice = voice;
  }

  /** The voices shipped (from the manifest; Bella and Brian until it has loaded). */
  voices(): { id: string; name: string }[] {
    return this.manifest?.voices ?? [
      { id: 'bella', name: 'Bella' },
      { id: 'brian', name: 'Brian' },
    ];
  }

  setSubtitles(on: boolean): void {
    if (on && !this.subs) this.subs = new Subtitles(this.parent);
    if (!on && this.subs) {
      this.subs.el.remove();
      this.subs = null;
    }
    if (on && this.subs && this.current && !this.current.done) this.subs.show(this.current.plain);
  }

  /** A short line now, through the speaker, cutting off whatever is playing (the settings' sample). */
  sample(): boolean {
    let ok = false;
    this.safe(() => {
      this.loadManifest();
      const m = this.manifest;
      if (!m) return;
      const pick = [...m.lines].filter((l) => l.moment !== 'slip' && l.moment !== 'resume').sort((a, b) => a.plain.length - b.plain.length)[0];
      if (!pick) return;
      this.stopCurrent();
      this.loading = null;
      this.gapUntil = 0;
      const now = performance.now();
      this.queue = this.queue.filter((q) => q.id !== pick.id);
      this.queue.unshift({ id: pick.id, moment: pick.moment, priority: 9, queuedAt: now, expires: now + VOICE.expireMs });
      ok = true;
    });
    return ok;
  }

  /** The voice lines are taken from now: the setting, if the manifest ships it. */
  private voiceInUse(): string {
    const vs = this.manifest?.voices;
    if (!vs || vs.some((v) => v.id === this.voice)) return this.voice;
    return this.manifest?.default ?? vs[0]?.id ?? this.voice;
  }

  // ---- what happens in the run ---------------------------------------------------------------

  /** A new run (also the first): the per-run record starts over and the boarding line is said. */
  startRun(): void {
    this.safe(() => {
      this.stopCurrent();
      this.queue = [];
      this.early = [];
      this.loading = null;
      this.played = [];
      this.blackoutOn = false;
      this.slipDone = false;
      this.slipAt = null;
      this.resumeAfterSlip = false;
      this.gapUntil = 0;
      this.request('board', VOICE.expireBoardMs);
    });
  }

  /** The run's events after a frame's ticks (run, Orderly and crew events alike). */
  onEvents(events: readonly AnnouncerEvent[], firstDepth: number): void {
    this.safe(() => {
      const wiped = events.some((e) => e.type === 'wiped');
      for (const e of events) {
        switch (e.type) {
          case 'doorsOpened':
            // The boarding line covers the run's first floor.
            if (e.reason === 'arrival' && (e.depth ?? 1) > firstDepth) this.request('doors');
            break;
          case 'carLeft':
            if (e.reason === 'unloaded' || e.reason === 'empty') this.request('left');
            else if (e.reason === 'ride') this.request('ride');
            break;
          case 'called':
            this.request('called', VOICE.expireLongMs); // the answer to a button press: worth saying even behind two long lines
            break;
          case 'blinkStart':
            if (e.blackout === true) {
              this.blackoutOn = true;
              this.request('blackout');
            }
            break;
          case 'carArrived':
            // A wait that ended in the blackout gets the lights line as they come back, in place of the
            // arrival line; a blackout line still waiting to be said is stale by then.
            if (this.blackoutOn) {
              this.queue = this.queue.filter((q) => q.moment !== 'blackout');
              this.request('lights', VOICE.expireLongMs);
            } else this.request('arrived');
            this.blackoutOn = false;
            break;
          case 'banked':
            this.request('banked', VOICE.expireLongMs);
            break;
          case 'wiped':
            this.request('wipe', VOICE.expireLongMs);
            break;
          case 'caught':
            if (!wiped) this.request('taken');
            break;
          default:
            break;
        }
      }
    });
  }

  /** The doors will close soon (the bell's line plays ahead of the bell itself). */
  bellSoon(): void {
    this.safe(() => this.request('bell', 7000));
  }

  /** Test hook: deals the next line of a moment as a request would (null before the manifest or with none). */
  dealNext(moment: string): string | null {
    let id: string | null = null;
    this.safe(() => {
      id = this.deal(moment);
      if (id) this.lastOf.set(moment, id);
    });
    return id;
  }

  /** Test hook: says a line by id (the slip only from floor 2 and once a run). False if it cannot. */
  say(id: string): boolean {
    let ok = false;
    this.safe(() => {
      if (!this.manifest) {
        this.early.push({ id, at: performance.now() });
        this.loadManifest();
        ok = true;
        return;
      }
      ok = this.requestId(id, VOICE.expireLongMs);
    });
    return ok;
  }

  // ---- per frame -----------------------------------------------------------------------------

  update(frame: AnnouncerFrame): void {
    this.frame = frame;
    this.safe(() => {
      const now = performance.now();
      const ctx = this.context();
      if (ctx && !this.manifest) this.loadManifest();
      this.place(false);
      if (this.current && !this.current.done && now > this.current.endsAt + 600) this.finish(this.current);
      this.queue = this.queue.filter((q) => q.expires > now);
      // The slip: due a while after floor 2, said only when everything is quiet.
      if (!this.slipDone && frame.depth >= 2 && this.slipAt === null && this.manifest?.lines.some((l) => l.moment === 'slip')) {
        this.slipAt = now + VOICE.slipMinMs + Math.random() * (VOICE.slipMaxMs - VOICE.slipMinMs);
      }
      const running = ctx?.state === 'running';
      const idle = !this.current && !this.loading && now >= this.gapUntil;
      if (!running || !idle) return;
      if (this.slipAt !== null && !this.slipDone && now >= this.slipAt && frame.quiet && this.queue.length === 0) {
        this.requestMoment('slip', VOICE.expireMs);
      }
      const next = this.queue.shift();
      if (next) this.begin(next);
    });
  }

  // ---- requests ------------------------------------------------------------------------------

  private request(moment: string, expireMs = VOICE.expireMs): void {
    if (!this.manifest) {
      this.early.push({ moment, at: performance.now() });
      this.loadManifest();
      return;
    }
    this.requestMoment(moment, expireMs);
  }

  /** The next of the moment's lines from its deck. */
  private requestMoment(moment: string, expireMs: number): void {
    const pick = this.deal(moment);
    if (pick) this.requestId(pick, expireMs);
  }

  /**
   * Deals the next line of a moment: every line once, in a shuffled order, before any comes round
   * again; a new deck never starts with the line said last. Lines with no file are left out.
   */
  private deal(moment: string): string | null {
    const m = this.manifest;
    if (!m) return null;
    const options = m.lines.filter((l) => l.moment === moment && !this.missing.has(this.fileOf(l.id))).map((l) => l.id);
    if (options.length === 0) return null;
    let deck = (this.decks.get(moment) ?? []).filter((id) => options.includes(id));
    if (deck.length === 0) {
      deck = [...options];
      for (let i = deck.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [deck[i], deck[j]] = [deck[j] as string, deck[i] as string];
      }
      const last = this.lastOf.get(moment);
      if (deck.length > 1 && deck[0] === last) deck.push(deck.shift() as string);
    }
    const pick = deck.shift() ?? null;
    this.decks.set(moment, deck);
    return pick;
  }

  private requestId(id: string, expireMs: number): boolean {
    const m = this.manifest;
    const line = m?.lines.find((l) => l.id === id);
    if (!m || !line) {
      this.missing.add(id);
      return false;
    }
    if (line.moment === 'slip' && (this.slipDone || this.frame.depth < 2)) return false;
    const now = performance.now();
    const item: Item = { id, moment: line.moment, priority: m.moments[line.moment]?.priority ?? 1, queuedAt: now, expires: now + expireMs };
    if (line.moment === 'slip') this.slipDone = true;
    // Not twice in the queue for one moment: the newer request replaces the older.
    this.queue = this.queue.filter((q) => q.moment !== item.moment);
    const cur = this.current && !this.current.done ? this.current.item : this.loading;
    if (cur && item.priority >= cur.priority + 2) {
      // Cuts in: the line playing stops, and this goes first.
      this.stopCurrent();
      this.loading = null;
      this.gapUntil = now + 80;
      this.queue.unshift(item);
    } else {
      // In order, except that a line two steps more urgent goes ahead of those it outranks.
      const at = this.queue.findIndex((q) => item.priority >= q.priority + 2);
      if (at < 0) this.queue.push(item);
      else this.queue.splice(at, 0, item);
    }
    while (this.queue.length > VOICE.queueMax) {
      // Drop the least urgent (the last of the lowest priority).
      let worst = 0;
      this.queue.forEach((q, i) => {
        if (q.priority <= (this.queue[worst]?.priority ?? 0)) worst = i;
      });
      this.queue.splice(worst, 1);
    }
    return true;
  }

  // ---- loading -------------------------------------------------------------------------------

  private loadManifest(): void {
    if (this.manifestLoad) return;
    this.manifestLoad = fetch(`${this.base}assets/voice/manifest.json`)
      .then((r) => (r.ok ? (r.json() as Promise<Manifest>) : null))
      .then((m) => {
        if (!m || !Array.isArray(m.lines)) return;
        this.manifest = m;
        const early = this.early;
        this.early = [];
        for (const e of early) {
          const age = performance.now() - e.at;
          if (e.id) this.requestId(e.id, VOICE.expireLongMs - age);
          else if (e.moment) this.requestMoment(e.moment, (e.moment === 'board' ? VOICE.expireBoardMs : VOICE.expireMs) - age);
        }
      })
      .catch(() => undefined);
  }

  private fileOf(id: string): string {
    return `${this.voiceInUse()}/${id}`;
  }

  private buffer(id: string): Promise<AudioBuffer | null> {
    const voice = this.voiceInUse();
    if (voice !== this.cacheVoice) {
      // The voice changed: let the old one's audio go (lazily, now that a line is wanted).
      this.buffers.clear();
      this.decoded.clear();
      this.cacheVoice = voice;
    }
    const key = `${voice}/${id}`;
    let p = this.buffers.get(key);
    if (!p) {
      const ctx = this.context();
      p = fetch(`${this.base}assets/voice/${key}.mp3`)
        .then((r) => (r.ok ? r.arrayBuffer() : null))
        .then((bytes) => (bytes && ctx ? ctx.decodeAudioData(bytes) : null))
        .then((b) => {
          if (b) {
            if (this.cacheVoice === voice) this.decoded.set(key, b);
          } else this.missing.add(key);
          return b;
        })
        .catch(() => {
          this.missing.add(key);
          return null;
        });
      this.buffers.set(key, p);
    }
    return p;
  }

  // ---- playing -------------------------------------------------------------------------------

  private begin(item: Item): void {
    const ready = this.cacheVoice === this.voiceInUse() ? this.decoded.get(`${this.cacheVoice}/${item.id}`) : undefined;
    if (ready) {
      this.play(item, ready);
      return;
    }
    this.loading = item;
    void this.buffer(item.id).then((b) => {
      if (this.loading !== item) return;
      this.loading = null;
      if (b) this.safe(() => this.play(item, b));
    });
  }

  private play(item: Item, buf: AudioBuffer): void {
    const ctx = this.context();
    if (!ctx) return;
    const t = ctx.currentTime + 0.02;
    const k = clamp((this.frame.depth - 1) / SPEAKER.worstAfter, 0, 1);
    const nodes: AudioNode[] = [];
    const add = <T extends AudioNode>(n: T): T => {
      nodes.push(n);
      return n;
    };

    const src = add(ctx.createBufferSource());
    src.buffer = buf;
    // The speaker: band-limit, honk, soft clip.
    const hp = add(ctx.createBiquadFilter());
    hp.type = 'highpass';
    hp.frequency.value = lerp(SPEAKER.highpass, k);
    hp.Q.value = 0.8;
    const lp = add(ctx.createBiquadFilter());
    lp.type = 'lowpass';
    lp.frequency.value = lerp(SPEAKER.lowpass, k);
    lp.Q.value = 0.9;
    const honk = add(ctx.createBiquadFilter());
    honk.type = 'peaking';
    honk.frequency.value = SPEAKER.honkHz;
    honk.Q.value = 1.2;
    honk.gain.value = lerp(SPEAKER.honkDb, k);
    const drive = lerp(SPEAKER.drive, k);
    const shaper = add(ctx.createWaveShaper());
    const curve = new Float32Array(1024);
    for (let i = 0; i < curve.length; i++) {
      const x = (i / (curve.length - 1)) * 2 - 1;
      curve[i] = Math.tanh(drive * x) / Math.tanh(drive);
    }
    shaper.curve = curve;
    shaper.oversample = '2x';
    // Dropouts: the line's level cut for a moment, here and there, more often deeper.
    const gate = add(ctx.createGain());
    const dur = buf.duration;
    const pDrop = Math.max(0, (k - 0.2) / 0.8) * SPEAKER.dropout[1];
    for (let s = 0.3; s < dur - 0.2; s += 0.12) {
      if (Math.random() < pDrop) {
        const len = 0.04 + Math.random() * 0.07;
        gate.gain.setValueAtTime(SPEAKER.dropGain, t + s);
        gate.gain.setValueAtTime(1, t + s + len);
      }
    }
    // The bus after the speaker: dry plus the metallic echo.
    const bus = add(ctx.createGain());
    const level = item.moment === 'slip' ? VOICE.slipLevel : 1;
    bus.gain.value = level;
    src.connect(hp).connect(lp).connect(honk).connect(shaper).connect(gate).connect(bus);
    const delay = add(ctx.createDelay(0.5));
    delay.delayTime.value = SPEAKER.echoS;
    const fb = add(ctx.createGain());
    fb.gain.value = lerp(SPEAKER.echoFeedback, k);
    const ring = add(ctx.createBiquadFilter());
    ring.type = 'bandpass';
    ring.frequency.value = SPEAKER.echoHz;
    ring.Q.value = 2.5;
    const wet = add(ctx.createGain());
    wet.gain.value = lerp(SPEAKER.echoWet, k);
    gate.connect(delay).connect(ring).connect(fb).connect(delay);
    ring.connect(wet).connect(bus);
    // Crackle: short pops of noise, more of them deeper.
    if (!this.noise) {
      const n = Math.floor(ctx.sampleRate * 1.5);
      this.noise = ctx.createBuffer(1, n, ctx.sampleRate);
      const d = this.noise.getChannelData(0);
      for (let i = 0; i < n; i++) d[i] = Math.random() * 2 - 1;
    }
    const crack = add(ctx.createBufferSource());
    crack.buffer = this.noise;
    crack.loop = true;
    const crackHp = add(ctx.createBiquadFilter());
    crackHp.type = 'highpass';
    crackHp.frequency.value = 2500;
    const crackGate = add(ctx.createGain());
    crackGate.gain.value = 0;
    const pops = Math.round(lerp(SPEAKER.crackleHz, k) * dur);
    const popLevel = lerp(SPEAKER.crackleLevel, k) * level;
    for (let i = 0; i < pops; i++) {
      const at = t + Math.random() * dur;
      crackGate.gain.setValueAtTime(popLevel * (0.4 + Math.random() * 0.6), at);
      crackGate.gain.setValueAtTime(0, at + 0.004 + Math.random() * 0.012);
    }
    crack.connect(crackHp).connect(crackGate).connect(bus);
    // Out: close (in the car) or from the landing speaker (panned, dulled, quieter with distance).
    // The voice bus's compressor (and its make-up gain), before the line is placed.
    const comp = add(ctx.createDynamicsCompressor());
    comp.threshold.value = COMPRESS.threshold;
    comp.knee.value = COMPRESS.knee;
    comp.ratio.value = COMPRESS.ratio;
    comp.attack.value = COMPRESS.attack;
    comp.release.value = COMPRESS.release;
    const makeup = add(ctx.createGain());
    makeup.gain.value = COMPRESS.makeup;
    bus.connect(comp).connect(makeup);
    const close = add(ctx.createGain());
    const far = add(ctx.createGain());
    const farLp = add(ctx.createBiquadFilter());
    farLp.type = 'lowpass';
    const pan = add(ctx.createStereoPanner());
    const out = this.output() ?? ctx.destination;
    makeup.connect(close).connect(out);
    makeup.connect(farLp).connect(far).connect(pan).connect(out);

    const now = performance.now();
    const p: Playing = { item, plain: this.lineOf(item.id)?.plain ?? '', src, nodes, close, far, farLp, pan, level: 0, lowpass: 0, startedAt: now, endsAt: now + dur * 1000 + 40, done: false };
    this.current = p;
    this.place(true);
    src.onended = () => this.safe(() => this.finish(p));
    src.start(t);
    crack.start(t);
    crack.stop(t + dur + 0.05);
    this.speakerInfo = { depth: this.frame.depth, highpass: hp.frequency.value, lowpass: lp.frequency.value, drive, crackle: popLevel, dropout: pDrop };
    this.played.push(item.id);
    this.lastOf.set(item.moment, item.id);
    const file = this.fileOf(item.id);
    this.history.push({ id: item.id, moment: item.moment, voice: file.split('/')[0] ?? '', file: `assets/voice/${file}.mp3`, start: now, end: null, depth: this.frame.depth, mode: this.frame.inCar ? 'car' : 'landing', level: p.level, lowpass: p.lowpass });
    if (this.history.length > 80) this.history.shift();
    this.subs?.show(p.plain);
  }

  /** Sets where the line playing now is heard from. */
  private place(snap: boolean): void {
    const p = this.current;
    const ctx = this.context();
    if (!p || p.done || !ctx) return;
    const f = this.frame;
    const t = ctx.currentTime;
    const set = (param: AudioParam, v: number): void => {
      if (snap) param.setValueAtTime(v, t);
      else param.setTargetAtTime(v, t, 0.08);
    };
    if (f.inCar || ALWAYS_CLOSE.has(p.item.moment)) {
      set(p.close.gain, VOICE.closeLevel);
      set(p.far.gain, 0);
      p.level = VOICE.closeLevel;
      p.lowpass = 0;
      return;
    }
    const dx = f.speaker.x - f.ear.x;
    const dy = f.speaker.y - f.ear.y;
    const dz = f.speaker.z - f.ear.z;
    const d = Math.hypot(dx, dy, dz);
    // Right of the camera = forward x up(0,1,0).
    const rx = -f.forward.z;
    const rz = f.forward.x;
    const rl = Math.hypot(rx, rz) || 1;
    const side = d > 0.01 ? (dx * rx + dz * rz) / (rl * d) : 0;
    const ahead = d > 0.01 ? (dx * f.forward.x + dz * f.forward.z) / d : 1;
    const g = clamp((VOICE.farRef / (VOICE.farRef + d)) * (ahead < 0 ? 0.8 : 1), VOICE.farMin, 1) * VOICE.farLevel;
    const lp = Math.max(VOICE.farLpMin, (VOICE.farLpNear - d * VOICE.farLpPerMetre) * (ahead < 0 ? 0.75 : 1));
    set(p.close.gain, 0);
    set(p.far.gain, g);
    set(p.pan.pan, clamp(side * VOICE.panWidth, -1, 1));
    set(p.farLp.frequency, lp);
    p.level = g;
    p.lowpass = lp;
  }

  private finish(p: Playing): void {
    if (p.done) return;
    p.done = true;
    const now = performance.now();
    const h = [...this.history].reverse().find((x) => x.id === p.item.id && x.end === null);
    if (h) h.end = now;
    if (this.current === p) {
      this.current = null;
      this.subs?.hide();
      this.gapUntil = now + VOICE.gapMs;
      if (p.item.moment === 'slip') {
        // The pause, then the cheerful line as if nothing happened.
        this.gapUntil = now + VOICE.slipPauseMs;
        this.resumeAfterSlip = true;
      }
    }
    // Let the echo ring out, then let go of the nodes.
    setTimeout(() => {
      for (const n of p.nodes) {
        try {
          n.disconnect();
        } catch {
          /* already gone */
        }
      }
    }, 800);
    if (this.resumeAfterSlip) {
      this.resumeAfterSlip = false;
      this.queue = this.queue.filter((q) => q.moment !== 'resume');
      const m = this.manifest;
      const pick = this.deal('resume');
      if (pick && m) {
        const at = performance.now();
        this.queue.unshift({ id: pick, moment: 'resume', priority: m.moments['resume']?.priority ?? 1, queuedAt: at, expires: at + VOICE.slipPauseMs + VOICE.expireMs });
      }
    }
  }

  private stopCurrent(): void {
    const p = this.current;
    if (!p) return;
    const ctx = this.context();
    try {
      if (ctx) {
        const t = ctx.currentTime;
        p.close.gain.setTargetAtTime(0, t, 0.015);
        p.far.gain.setTargetAtTime(0, t, 0.015);
        p.src.stop(t + 0.07);
      }
    } catch {
      /* not started or already stopped */
    }
    // A cut-off slip still counts as said, but is not followed by the resume line.
    this.finish(p);
    this.resumeAfterSlip = false;
    this.queue = this.queue.filter((q) => q.moment !== 'resume' || p.item.moment !== 'slip');
  }

  private lineOf(id: string): LineInfo | undefined {
    return this.manifest?.lines.find((l) => l.id === id);
  }

  private safe(fn: () => void): void {
    try {
      fn();
    } catch {
      /* the announcer must never break the game */
    }
  }

  state(): AnnouncerState {
    return {
      ready: this.manifest !== null,
      playing: this.current && !this.current.done ? this.current.item.id : null,
      loading: this.loading?.id ?? null,
      queue: this.queue.map((q) => q.id),
      played: this.played.slice(),
      slipPlayed: this.played.some((id) => this.lineOf(id)?.moment === 'slip'),
      slipAt: this.slipDone ? null : this.slipAt,
      history: this.history.map((h) => ({ ...h })),
      missing: [...this.missing],
      subtitle: this.subs?.text ?? '',
      subsOn: this.subs !== null,
      speaker: this.speakerInfo,
      mode: this.frame.inCar ? 'car' : 'landing',
      level: this.current && !this.current.done ? { gain: this.current.level, lowpass: this.current.lowpass } : null,
      closeLevel: VOICE.closeLevel,
      voice: this.voice,
      voiceInUse: this.voiceInUse(),
      cached: [...this.decoded.keys()],
    };
  }
}
