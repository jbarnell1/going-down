// The mouse lock, behind one small interface. A real player gets the browser's pointer lock. A page
// driven by test automation (navigator.webdriver) gets a stand-in instead: the browser's lock is
// never asked for, because Chrome on Windows then confines the real cursor of whoever owns the
// machine to the hidden test window. The stand-in behaves like the real lock for the game's code:
// asking for it "locks" (a pointerlockchange event follows, as with the real one), Esc releases it,
// and mouse movement still turns the view (the game reads movementX/Y either way, which synthetic
// test mouse moves carry). `?reallock=1` forces the real lock for one deliberate test.

export interface PointerLock {
  /** True when this is the stand-in (automation without ?reallock=1). */
  readonly standIn: boolean;
  /** Asks for the lock on `el`. A refusal is not an error. */
  request(el: Element): void;
  /** Gives the lock back, if held. */
  exit(): void;
  /** The element holding the lock, or null. */
  element(): Element | null;
}

/** Whether this page should use the stand-in: driven by automation and not told to use the real lock. */
export function wantsStandIn(webdriver: boolean, search: string): boolean {
  return webdriver && new URLSearchParams(search).get('reallock') !== '1';
}

export function makePointerLock(doc: Document = document): PointerLock {
  const webdriver = typeof navigator !== 'undefined' && navigator.webdriver === true;
  if (!wantsStandIn(webdriver, typeof location === 'undefined' ? '' : location.search)) return realLock(doc);
  return standInLock(doc);
}

function realLock(doc: Document): PointerLock {
  return {
    standIn: false,
    request(el) {
      try {
        // Some browsers return a promise that rejects when the lock is refused; that is not an error.
        const req = (el as HTMLElement).requestPointerLock() as unknown;
        if (req instanceof Promise) req.catch(() => undefined);
      } catch { /* no pointer lock on this device */ }
    },
    exit() {
      doc.exitPointerLock?.();
    },
    element() {
      return doc.pointerLockElement;
    },
  };
}

function standInLock(doc: Document): PointerLock {
  let held: Element | null = null;
  // Like the real lock, the change is announced after the call returns, not inside it.
  const announce = () => queueMicrotask(() => doc.dispatchEvent(new Event('pointerlockchange')));
  const lock: PointerLock = {
    standIn: true,
    request(el) {
      if (held === el) return;
      held = el;
      announce();
    },
    exit() {
      if (held === null) return;
      held = null;
      announce();
    },
    element() {
      return held;
    },
  };
  // The browser releases a real lock on Esc before the page hears the key; so does the stand-in.
  doc.defaultView?.addEventListener('keydown', (e) => { if (e.code === 'Escape') lock.exit(); }, { capture: true });
  return lock;
}
