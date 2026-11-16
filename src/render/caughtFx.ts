// Placeholder for being caught: the picture cuts to tape noise, then a brief line of text. The real
// rules for what being caught means come in a later task. Before the noise there may be a hard cut to
// black: the first instant of being taken, when this screen has committed to the catch (net/client.ts,
// the taken latch) and the host's word has not arrived yet.

/** How long the picture is noise before the player comes back at the landing, ms. */
export const NOISE_MS = 2000;
/** How long the line stays up afterwards, ms. */
export const LINE_MS = 3200;

export class CaughtFx {
  private readonly noise: HTMLCanvasElement;
  private readonly line: HTMLDivElement;
  private readonly img: ImageData | null;
  private readonly black: HTMLDivElement;
  private noiseUntil = 0;
  private lineUntil = 0;

  constructor(parent: HTMLElement) {
    this.noise = document.createElement('canvas');
    this.noise.id = 'caught-noise';
    this.noise.width = 192;
    this.noise.height = 108;
    this.noise.hidden = true;
    this.line = document.createElement('div');
    this.line.id = 'went-down';
    this.line.textContent = 'YOU WENT DOWN';
    this.line.hidden = true;
    this.black = document.createElement('div');
    this.black.id = 'taken-black';
    this.black.hidden = true;
    this.black.style.cssText = 'position:fixed;inset:0;background:#000;pointer-events:none;';
    // Under the noise, so the noise takes over from the black with no frame between.
    parent.append(this.black, this.noise, this.line);
    this.img = this.noise.getContext('2d')?.createImageData(this.noise.width, this.noise.height) ?? null;
  }

  /** Starts the noise; it ends by itself after NOISE_MS. */
  start(now: number): void {
    this.noiseUntil = now + NOISE_MS;
    this.noise.hidden = false;
  }

  /** The hard cut to black of being taken (on while the latch holds). */
  blackout(on: boolean): void {
    this.black.hidden = !on;
  }

  get blackOn(): boolean {
    return !this.black.hidden;
  }

  get noiseOn(): boolean {
    return !this.noise.hidden;
  }

  get lineOn(): boolean {
    return !this.line.hidden;
  }

  /** Clears the noise and the line at once (a new run). */
  reset(): void {
    this.noise.hidden = true;
    this.line.hidden = true;
    this.black.hidden = true;
  }

  /**
   * Per frame. Returns true on the frame the noise ends (the moment to put the player back). With
   * `line` false the line is not shown afterwards (the run ended instead: its own screen follows).
   */
  update(now: number, line = true): boolean {
    let ended = false;
    if (!this.noise.hidden) {
      if (now >= this.noiseUntil) {
        this.noise.hidden = true;
        this.line.hidden = !line;
        this.lineUntil = now + LINE_MS;
        ended = true;
      } else this.draw();
    } else if (!this.line.hidden && now >= this.lineUntil) this.line.hidden = true;
    return ended;
  }

  private draw(): void {
    const g = this.noise.getContext('2d');
    if (!g || !this.img) return;
    const d = this.img.data;
    const w = this.noise.width;
    // Snow with rolling bands, like a tape with no picture on it.
    const band = Math.random() * this.noise.height;
    for (let y = 0; y < this.noise.height; y++) {
      const lift = Math.abs(y - band) < 6 ? 60 : 0;
      for (let x = 0; x < w; x++) {
        const v = Math.min(255, (Math.random() * 200) | 0) + lift;
        const i = (y * w + x) * 4;
        d[i] = v;
        d[i + 1] = v;
        d[i + 2] = v;
        d[i + 3] = 255;
      }
    }
    g.putImageData(this.img, 0, 0);
  }
}
