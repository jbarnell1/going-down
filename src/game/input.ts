// Keyboard, mouse and touch. Mouse look only while the pointer is locked; the click-to-start
// overlay asks for the lock. On a phone there is no lock: the left thumb is a walk stick and the
// right thumb drags to look. Nothing else in the game waits on the lock, so tests can drive it headless.
// The lock itself goes through pointerLock.ts: under test automation a stand-in that never takes the
// real cursor (Chrome on Windows would confine the machine owner's mouse to the hidden test window).
//
// The instrument is raised only while it is held: the right mouse button or F on a computer. On a
// phone a round hold-button sits under the right thumb; a press on it raises the instrument AND
// starts a look-drag with the same finger, so you can hold it up and still turn. A small latch
// button beside it keeps it raised without holding, for anyone who cannot hold and drag at once.
//
// Gait: hold Shift to sprint (while there is breath for it), hold C to creep. Plain Ctrl is never a
// game key, because Ctrl+W closes the tab; it creeps too only while the page is fullscreen AND the
// browser granted a keyboard lock (then the page gets Ctrl+W instead of the browser). On a phone the
// walk stick sprints when pushed to its rim (the outer 15% of its travel), and a small toggle button
// above the stick creeps.

import { makePointerLock, type PointerLock } from './pointerLock';

/** How the player wants to move this frame, in their own frame of reference. */
export interface MoveIntent {
  /** Forward (+) or back (-). */
  f: number;
  /** Right (+) or left (-). */
  r: number;
  /** 0 to 1: how hard the stick is pushed. Keys always give 1. */
  strength: number;
  /** C held (or the phone's creep toggle): creep at a fixed slow speed. */
  creep: boolean;
  /** Shift held, or the phone's stick at its rim: sprint, if there is breath for it. */
  sprint: boolean;
}

const STICK_RADIUS = 56; // px of thumb travel for full speed
const STICK_DEADZONE = 0.12;
const TOUCH_LOOK_SCALE = 2.8; // a thumb drags far fewer pixels than a mouse travels
const STICK_ZONE = 0.45; // left share of the screen that starts a walk stick
/** The stick sprints from this share of its travel out (its outer 15%). */
export const STICK_SPRINT = 0.85;

export class Input {
  private keys = new Set<string>();
  private dx = 0;
  private dy = 0;
  locked = false;
  /** The mouse lock: the browser's, or a stand-in under test automation (see pointerLock.ts). */
  readonly lock: PointerLock = makePointerLock();
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
  /** Right mouse button held. */
  private rmb = false;
  /** Keys pressed since the last takePress for them (no auto-repeat). */
  private pressed = new Set<string>();
  /** The finger holding the phone's raise button, if any. */
  private raiseId: number | null = null;
  /** The phone's latch: raised without holding. */
  latched = false;
  readonly raiseBtn: HTMLDivElement;
  readonly latchBtn: HTMLDivElement;
  /** The phone's creep toggle. */
  readonly creepBtn: HTMLDivElement;
  /** Creeping without holding a key (the phone's toggle). */
  creepLatched = false;
  /** Ctrl creeps too: only while fullscreen with a keyboard lock granted (see the header). */
  ctrlCreep = false;
  /** The mouse was released after play had started (Esc): return true to keep the start overlay hidden (the settings panel opens instead). */
  onUnlock: (() => boolean) | null = null;
  /** Esc pressed while the mouse is not locked and the game has started. */
  onEscape: (() => void) | null = null;

  constructor(private canvas: HTMLCanvasElement, private overlay: HTMLElement) {
    window.addEventListener('keydown', (e) => {
      if (e.code === 'Escape' && !e.repeat && !this.locked && this.overlay.hidden) this.onEscape?.();
      // Under a keyboard lock the page receives Ctrl+W and the like: they must do nothing.
      if (this.ctrlCreep && e.ctrlKey) e.preventDefault();
      this.keys.add(e.code);
      if (!e.repeat) this.pressed.add(e.code);
    });
    window.addEventListener('mousedown', (e) => { if (e.button === 2) this.rmb = true; });
    window.addEventListener('mouseup', (e) => { if (e.button === 2) this.rmb = false; });
    window.addEventListener('keyup', (e) => this.keys.delete(e.code));
    window.addEventListener('blur', () => this.releaseAll());
    document.addEventListener('visibilitychange', () => { if (document.hidden) this.releaseAll(); });
    document.addEventListener('fullscreenchange', () => this.fullscreenChanged());

    overlay.addEventListener('click', () => this.relock());
    document.addEventListener('pointerlockchange', () => {
      const was = this.locked;
      this.locked = this.lock.element() === this.canvas;
      this.overlay.hidden = this.locked || (was && this.onUnlock?.() === true);
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
    // A long press, or the right mouse button that raises the instrument, must not open a menu.
    window.addEventListener('contextmenu', (e) => e.preventDefault());

    this.raiseBtn = touchButton('raise-btn', 'right:max(5vw,16px);bottom:max(16vh,28px);width:86px;height:86px;', meterIcon(), 4);
    this.latchBtn = touchButton('latch-btn', 'right:calc(max(5vw,16px) + 98px);bottom:calc(max(16vh,28px) + 50px);width:46px;height:46px;', latchIcon(), 3);
    this.creepBtn = touchButton('creep-btn', 'left:max(5vw,16px);bottom:calc(max(16vh,28px) + 120px);width:46px;height:46px;', creepIcon(), 3);
    document.body.append(this.raiseBtn, this.latchBtn, this.creepBtn);
    this.creepBtn.addEventListener('pointerdown', (e) => {
      e.stopPropagation();
      e.preventDefault();
      this.creepLatched = !this.creepLatched;
      this.drawButtons();
    });
    this.raiseBtn.addEventListener('pointerdown', (e) => {
      e.stopPropagation();
      e.preventDefault();
      this.touch = true;
      this.raiseId = e.pointerId;
      // The same finger also looks, so holding the instrument up never stops you turning.
      if (this.lookId === null) {
        this.lookId = e.pointerId;
        this.lookX = e.clientX;
        this.lookY = e.clientY;
      }
      this.drawButtons();
    });
    this.latchBtn.addEventListener('pointerdown', (e) => {
      e.stopPropagation();
      e.preventDefault();
      this.latched = !this.latched;
      this.drawButtons();
    });
  }

  /** The instrument is being held up (any of the ways to hold it). */
  instrumentHeld(): boolean {
    return this.rmb || this.down('KeyF') || this.raiseId !== null || this.latched;
  }

  /** Asks for a keyboard lock when the page goes fullscreen; Ctrl creeps only once it is granted. */
  private fullscreenChanged(): void {
    this.ctrlCreep = false;
    const kb = (navigator as unknown as { keyboard?: { lock?: () => Promise<void>; unlock?: () => void } }).keyboard;
    if (!document.fullscreenElement) {
      try {
        kb?.unlock?.();
      } catch { /* nothing locked */ }
      return;
    }
    try {
      const p = kb?.lock?.();
      if (p) p.then(() => { this.ctrlCreep = document.fullscreenElement !== null; }).catch(() => { this.ctrlCreep = false; });
    } catch {
      this.ctrlCreep = false;
    }
  }

  /** Whether `code` was pressed since the last call for it. */
  takePress(code: string): boolean {
    const had = this.pressed.has(code);
    this.pressed.delete(code);
    return had;
  }

  private drawButtons(): void {
    const on = this.touch && this.overlay.hidden;
    this.raiseBtn.hidden = !on;
    this.latchBtn.hidden = !on;
    this.creepBtn.hidden = !on;
    this.creepBtn.style.background = this.creepLatched ? 'rgba(240,245,242,0.55)' : 'rgba(240,245,242,0.12)';
    this.raiseBtn.style.background = this.raiseId !== null || this.latched ? 'rgba(240,245,242,0.38)' : 'rgba(240,245,242,0.12)';
    this.latchBtn.style.background = this.latched ? 'rgba(240,245,242,0.55)' : 'rgba(240,245,242,0.12)';
  }

  private touchDown(e: PointerEvent): void {
    if (e.pointerType !== 'touch') return;
    this.touch = true;
    this.drawButtons();
    if (!this.overlay.hidden) {
      // The first tap only starts the game.
      this.overlay.hidden = true;
      this.drawButtons();
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
    if (e.pointerId === this.raiseId) {
      this.raiseId = null;
      this.drawButtons();
    }
    if (e.pointerId === this.stickId) {
      this.stickId = null;
      this.drawStick();
    } else if (e.pointerId === this.lookId) {
      this.lookId = null;
    }
  }

  private releaseAll(): void {
    this.keys.clear();
    this.rmb = false;
    this.raiseId = null;
    this.drawButtons();
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

  /** Asks for the mouse (desktop only; a refusal is not an error). */
  relock(): void {
    if (this.touch) return;
    this.lock.request(this.canvas);
  }

  /** Gives the mouse back. */
  unlock(): void {
    this.lock.exit();
  }

  /** Hides the overlay without a pointer lock (tests, and anyone who just wants to watch). */
  dismissOverlay(): void {
    this.overlay.hidden = true;
    this.drawButtons();
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
      // Screen up is forward. Pushing gently walks slowly; the rim sprints.
      return { f: -oy / len, r: ox / len, strength: Math.min(1, len), creep: this.creepLatched, sprint: len >= STICK_SPRINT };
    }
    let f = 0;
    let r = 0;
    if (this.down('KeyW') || this.down('ArrowUp')) f += 1;
    if (this.down('KeyS') || this.down('ArrowDown')) f -= 1;
    if (this.down('KeyD') || this.down('ArrowRight')) r += 1;
    if (this.down('KeyA') || this.down('ArrowLeft')) r -= 1;
    if (f === 0 && r === 0) return null;
    const len = Math.hypot(f, r);
    const ctrl = this.ctrlCreep && (this.down('ControlLeft') || this.down('ControlRight'));
    return {
      f: f / len,
      r: r / len,
      strength: 1,
      creep: this.down('KeyC') || ctrl || this.creepLatched,
      sprint: this.down('ShiftLeft') || this.down('ShiftRight'),
    };
  }

  /** Look movement in mouse-pixel units since the last call. */
  takeLook(): [number, number] {
    const out: [number, number] = [this.dx, this.dy];
    this.dx = 0;
    this.dy = 0;
    return out;
  }
}

function touchButton(id: string, place: string, icon: HTMLCanvasElement, iconPx: number): HTMLDivElement {
  const d = document.createElement('div');
  d.id = id;
  d.hidden = true;
  d.style.cssText =
    `position:fixed;${place}border-radius:50%;border:2px solid rgba(240,245,242,0.5);background:rgba(240,245,242,0.12);` +
    'box-sizing:border-box;z-index:4;display:flex;align-items:center;justify-content:center;touch-action:none;';
  // Whole pixels per icon pixel, sized explicitly (the page's canvas rule would stretch it otherwise).
  icon.style.cssText = `width:${icon.width * iconPx}px;height:${icon.height * iconPx}px;image-rendering:pixelated;pointer-events:none;flex:none;`;
  d.append(icon);
  return d;
}

/** Pixel icons, drawn in code: a needle meter (raise), a padlock (latch) and footprints (creep). */
function pixelIcon(rows: string[]): HTMLCanvasElement {
  const c = document.createElement('canvas');
  c.width = rows[0]?.length ?? 1;
  c.height = rows.length;
  const g = c.getContext('2d');
  if (g) {
    g.fillStyle = 'rgba(244,244,236,0.9)';
    rows.forEach((row, y) => { for (let x = 0; x < row.length; x++) if (row[x] === '1') g.fillRect(x, y, 1, 1); });
  }
  return c;
}

function meterIcon(): HTMLCanvasElement {
  return pixelIcon([
    '1111111111111',
    '1000000000001',
    '1010101010101',
    '1000000010001',
    '1000000100001',
    '1000001000001',
    '1000010000001',
    '1111111111111',
  ]);
}

function latchIcon(): HTMLCanvasElement {
  return pixelIcon([
    '0011100',
    '0100010',
    '0100010',
    '1111111',
    '1110111',
    '1110111',
    '1111111',
  ]);
}

/** Two footprints, small: creep. */
function creepIcon(): HTMLCanvasElement {
  return pixelIcon([
    '0110000',
    '1111000',
    '1111000',
    '0110110',
    '0001111',
    '0001111',
    '0000110',
  ]);
}

function stickPart(size: number, border: string, fill: string): HTMLDivElement {
  const d = document.createElement('div');
  d.hidden = true;
  d.style.cssText =
    `position:fixed;left:0;top:0;width:${size}px;height:${size}px;border-radius:50%;` +
    `border:2px solid ${border};background:${fill};pointer-events:none;box-sizing:border-box;z-index:3;`;
  return d;
}
