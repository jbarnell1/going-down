// The prompt that appears when a dropped tape is within reach: a cassette mark with the key to press
// (E) on a computer, or a button to tap on a phone. Camcorder font, low on the screen, off-centre.

import { drawText, textWidth } from './pixelFont';

export class PickupPrompt {
  readonly el: HTMLDivElement;
  private readonly canvas: HTMLCanvasElement;
  private text = '';

  constructor(parent: HTMLElement, onTap: () => void) {
    this.el = document.createElement('div');
    this.el.id = 'pickup';
    this.el.hidden = true;
    this.canvas = document.createElement('canvas');
    this.el.append(this.canvas);
    parent.append(this.el);
    this.el.addEventListener('pointerdown', (e) => {
      e.stopPropagation();
      e.preventDefault();
      onTap();
    });
  }

  /** Shown while a tape is in reach; `touch` picks the phone's tap button over the key. */
  update(show: boolean, touch: boolean): void {
    this.el.hidden = !show;
    if (!show) return;
    const text = touch ? '#' : 'E #';
    if (text === this.text) return;
    this.text = text;
    this.el.classList.toggle('touch', touch);
    const w = textWidth(text) + 4;
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
      // The key in a box.
      g.fillStyle = 'rgba(244,244,236,0.85)';
      g.fillRect(0, 0, 9, h);
      g.fillStyle = '#111';
      drawText(g, 'E', 2, 2);
      g.fillStyle = 'rgba(0,0,0,0.55)';
      drawText(g, '#', 15, 3);
      g.fillStyle = '#f4f4ec';
      drawText(g, '#', 14, 2);
    } else {
      g.fillStyle = '#f4f4ec';
      drawText(g, '#', 2, 2);
    }
  }
}
