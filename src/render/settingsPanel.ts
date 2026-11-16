// The settings panel: a small box in the camcorder's pixel font, top left, covering only part of the
// view. It never pauses anything (the game is multiplayer). Rows are added with a tiny API:
//
//   panel.choice('voice', 'VOICE', () => options, () => current, (v) => apply(v))   < VALUE > cycles
//   panel.stepper('volume', 'VOLUME', () => n, (n) => apply(n), { step, min, max, format })
//   panel.action('sample', 'PLAY A SAMPLE', () => doIt())
//
// On a phone a small gear button in the top left corner opens and closes it. Every control is a real
// <button> (data-setting, data-dir) so the keyboard, touch and tests all work the same way.

import { drawText } from './pixelFont';

export interface Option<V> {
  value: V;
  label: string;
}

/** A canvas showing `text` in the pixel font, `scale` screen pixels per font pixel. */
function textCanvas(text: string, scale: number, color = '#f4f4ec', mirror = false): HTMLCanvasElement {
  const c = document.createElement('canvas');
  const w = Math.max(1, text.length * 6 - 1) + 2;
  const h = 9;
  c.width = w;
  c.height = h;
  c.style.cssText = `display:block;width:${w * scale}px;height:${h * scale}px;image-rendering:pixelated;pointer-events:none;`;
  const g = c.getContext('2d');
  if (g) {
    // The font's '>' is the camcorder's PLAY triangle; a mirrored '<' makes the matching arrow.
    if (mirror) g.setTransform(-1, 0, 0, 1, w, 0);
    g.fillStyle = 'rgba(0,0,0,0.6)';
    drawText(g, text, 2, 2);
    g.fillStyle = color;
    drawText(g, text, 1, 1);
  }
  return c;
}

function gearCanvas(scale: number): HTMLCanvasElement {
  const rows = ['00100100', '01111110', '11100111', '01000010', '01000010', '11100111', '01111110', '00100100'];
  const c = document.createElement('canvas');
  c.width = 8;
  c.height = 8;
  c.style.cssText = `display:block;width:${8 * scale}px;height:${8 * scale}px;image-rendering:pixelated;pointer-events:none;`;
  const g = c.getContext('2d');
  if (g) {
    g.fillStyle = '#f4f4ec';
    rows.forEach((r, y) => [...r].forEach((b, x) => b === '1' && g.fillRect(x, y, 1, 1)));
  }
  return c;
}

const BTN = 'background:transparent;border:2px solid transparent;border-radius:4px;padding:3px 5px;margin:0;cursor:pointer;color:inherit;touch-action:manipulation;';

export class SettingsPanel {
  readonly el: HTMLDivElement;
  readonly gear: HTMLButtonElement;
  private readonly rows: (() => void)[] = [];
  private readonly scale: number;
  /** performance.now() when it last opened or closed (a click that opened it must not also close it). */
  changedAt = Number.NEGATIVE_INFINITY;

  constructor(parent: HTMLElement) {
    this.scale = window.innerWidth < 700 || window.innerHeight < 500 ? 2 : 3;
    this.el = document.createElement('div');
    this.el.id = 'settings';
    this.el.hidden = true;
    this.el.style.cssText =
      'position:fixed;left:max(5vw,14px);top:max(5vh,10px);z-index:8;background:rgba(8,11,10,0.86);border:2px solid rgba(240,245,242,0.45);' +
      'border-radius:6px;padding:8px 10px;display:flex;flex-direction:column;gap:2px;max-width:calc(100vw - 28px);max-height:calc(100vh - 20px);overflow:auto;';
    this.el.append(textCanvas('SETTINGS', this.scale, '#ffd27a'));
    // Clicks inside the panel stay inside it (they must not start a walk stick or re-lock the mouse).
    for (const ev of ['pointerdown', 'mousedown', 'click', 'touchstart'] as const) this.el.addEventListener(ev, (e) => e.stopPropagation());
    parent.append(this.el);

    this.gear = document.createElement('button');
    this.gear.id = 'settings-gear';
    this.gear.setAttribute('aria-label', 'Settings');
    this.gear.hidden = true;
    this.gear.style.cssText =
      `${BTN}position:fixed;left:max(2vw,8px);top:max(2vh,8px);z-index:9;padding:8px;background:rgba(240,245,242,0.12);border-color:rgba(240,245,242,0.45);`;
    this.gear.append(gearCanvas(3));
    for (const ev of ['pointerdown', 'mousedown', 'touchstart'] as const) this.gear.addEventListener(ev, (e) => e.stopPropagation());
    this.gear.addEventListener('click', (e) => {
      e.stopPropagation();
      this.toggle();
    });
    parent.append(this.gear);
  }

  get isOpen(): boolean {
    return !this.el.hidden;
  }

  open(): void {
    if (this.isOpen) return;
    this.refresh();
    this.el.hidden = false;
    this.changedAt = performance.now();
  }

  close(): void {
    if (!this.isOpen) return;
    this.el.hidden = true;
    this.changedAt = performance.now();
    if (this.el.contains(document.activeElement)) (document.activeElement as HTMLElement).blur();
  }

  toggle(): void {
    if (this.isOpen) this.close();
    else this.open();
  }

  showGear(on: boolean): void {
    if (this.gear.hidden !== on) return;
    this.gear.hidden = !on;
    // Beside the gear, not under it.
    this.el.style.left = on ? 'calc(max(2vw,8px) + 64px)' : 'max(5vw,14px)';
    this.el.style.top = on ? 'max(2vh,8px)' : 'max(5vh,10px)';
  }

  /** Redraws every row from the current values. */
  refresh(): void {
    for (const r of this.rows) r();
  }

  private row(key: string, label: string): { row: HTMLDivElement; value: HTMLDivElement } {
    const row = document.createElement('div');
    row.dataset.setting = key;
    row.style.cssText = 'display:flex;align-items:center;gap:6px;flex-wrap:wrap;';
    const name = document.createElement('div');
    name.style.cssText = `min-width:${10 * 6 * this.scale}px;opacity:0.8;`;
    name.append(textCanvas(label, this.scale, '#c9cfcb'));
    const value = document.createElement('div');
    value.style.cssText = 'display:flex;align-items:center;gap:2px;';
    row.append(name, value);
    this.el.append(row);
    return { row, value };
  }

  private button(key: string, dir: string, text: string, onPress: () => void): HTMLButtonElement {
    const b = document.createElement('button');
    b.dataset.setting = key;
    b.dataset.dir = dir;
    b.style.cssText = BTN;
    // Fingers need bigger targets than a mouse.
    if (typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches) b.style.padding = '7px 10px';
    b.append(text === '>' ? textCanvas('<', this.scale, '#f4f4ec', true) : textCanvas(text, this.scale));
    b.addEventListener('focus', () => (b.style.borderColor = 'rgba(255,210,122,0.8)'));
    b.addEventListener('blur', () => (b.style.borderColor = 'transparent'));
    b.addEventListener('click', (e) => {
      e.stopPropagation();
      onPress();
      this.refresh();
    });
    return b;
  }

  /** A setting with a few values: < VALUE > steps through them (the value itself steps forward). */
  choice<V>(key: string, label: string, options: () => Option<V>[], get: () => V, set: (v: V) => void): void {
    const { row, value } = this.row(key, label);
    const step = (d: number): void => {
      const opts = options();
      if (!opts.length) return;
      const i = opts.findIndex((o) => o.value === get());
      const next = opts[(Math.max(0, i) + d + opts.length) % opts.length];
      if (next) set(next.value);
    };
    value.append(this.button(key, 'prev', '<', () => step(-1)), this.button(key, 'value', '', () => step(1)), this.button(key, 'next', '>', () => step(1)));
    this.rows.push(() => {
      const cur = options().find((o) => o.value === get());
      const text = (cur?.label ?? String(get())).toUpperCase();
      row.dataset.value = String(get());
      const mid = value.querySelector<HTMLButtonElement>('[data-dir="value"]');
      if (mid) mid.replaceChildren(textCanvas(text.padEnd(6, ' '), this.scale, '#ffd27a'));
    });
  }

  /** A number stepped by - and +. */
  stepper(key: string, label: string, get: () => number, set: (n: number) => void, o: { step: number; min: number; max: number; format: (n: number) => string }): void {
    const { row, value } = this.row(key, label);
    const shown = document.createElement('div');
    const nudge = (d: number): void => set(Math.round(Math.max(o.min, Math.min(o.max, get() + d * o.step)) * 1000) / 1000);
    value.append(this.button(key, 'prev', '-', () => nudge(-1)), shown, this.button(key, 'next', '+', () => nudge(1)));
    this.rows.push(() => {
      row.dataset.value = String(get());
      shown.replaceChildren(textCanvas(o.format(get()).padStart(4, ' '), this.scale, '#ffd27a'));
    });
  }

  /** A button that does something. */
  action(key: string, label: string, run: () => void): void {
    const { value } = this.row(key, '');
    value.append(this.button(key, 'run', label, run));
  }
}
