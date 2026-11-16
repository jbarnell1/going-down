// The camcorder's on-screen display: "PLAY" in the top right and a running tape counter in the
// bottom right, in a blocky 5x7 character-generator font drawn into tiny canvases and scaled up with
// hard pixels. Sits inside the picture's safe area, well away from the centre of view.

const GLYPHS: Record<string, string[]> = {
  '0': ['01110', '10001', '10011', '10101', '11001', '10001', '01110'],
  '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
  '2': ['01110', '10001', '00001', '00010', '00100', '01000', '11111'],
  '3': ['11111', '00010', '00100', '00010', '00001', '10001', '01110'],
  '4': ['00010', '00110', '01010', '10010', '11111', '00010', '00010'],
  '5': ['11111', '10000', '11110', '00001', '00001', '10001', '01110'],
  '6': ['00110', '01000', '10000', '11110', '10001', '10001', '01110'],
  '7': ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
  '8': ['01110', '10001', '10001', '01110', '10001', '10001', '01110'],
  '9': ['01110', '10001', '10001', '01111', '00001', '00010', '01100'],
  ':': ['00000', '01100', '01100', '00000', '01100', '01100', '00000'],
  ' ': ['00000', '00000', '00000', '00000', '00000', '00000', '00000'],
  P: ['11110', '10001', '10001', '11110', '10000', '10000', '10000'],
  L: ['10000', '10000', '10000', '10000', '10000', '10000', '11111'],
  A: ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
  Y: ['10001', '10001', '01010', '00100', '00100', '00100', '00100'],
  S: ['01111', '10000', '10000', '01110', '00001', '00001', '11110'],
  '>': ['10000', '11000', '11100', '11110', '11100', '11000', '10000'],
};

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
  for (const [ox, oy, colour] of [[1, 1, 'rgba(0,0,0,0.55)'], [0, 0, '#f4f4ec']] as const) {
    g.fillStyle = colour;
    for (let i = 0; i < text.length; i++) {
      const rows = GLYPHS[text[i] ?? ' '] ?? GLYPHS[' ']!;
      for (let y = 0; y < 7; y++) {
        const row = rows[y] ?? '';
        for (let x = 0; x < 5; x++) if (row[x] === '1') g.fillRect(i * 6 + x + ox, y + oy, 1, 1);
      }
    }
  }
}

export class Osd {
  private readonly root: HTMLDivElement;
  private readonly top: HTMLCanvasElement;
  private readonly bottom: HTMLCanvasElement;
  private lastTop = '';
  private lastBottom = '';
  private readonly startSec: number;
  private readonly t0 = performance.now();
  private scale = 2;

  constructor(parent: HTMLElement, seed: string) {
    this.root = document.createElement('div');
    this.root.id = 'osd';
    this.top = document.createElement('canvas');
    this.top.className = 'osd-top';
    this.bottom = document.createElement('canvas');
    this.bottom.className = 'osd-bottom';
    this.root.append(this.top, this.bottom);
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

  /** Called once a frame; only redraws when the text changes. */
  update(blinkOn: boolean): void {
    if (this.root.hidden) return;
    const s = Math.floor(this.startSec + (performance.now() - this.t0) / 1000);
    const top = blinkOn ? 'PLAY >' : 'PLAY  ';
    const hh = Math.floor(s / 3600);
    const mm = String(Math.floor(s / 60) % 60).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    const bottom = `SP ${hh}:${mm}:${ss}`;
    if (top !== this.lastTop) draw(this.top, (this.lastTop = top), this.scale);
    if (bottom !== this.lastBottom) draw(this.bottom, (this.lastBottom = bottom), this.scale);
  }

  private resize(): void {
    this.scale = Math.max(2, Math.floor(window.innerHeight / 320));
    this.lastTop = '';
    this.lastBottom = '';
  }
}
