// The elevator's prompt: the key to press (E) and a mark for what it does, in the camcorder font, low
// on the screen; on a phone, a button to tap or hold. Used for the call button on the landing (a
// down arrow) and the door-hold button in the car (doors pushed apart, held while the key is).

import { drawText, textWidth } from './pixelFont';

export class ActionPrompt {
  readonly el: HTMLDivElement;
  private readonly canvas: HTMLCanvasElement;
  private text = '';
  /** A finger is on the phone button now. */
  held = false;

  constructor(parent: HTMLElement, id: string, onTap: () => void) {
    this.el = document.createElement('div');
    this.el.id = id;
    this.el.className = 'action-prompt';
    this.el.hidden = true;
    this.canvas = document.createElement('canvas');
    this.el.append(this.canvas);
    parent.append(this.el);
    this.el.addEventListener('pointerdown', (e) => {
      e.stopPropagation();
      e.preventDefault();
      this.held = true;
      onTap();
    });
    const up = (e: PointerEvent): void => {
      e.stopPropagation();
      this.held = false;
    };
    this.el.addEventListener('pointerup', up);
    this.el.addEventListener('pointercancel', up);
    this.el.addEventListener('pointerleave', up);
  }

  /** Shown with `mark` after the key; `touch` swaps the key for a tappable button. */
  update(show: boolean, touch: boolean, mark: string): void {
    this.el.hidden = !show;
    if (!show) {
      this.held = false;
      return;
    }
    const text = `${touch ? 't' : 'k'}${mark}`;
    if (text === this.text) return;
    this.text = text;
    this.el.classList.toggle('touch', touch);
    const markX = touch ? 2 : 14;
    const w = markX + textWidth(mark) + 3;
    const h = 11;
    const c = this.canvas;
    c.width = w;
    c.height = h;
    const scale = Math.max(3, Math.floor(window.innerHeight / 200));
    c.style.width = `${w * scale}px`;
    c.style.height = `${h * scale}px`;
    const g = c.getContext('2d');
    if (!g) return;
    g.clearRect(0, 0, w, h);
    if (!touch) {
      g.fillStyle = 'rgba(244,244,236,0.85)';
      g.fillRect(0, 0, 9, h);
      g.fillStyle = '#111';
      drawText(g, 'E', 2, 2);
    }
    g.fillStyle = 'rgba(0,0,0,0.55)';
    drawText(g, mark, markX + 1, 3);
    g.fillStyle = '#f4f4ec';
    drawText(g, mark, markX, 2);
  }
}
