// Keyboard and mouse. Mouse look only while the pointer is locked; the click-to-start overlay asks
// for the lock. Nothing else in the game waits on the lock, so tests can drive it headless.

export class Input {
  private keys = new Set<string>();
  private dx = 0;
  private dy = 0;
  locked = false;

  constructor(private canvas: HTMLCanvasElement, private overlay: HTMLElement) {
    window.addEventListener('keydown', (e) => this.keys.add(e.code));
    window.addEventListener('keyup', (e) => this.keys.delete(e.code));
    window.addEventListener('blur', () => this.keys.clear());
    overlay.addEventListener('click', () => {
      // Some browsers return a promise that rejects when the lock is refused; that is not an error.
      const req = canvas.requestPointerLock() as unknown;
      if (req instanceof Promise) req.catch(() => undefined);
    });
    document.addEventListener('pointerlockchange', () => {
      this.locked = document.pointerLockElement === this.canvas;
      this.overlay.hidden = this.locked;
      if (!this.locked) this.keys.clear();
    });
    document.addEventListener('mousemove', (e) => {
      if (!this.locked) return;
      this.dx += e.movementX;
      this.dy += e.movementY;
    });
  }

  /** Hides the overlay without a pointer lock (tests, and anyone who just wants to watch). */
  dismissOverlay(): void {
    this.overlay.hidden = true;
  }

  down(code: string): boolean {
    return this.keys.has(code);
  }

  /** Mouse movement in pixels since the last call. */
  takeLook(): [number, number] {
    const out: [number, number] = [this.dx, this.dy];
    this.dx = 0;
    this.dy = 0;
    return out;
  }
}
