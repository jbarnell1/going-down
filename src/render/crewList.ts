// The crew in a corner of the screen, in the camcorder font: each name, a mark when someone has been
// taken, has gone, or is only watching until the next stop, and what their tapes are worth so far.
// Shown only with more than one person in the run.

import { drawText, textWidth } from './pixelFont';

export interface CrewRow {
  name: string;
  me: boolean;
  /** '' when playing; otherwise TAKEN, GONE, LEFT or WATCHING. */
  mark: string;
  total: number;
}

export class CrewList {
  readonly el: HTMLCanvasElement;
  private key = '';
  /** The rows as drawn (tests). */
  rows: CrewRow[] = [];

  constructor(parent: HTMLElement) {
    this.el = document.createElement('canvas');
    this.el.id = 'crew-list';
    this.el.style.cssText = 'position:fixed;left:max(4vw,12px);top:max(5vh,10px);image-rendering:pixelated;pointer-events:none;opacity:0.85;';
    this.el.hidden = true;
    parent.append(this.el);
  }

  update(rows: readonly CrewRow[], show: boolean): void {
    this.el.hidden = !show;
    const lines = rows.map((r) => {
      const money = String(Math.floor(r.total)).padStart(4, '0');
      return `${r.me ? '>' : ' '}${r.name.padEnd(12).slice(0, 12)} ${r.mark ? r.mark.padEnd(8) : money.padEnd(8)}`;
    });
    const key = `${show}|${lines.join('\n')}`;
    this.rows = rows.map((r) => ({ ...r }));
    if (key === this.key || !show) return;
    this.key = key;
    const w = Math.max(...lines.map((l) => textWidth(l)), 10) + 4;
    const h = lines.length * 10 + 3;
    const c = this.el;
    c.width = w;
    c.height = h;
    const scale = window.innerWidth < 700 ? 1 : 2;
    c.style.width = `${w * scale}px`;
    c.style.height = `${h * scale}px`;
    const g = c.getContext('2d');
    if (!g) return;
    g.clearRect(0, 0, w, h);
    lines.forEach((l, i) => {
      const r = rows[i] as CrewRow;
      g.fillStyle = 'rgba(0,0,0,0.6)';
      drawText(g, l, 3, 3 + i * 10);
      g.fillStyle = r.mark ? '#e06a5a' : r.me ? '#ffd27a' : '#e8ece9';
      drawText(g, l, 2, 2 + i * 10);
    });
  }
}
