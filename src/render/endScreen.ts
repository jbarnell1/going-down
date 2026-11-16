// The end of a run: a plain screen in the camcorder font. The banked summary (floors, readings, the
// total, your share, the lifetime total), the wipe (nothing banked), or the one line for being left
// behind. A key or a tap starts a new run.

import { drawText, textWidth } from './pixelFont';

export interface EndLine {
  text: string;
  /** Brighter, for the heading and the money. */
  strong?: boolean;
}

export class EndScreen {
  readonly el: HTMLDivElement;
  private readonly canvas: HTMLCanvasElement;
  private lines: EndLine[] = [];
  /** performance.now() when it was shown. */
  shownAt = 0;

  constructor(parent: HTMLElement) {
    this.el = document.createElement('div');
    this.el.id = 'end';
    this.el.hidden = true;
    this.canvas = document.createElement('canvas');
    this.el.append(this.canvas);
    parent.append(this.el);
    window.addEventListener('resize', () => this.draw());
  }

  get shown(): boolean {
    return !this.el.hidden;
  }

  /** The lines on screen now, for tests. */
  get text(): string[] {
    return this.shown ? this.lines.map((l) => l.text) : [];
  }

  show(lines: EndLine[]): void {
    this.lines = lines;
    this.el.hidden = false;
    this.shownAt = performance.now();
    this.draw();
  }

  hide(): void {
    this.el.hidden = true;
  }

  private draw(): void {
    if (this.el.hidden) return;
    const w = Math.max(...this.lines.map((l) => textWidth(l.text)), 10) + 4;
    const rowH = 11;
    const h = this.lines.length * rowH + 2;
    const c = this.canvas;
    c.width = w;
    c.height = h;
    const scale = Math.max(2, Math.floor(Math.min((window.innerWidth * 0.8) / w, (window.innerHeight * 0.7) / h)));
    c.style.width = `${w * scale}px`;
    c.style.height = `${h * scale}px`;
    const g = c.getContext('2d');
    if (!g) return;
    g.clearRect(0, 0, w, h);
    this.lines.forEach((l, i) => {
      const x = Math.floor((w - textWidth(l.text)) / 2);
      const y = 2 + i * rowH;
      g.fillStyle = 'rgba(0,0,0,0.6)';
      drawText(g, l.text, x + 1, y + 1);
      g.fillStyle = l.strong ? '#ffd27a' : '#d8ddd9';
      drawText(g, l.text, x, y);
    });
  }
}
