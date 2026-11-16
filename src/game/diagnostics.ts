// What to do when a device cannot keep the picture going, and how to find out why.
//
// On a phone the graphics context can be thrown away by the browser (too much memory, a driver
// fault). The canvas then goes blank while the page carries on. This module:
//  - tries to carry on when the context comes back, and tells the player what is happening;
//  - if it is lost twice, or does not come back, switches to a lighter way of drawing and reloads
//    (at most twice per visit, so it can never loop);
//  - reports what the device is and what happened to the hub this build is served from, when there
//    is one, so the cause can be read afterwards. Nothing personal is sent: the graphics chip's name,
//    limits, the browser's user-agent string and what the game was doing.
import type * as THREE from 'three';

/** 0: everything on. 1: 8-bit picture and no shadows. 2: also no tape look. */
export type SafeLevel = 0 | 1 | 2;

const KEY = 'gd-safe';
const RELOADS = 'gd-safe-reloads';

export function phoneLike(): boolean {
  try { return window.matchMedia('(pointer: coarse)').matches; } catch { return false; }
}

/** The drawing level to use: `?safe=N` wins, then what an earlier crash on this device chose. */
export function readSafeLevel(params: URLSearchParams): SafeLevel {
  const clamp = (n: number): SafeLevel => (n >= 2 ? 2 : n >= 1 ? 1 : 0);
  const q = params.get('safe');
  if (q !== null) return clamp(Number(q) || 0);
  try { return clamp(Number(localStorage.getItem(KEY) ?? '0') || 0); } catch { return 0; }
}

function report(kind: string, data: Record<string, unknown>): void {
  // Only the hub has somewhere to send this; the public build stays silent.
  if (!location.pathname.startsWith('/play/')) return;
  try {
    const body = JSON.stringify({ kind, at: new Date().toISOString(), ...data });
    void fetch('/api/clientlog', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body, keepalive: true }).catch(() => undefined);
  } catch { /* reporting must never break the game */ }
}

function deviceInfo(renderer: THREE.WebGLRenderer): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  try {
    const gl = renderer.getContext();
    const dbg = gl.getExtension('WEBGL_debug_renderer_info');
    out.gpu = dbg ? String(gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL)) : 'unknown';
    out.webgl2 = renderer.capabilities.isWebGL2;
    out.maxTexture = renderer.capabilities.maxTextureSize;
    out.precision = renderer.capabilities.precision;
    out.halfFloatTarget = renderer.extensions.has('EXT_color_buffer_half_float') || renderer.extensions.has('EXT_color_buffer_float');
  } catch { out.gpu = 'unreadable'; }
  out.ua = navigator.userAgent;
  out.screen = `${window.innerWidth}x${window.innerHeight}@${window.devicePixelRatio}`;
  out.memoryGB = (navigator as unknown as { deviceMemory?: number }).deviceMemory ?? null;
  out.coarse = phoneLike();
  return out;
}

export interface Diagnostics {
  readonly safe: SafeLevel;
  /** Times the picture has been lost since the page loaded. */
  lost(): number;
  /** Records something worth knowing afterwards (kept small; only the last few are sent). */
  note(text: string): void;
}

export function installDiagnostics(
  renderer: THREE.WebGLRenderer,
  canvas: HTMLCanvasElement,
  safe: SafeLevel,
  state: () => Record<string, unknown>,
): Diagnostics {
  let lost = 0;
  let waiting: number | null = null;
  const notes: string[] = [];
  const snapshot = (): Record<string, unknown> => {
    let s: Record<string, unknown> = {};
    try { s = state(); } catch { s = { state: 'unreadable' }; }
    return { safe, lost, notes: notes.slice(-12), ...s };
  };

  const banner = document.createElement('div');
  banner.hidden = true;
  banner.style.cssText =
    'position:fixed;left:50%;top:38%;transform:translate(-50%,-50%);z-index:9;padding:12px 16px;max-width:80vw;' +
    'background:rgba(10,16,14,0.9);color:#eef3f0;font:600 15px ui-monospace,Consolas,monospace;text-align:center;border:1px solid #5d6a64;';
  document.body.append(banner);
  const say = (text: string | null): void => { banner.hidden = text === null; banner.textContent = text ?? ''; };

  /** Drops to a lighter way of drawing and reloads, unless that has already been tried twice. */
  const stepDown = (why: string): void => {
    let reloads = 0;
    try { reloads = Number(sessionStorage.getItem(RELOADS) ?? '0') || 0; } catch { /* ignore */ }
    const next = Math.min(2, safe + 1) as SafeLevel;
    report('stepdown', { why, next, reloads, ...snapshot() });
    if (reloads >= 2 || next === safe) {
      say('THE PICTURE WAS LOST AND COULD NOT BE RESTORED ON THIS DEVICE. RELOAD TO TRY AGAIN.');
      return;
    }
    try {
      localStorage.setItem(KEY, String(next));
      sessionStorage.setItem(RELOADS, String(reloads + 1));
    } catch { /* storage may be blocked; reload anyway with the flag in the address */ }
    say('SWITCHING TO A LIGHTER PICTURE...');
    const url = new URL(location.href);
    url.searchParams.set('safe', String(next));
    window.setTimeout(() => location.replace(url.toString()), 600);
  };

  canvas.addEventListener('webglcontextlost', (e) => {
    e.preventDefault(); // without this the browser will not give the context back
    lost++;
    report('contextlost', { device: deviceInfo(renderer), ...snapshot() });
    if (lost >= 2) { stepDown('lost twice'); return; }
    say('PICTURE LOST. RESTORING...');
    waiting = window.setTimeout(() => stepDown('not restored in 4 s'), 4000);
  });
  canvas.addEventListener('webglcontextrestored', () => {
    if (waiting !== null) window.clearTimeout(waiting);
    waiting = null;
    say(null);
    report('contextrestored', snapshot());
  });
  window.addEventListener('error', (e) => report('error', { message: String(e.message).slice(0, 300), where: `${e.filename ?? ''}:${e.lineno ?? 0}`, ...snapshot() }));
  window.addEventListener('unhandledrejection', (e) => report('rejection', { message: String((e as PromiseRejectionEvent).reason).slice(0, 300), ...snapshot() }));

  // One report a few seconds in, so a device that works is on record too.
  window.setTimeout(() => report('boot', { device: deviceInfo(renderer), ...snapshot() }), 3000);

  return { safe, lost: () => lost, note: (text) => { notes.push(`${Math.round(performance.now())}ms ${text}`.slice(0, 120)); if (notes.length > 40) notes.shift(); } };
}
