// The camcorder's on-screen display: "PLAY" in the top right and a running tape counter in the
// bottom right, in a blocky 5x7 character-generator font drawn into tiny canvases and scaled up with
// hard pixels. Sits inside the picture's safe area, well away from the centre of view.
//
// Above the counter, once there is anything on it, the value on the tapes you hold: a cassette mark,
// how many tapes, and their worth. It blinks for a moment when a reading lands on it.

import { drawText } from './pixelFont';

function draw(c: HTMLCanvasElement, text: string, scale: number): void {
  const w = text.length * 6 + 1;
  const h = 9;
  if (c.width !== w) c.width = w;
  if (c.height !== h) c.height = h;
  c.style.width = `${w * scale}px`;
  c.style.height = `${h * scale}px`;
  const g = c.getContext('2d');
  if (!g) return;
  g.clearRect(0, 0, w, h);
  // A dark drop shadow one pixel down-right, then the characters, like a camcorder's char generator.
  g.fillStyle = 'rgba(0,0,0,0.55)';
  drawText(g, text, 1, 1);
  g.fillStyle = '#f4f4ec';
  drawText(g, text, 0, 0);
}

/** How long the tape line blinks after its value jumps, ms, and the blink period. */
const JUMP_MS = 900;
const JUMP_BLINK_MS = 150;

export class Osd {
  private readonly root: HTMLDivElement;
  private readonly top: HTMLCanvasElement;
  private readonly bottom: HTMLCanvasElement;
  private readonly tapeLine: HTMLCanvasElement;
  private lastTop = '';
  private lastBottom = '';
  private lastTape = '';
  private readonly startSec: number;
  private readonly t0 = performance.now();
  private scale = 2;
  private tapeValue = 0;
  private tapeCount = 0;
  private jumpAt = -1e9;

  constructor(parent: HTMLElement, seed: string) {
    this.root = document.createElement('div');
    this.root.id = 'osd';
    this.top = document.createElement('canvas');
    this.top.className = 'osd-top';
    this.bottom = document.createElement('canvas');
    this.bottom.className = 'osd-bottom';
    this.tapeLine = document.createElement('canvas');
    this.tapeLine.className = 'osd-tape';
    this.tapeLine.hidden = true;
    this.root.append(this.top, this.bottom, this.tapeLine);
    parent.append(this.root);
    // The counter starts part-way into the tape, picked from the seed: this is not the first recording.
    let h = 2166136261;
    for (const ch of seed) h = Math.imul(h ^ ch.charCodeAt(0), 16777619);
    this.startSec = 1500 + ((h >>> 0) % 4800);
    this.resize();
    window.addEventListener('resize', () => this.resize());
  }

  set visible(v: boolean) {
    this.root.hidden = !v;
  }

  /** The tapes held: how many have something on them, and their total value. */
  setTapes(count: number, value: number): void {
    const v = Math.floor(value);
    if (v > Math.floor(this.tapeValue)) this.jumpAt = performance.now();
    this.tapeValue = value;
    this.tapeCount = count;
  }

  /** The text of the tape line as drawn now ('' while hidden). For tests. */
  get tapeText(): string {
    return this.tapeLine.hidden ? '' : this.lastTape;
  }

  /** Called once a frame; only redraws when the text changes. */
  update(blinkOn: boolean): void {
    if (this.root.hidden) return;
    const now = performance.now();
    const s = Math.floor(this.startSec + (now - this.t0) / 1000);
    const top = blinkOn ? 'PLAY >' : 'PLAY  ';
    const hh = Math.floor(s / 3600);
    const mm = String(Math.floor(s / 60) % 60).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    const bottom = `SP ${hh}:${mm}:${ss}`;
    if (top !== this.lastTop) draw(this.top, (this.lastTop = top), this.scale);
    if (bottom !== this.lastBottom) draw(this.bottom, (this.lastBottom = bottom), this.scale);

    const show = this.tapeCount > 0 || this.tapeValue > 0;
    const since = now - this.jumpAt;
    // Blinks off and on a few times right after a jump.
    const blinkOff = since < JUMP_MS && Math.floor(since / JUMP_BLINK_MS) % 2 === 1;
    this.tapeLine.hidden = !show || blinkOff;
    const tape = `#x${this.tapeCount} ${String(Math.floor(this.tapeValue)).padStart(4, '0')}`;
    if (show && tape !== this.lastTape) draw(this.tapeLine, (this.lastTape = tape), this.scale);
  }

  private resize(): void {
    this.scale = Math.max(2, Math.floor(window.innerHeight / 320));
    this.lastTop = '';
    this.lastBottom = '';
    this.lastTape = '';
    // The tape line sits one text row above the counter.
    this.tapeLine.style.bottom = `calc(max(6vh, 12px) + ${12 * this.scale}px)`;
  }
}
