// The player's settings: a few values, saved in this browser (localStorage, every access guarded so a
// private window or blocked storage just means nothing is remembered), and a change event so whoever
// owns a setting applies it at once. Adding a setting: a field in Settings, its default in DEFAULTS,
// a check in clean(), and a row in the settings panel (main.ts).
//
// The address can override a setting for this page: ?voice= (and that one is remembered), ?subs=0,
// ?fx= (the tape look; not remembered, it is a test and development flag; ?fx=0 also hides subtitles).

export type TapeLook = 0 | 1 | 2;

export interface Settings {
  /** The announcer's voice: a voice id from public/assets/voice/manifest.json. */
  voice: string;
  subtitles: boolean;
  /** 0 off (the clean render), 1 normal, 2 heavy: the tape pass's fx levels. */
  tape: TapeLook;
  /** Master volume, 0..1. */
  volume: number;
}

export const DEFAULTS: Settings = { voice: 'bella', subtitles: true, tape: 1, volume: 1 };

const KEY = 'going-down.settings';

function clean(raw: Partial<Record<keyof Settings, unknown>>): Partial<Settings> {
  const out: Partial<Settings> = {};
  if (typeof raw.voice === 'string' && /^[a-z0-9-]{1,32}$/.test(raw.voice)) out.voice = raw.voice;
  if (typeof raw.subtitles === 'boolean') out.subtitles = raw.subtitles;
  if (raw.tape === 0 || raw.tape === 1 || raw.tape === 2) out.tape = raw.tape;
  if (typeof raw.volume === 'number' && Number.isFinite(raw.volume)) out.volume = Math.max(0, Math.min(1, raw.volume));
  return out;
}

export class SettingsStore {
  private values: Settings;
  /** Values that hold for this page only (from the address), on top of the saved ones. */
  private session: Partial<Settings> = {};
  private readonly listeners: ((key: keyof Settings, s: Readonly<Settings>) => void)[] = [];

  constructor(params?: URLSearchParams) {
    let saved: Partial<Settings> = {};
    try {
      const text = window.localStorage.getItem(KEY);
      if (text) saved = clean(JSON.parse(text) as Partial<Record<keyof Settings, unknown>>);
    } catch {
      /* no storage, or nonsense in it: the defaults */
    }
    this.values = { ...DEFAULTS, ...saved };
    if (params) {
      const voice = params.get('voice');
      if (voice) {
        const v = clean({ voice: voice.toLowerCase() }).voice;
        if (v) {
          this.values.voice = v;
          this.save();
        }
      }
      if (params.get('subs') === '0') this.session.subtitles = false;
      const fx = params.get('fx');
      if (fx !== null) {
        const n = Number(fx);
        this.session.tape = n >= 2 ? 2 : n === 0 ? 0 : 1;
        // The clean render from the address shows no on-screen display at all, subtitles included
        // (the reference pictures use it). Choosing "tape look off" in the panel does not do this.
        if (this.session.tape === 0) this.session.subtitles = false;
      }
    }
  }

  /** The values in force now. */
  get all(): Readonly<Settings> {
    return { ...this.values, ...this.session };
  }

  get<K extends keyof Settings>(key: K): Settings[K] {
    return this.all[key];
  }

  /** Sets a value, saves it, and tells the listeners. A change made here replaces an address override. */
  set<K extends keyof Settings>(key: K, value: Settings[K]): void {
    const v = clean({ [key]: value } as Partial<Record<keyof Settings, unknown>>)[key];
    if (v === undefined) return;
    this.values = { ...this.values, [key]: v };
    delete this.session[key];
    this.save();
    const now = this.all;
    for (const fn of this.listeners) {
      try {
        fn(key, now);
      } catch {
        /* one listener must not stop the others */
      }
    }
  }

  onChange(fn: (key: keyof Settings, s: Readonly<Settings>) => void): void {
    this.listeners.push(fn);
  }

  private save(): void {
    try {
      window.localStorage.setItem(KEY, JSON.stringify(this.values));
    } catch {
      /* not remembered; still applied */
    }
  }
}
