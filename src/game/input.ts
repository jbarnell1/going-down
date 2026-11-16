// Keyboard, mouse and touch. Mouse look only while the pointer is locked; the click-to-start
// overlay asks for the lock. On a phone there is no lock: the left thumb is a walk stick and the
// right thumb drags to look. Nothing else in the game waits on the lock, so tests can drive it headless.

/** How the player wants to move this frame, in their own frame of reference. */
export interface MoveIntent {
  /** Forward (+) or back (-). */
  f: number;
  /** Right (+) or left (-). */
  r: number;
  /** 0 to 1: how hard the stick is pushed. Keys always give 1. */
  strength: number;
  /** Shift held: creep at a fixed slow speed. */
  creep: boolean;
}

const STICK_RADIUS = 56; // px of thumb travel for full speed
const STICK_DEADZONE = 0.12;
const TOUCH_LOOK_SCALE = 2.8; // a thumb drags far fewer pixels than a mouse travels
const STICK_ZONE = 0.45; // left share of the screen that starts a walk stick

export class Input {
  private keys = new Set<string>();
  private dx = 0;
  private dy = 0;
  locked = false;
  /** True once a finger has been used. From then on the overlay never asks for a pointer lock. */
  touch = false;

  private stickId: number | null = null;
  private stickX0 = 0;
  private stickY0 = 0;
  private stickX = 0;
  private stickY = 0;
  private lookId: number | null = null;
  private lookX = 0;
  private lookY = 0;
  private ring: HTMLDivElement;
  private knob: HTMLDivElement;

  constructor(private canvas: HTMLCanvasElement, private overlay: HTMLElement) {
    window.addEventListener('keydown', (e) => this.keys.add(e.code));
    window.addEventListener('keyup', (e) => this.keys.delete(e.code));
    window.addEventListener('blur', () => this.releaseAll());
    document.addEventListener('visibilitychange', () => { if (document.hidden) this.releaseAll(); });

    overlay.addEventListener('click', () => {
      if (this.touch) return;
      try {
        // Some browsers return a promise that rejects when the lock is refused; that is not an error.
        const req = canvas.requestPointerLock() as unknown;
        if (req instanceof Promise) req.catch(() => undefined);
      } catch { /* no pointer lock on this device */ }
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

    this.ring = stickPart(STICK_RADIUS * 2, 'rgba(240,245,242,0.35)', 'transparent');
    this.knob = stickPart(44, 'rgba(240,245,242,0.6)', 'rgba(240,245,242,0.25)');
    document.body.append(this.ring, this.knob);

    window.addEventListener('pointerdown', (e) => this.touchDown(e));
    window.addEventListener('pointermove', (e) => this.touchMove(e));
    window.addEventListener('pointerup', (e) => this.touchUp(e));
    window.addEventListener('pointercancel', (e) => this.touchUp(e));
    // A long press must not open a menu or start a text selection mid-game.
    window.addEventListener('contextmenu', (e) => { if (this.touch) e.preventDefault(); });
  }

  private touchDown(e: PointerEvent): void {
    if (e.pointerType !== 'touch') return;
    this.touch = true;
    if (!this.overlay.hidden) {
      // The first tap only starts the game.
      this.overlay.hidden = true;
      return;
    }
    if (e.clientX < window.innerWidth * STICK_ZONE && this.stickId === null) {
      this.stickId = e.pointerId;
      this.stickX0 = this.stickX = e.clientX;
      this.stickY0 = this.stickY = e.clientY;
      this.drawStick();
    } else if (this.lookId === null) {
      this.lookId = e.pointerId;
      this.lookX = e.clientX;
      this.lookY = e.clientY;
    }
  }

  private touchMove(e: PointerEvent): void {
    if (e.pointerId === this.stickId) {
      this.stickX = e.clientX;
      this.stickY = e.clientY;
      this.drawStick();
    } else if (e.pointerId === this.lookId) {
      this.dx += (e.clientX - this.lookX) * TOUCH_LOOK_SCALE;
      this.dy += (e.clientY - this.lookY) * TOUCH_LOOK_SCALE;
      this.lookX = e.clientX;
      this.lookY = e.clientY;
    }
  }

  private touchUp(e: PointerEvent): void {
    if (e.pointerId === this.stickId) {
      this.stickId = null;
      this.drawStick();
    } else if (e.pointerId === this.lookId) {
      this.lookId = null;
    }
  }

  private releaseAll(): void {
    this.keys.clear();
    this.stickId = null;
    this.lookId = null;
    this.drawStick();
  }

  private drawStick(): void {
    const on = this.stickId !== null;
    this.ring.hidden = !on;
    this.knob.hidden = !on;
    if (!on) return;
    let ox = this.stickX - this.stickX0;
    let oy = this.stickY - this.stickY0;
    const len = Math.hypot(ox, oy);
    if (len > STICK_RADIUS) { ox *= STICK_RADIUS / len; oy *= STICK_RADIUS / len; }
    this.ring.style.transform = `translate(${this.stickX0 - STICK_RADIUS}px, ${this.stickY0 - STICK_RADIUS}px)`;
    this.knob.style.transform = `translate(${this.stickX0 + ox - 22}px, ${this.stickY0 + oy - 22}px)`;
  }

  /** Hides the overlay without a pointer lock (tests, and anyone who just wants to watch). */
  dismissOverlay(): void {
    this.overlay.hidden = true;
  }

  down(code: string): boolean {
    return this.keys.has(code);
  }

  /** What the player is asking for, from the stick if a thumb is on it, otherwise from the keys. */
  move(): MoveIntent | null {
    if (this.stickId !== null) {
      const ox = (this.stickX - this.stickX0) / STICK_RADIUS;
      const oy = (this.stickY - this.stickY0) / STICK_RADIUS;
      const len = Math.hypot(ox, oy);
      if (len < STICK_DEADZONE) return null;
      // Screen up is forward. Pushing gently walks slowly, which is how you creep on a phone.
      return { f: -oy / len, r: ox / len, strength: Math.min(1, len), creep: false };
    }
    let f = 0;
    let r = 0;
    if (this.down('KeyW') || this.down('ArrowUp')) f += 1;
    if (this.down('KeyS') || this.down('ArrowDown')) f -= 1;
    if (this.down('KeyD') || this.down('ArrowRight')) r += 1;
    if (this.down('KeyA') || this.down('ArrowLeft')) r -= 1;
    if (f === 0 && r === 0) return null;
    const len = Math.hypot(f, r);
    return { f: f / len, r: r / len, strength: 1, creep: this.down('ShiftLeft') || this.down('ShiftRight') };
  }

  /** Look movement in mouse-pixel units since the last call. */
  takeLook(): [number, number] {
    const out: [number, number] = [this.dx, this.dy];
    this.dx = 0;
    this.dy = 0;
    return out;
  }
}

function stickPart(size: number, border: string, fill: string): HTMLDivElement {
  const d = document.createElement('div');
  d.hidden = true;
  d.style.cssText =
    `position:fixed;left:0;top:0;width:${size}px;height:${size}px;border-radius:50%;` +
    `border:2px solid ${border};background:${fill};pointer-events:none;box-sizing:border-box;z-index:3;`;
  return d;
}
