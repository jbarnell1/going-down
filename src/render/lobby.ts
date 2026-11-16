// The crew menus, in the camcorder font, over the game. Short on purpose: two buttons on the start
// screen (PLAY ALONE, START A CREW); starting a crew shows its code in large letters, a link to
// share with a copy button, your name, who has joined, and GO DOWN; opening a shared link shows the
// code, your name and JOIN. The same panel tells you when the session has ended.

import { drawText, textWidth } from './pixelFont';

export interface LobbyPerson {
  name: string;
  host: boolean;
  me: boolean;
}

function pixelCanvas(text: string, scale: number, colour: string): HTMLCanvasElement {
  const c = document.createElement('canvas');
  const w = Math.max(1, textWidth(text) + 2);
  c.width = w;
  c.height = 9;
  const g = c.getContext('2d');
  if (g) {
    g.fillStyle = colour;
    drawText(g, text, 1, 1);
  }
  c.style.width = `${w * scale}px`;
  c.style.height = `${9 * scale}px`;
  c.style.imageRendering = 'pixelated';
  c.style.display = 'block';
  c.style.maxWidth = '100%';
  return c;
}

/** Characters the camcorder font can draw, for names. */
export function cleanName(s: string): string {
  return s
    .toUpperCase()
    .replace(/[^A-Z0-9 .#+\-/]/g, '')
    .replace(/\s+/g, ' ')
    .slice(0, 14)
    .trim();
}

const CSS = `
#lobby { position: fixed; inset: 0; z-index: 7; display: flex; align-items: center; justify-content: center; background: rgba(6, 9, 8, 0.94); color: #e8ece9; font: 14px ui-monospace, Consolas, monospace; overflow-y: auto; }
#lobby .panel { width: min(520px, calc(100vw - 32px)); display: flex; flex-direction: column; gap: 12px; padding: 16px 0; }
#lobby .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
#lobby .code canvas { margin: 2px 0 4px; }
#lobby .link { flex: 1 1 220px; min-width: 0; padding: 8px 10px; border: 1px solid #3c4642; background: #0f1513; color: #b9c4bf; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; user-select: text; -webkit-user-select: text; }
#lobby input { flex: 1 1 200px; min-width: 0; padding: 9px 10px; border: 1px solid #56625d; background: #0f1513; color: #ffe2a8; font: 600 16px ui-monospace, Consolas, monospace; letter-spacing: 0.08em; text-transform: uppercase; user-select: text; -webkit-user-select: text; }
#lobby button { padding: 10px 14px; border: 2px solid #9aa59f; background: #1a2320; color: #e8ece9; cursor: pointer; touch-action: manipulation; }
#lobby button.go { border-color: #ffd27a; background: #3a2c12; }
#lobby button[disabled] { opacity: 0.35; cursor: default; }
#lobby .people { display: flex; flex-direction: column; gap: 6px; min-height: 20px; }
#start { flex-direction: column; }
#start .start-buttons { display: flex; gap: 12px; justify-content: center; margin-top: 18px; flex-wrap: wrap; }
#start .start-buttons button { padding: 10px 14px; border: 2px solid #c9d2cd; background: rgba(20, 28, 25, 0.8); cursor: pointer; touch-action: manipulation; }
`;

export class Lobby {
  readonly el: HTMLDivElement;
  readonly nameInput: HTMLInputElement;
  /** Called when a button is pressed. */
  onCrew: (() => void) | null = null;
  onGoDown: (() => void) | null = null;
  onJoin: (() => void) | null = null;
  onLeave: (() => void) | null = null;
  onName: ((name: string) => void) | null = null;
  private readonly panel: HTMLDivElement;
  private readonly head: HTMLDivElement;
  private readonly codeBox: HTMLDivElement;
  private readonly linkRow: HTMLDivElement;
  private readonly link: HTMLDivElement;
  private readonly people: HTMLDivElement;
  private readonly status: HTMLDivElement;
  private readonly goBtn: HTMLButtonElement;
  private readonly joinBtn: HTMLButtonElement;
  private readonly leaveBtn: HTMLButtonElement;
  private peopleKey = '';
  private statusText = '';
  private linkText = '';

  constructor(parent: HTMLElement, start: HTMLElement) {
    const style = document.createElement('style');
    style.textContent = CSS;
    document.head.append(style);
    this.el = document.createElement('div');
    this.el.id = 'lobby';
    this.el.hidden = true;
    this.panel = document.createElement('div');
    this.panel.className = 'panel';
    this.el.append(this.panel);
    // Keys typed into the lobby are not game input.
    for (const t of ['keydown', 'keyup'] as const) this.el.addEventListener(t, (e) => e.stopPropagation());
    this.el.addEventListener('pointerdown', (e) => e.stopPropagation());

    const button = (text: string, cls: string, scale = 2): HTMLButtonElement => {
      const b = document.createElement('button');
      b.className = cls;
      b.dataset.lobby = cls;
      b.append(pixelCanvas(text, scale, '#e8ece9'));
      return b;
    };
    this.head = document.createElement('div');
    this.codeBox = document.createElement('div');
    this.codeBox.className = 'code';
    this.linkRow = document.createElement('div');
    this.linkRow.className = 'row';
    this.link = document.createElement('div');
    this.link.className = 'link';
    const copy = button('COPY LINK', 'copy');
    copy.addEventListener('click', () => {
      const done = (): void => this.setStatus('LINK COPIED');
      navigator.clipboard?.writeText(this.linkText).then(done, () => this.selectLink());
      if (!navigator.clipboard) this.selectLink();
    });
    this.linkRow.append(this.link, copy);
    const nameRow = document.createElement('div');
    nameRow.className = 'row';
    this.nameInput = document.createElement('input');
    this.nameInput.id = 'lobby-name';
    this.nameInput.maxLength = 14;
    this.nameInput.autocomplete = 'off';
    this.nameInput.spellcheck = false;
    this.nameInput.addEventListener('input', () => {
      const n = cleanName(this.nameInput.value);
      if (n) this.onName?.(n);
    });
    nameRow.append(pixelCanvas('YOUR NAME', 2, '#9aa59f'), this.nameInput);
    this.people = document.createElement('div');
    this.people.className = 'people';
    this.status = document.createElement('div');
    const buttons = document.createElement('div');
    buttons.className = 'row';
    this.goBtn = button('GO DOWN', 'go', 3);
    this.joinBtn = button('JOIN', 'go', 3);
    this.leaveBtn = button('LEAVE', 'leave');
    this.goBtn.addEventListener('click', () => this.onGoDown?.());
    this.joinBtn.addEventListener('click', () => this.onJoin?.());
    this.leaveBtn.addEventListener('click', () => this.onLeave?.());
    buttons.append(this.goBtn, this.joinBtn, this.leaveBtn);
    this.panel.append(this.head, this.codeBox, this.linkRow, nameRow, this.people, this.status, buttons);
    parent.append(this.el);

    // The start screen's two buttons. PLAY ALONE is the start screen's own click (it starts play).
    const row = document.createElement('div');
    row.className = 'start-buttons';
    const alone = button('PLAY ALONE', 'alone');
    const crew = button('START A CREW', 'crew');
    // A tap on the start screen starts play; this one must not.
    crew.addEventListener('pointerdown', (e) => e.stopPropagation());
    crew.addEventListener('click', (e) => {
      e.stopPropagation();
      this.onCrew?.();
    });
    row.append(alone, crew);
    start.append(row);
  }

  get shown(): boolean {
    return !this.el.hidden;
  }

  private selectLink(): void {
    const r = document.createRange();
    r.selectNodeContents(this.link);
    const sel = window.getSelection();
    sel?.removeAllRanges();
    sel?.addRange(r);
    this.setStatus('PRESS CTRL+C TO COPY');
  }

  private header(lines: [string, number, string][]): void {
    this.head.replaceChildren(...lines.map(([t, s, c]) => pixelCanvas(t, s, c)));
  }

  /** The host's view: the code, the link, the crew so far, GO DOWN. */
  showHost(code: string, link: string, name: string): void {
    this.header([['GOING DOWN', 3, '#ffd27a'], ['SEND THE LINK OR THE CODE', 2, '#9aa59f']]);
    this.codeBox.replaceChildren(pixelCanvas(code, 8, '#ffe2a8'));
    this.linkText = link;
    this.link.textContent = link;
    this.linkRow.hidden = false;
    this.nameInput.value = name;
    this.goBtn.hidden = false;
    this.joinBtn.hidden = true;
    this.leaveBtn.hidden = false;
    this.el.hidden = false;
  }

  /** A shared link opened: the code, your name, JOIN. */
  showJoin(code: string, name: string): void {
    this.header([['GOING DOWN', 3, '#ffd27a'], ['JOINING CREW', 2, '#9aa59f']]);
    this.codeBox.replaceChildren(pixelCanvas(code, 8, '#ffe2a8'));
    this.linkRow.hidden = true;
    this.nameInput.value = name;
    this.goBtn.hidden = true;
    this.joinBtn.hidden = false;
    this.joinBtn.disabled = false;
    this.leaveBtn.hidden = false;
    this.el.hidden = false;
  }

  /** The session is over: one plain message and a way to start again. */
  showEnded(text: string, again: string): void {
    this.header([['GOING DOWN', 3, '#ffd27a']]);
    this.codeBox.replaceChildren(pixelCanvas(text, 2, '#e8ece9'));
    this.linkRow.hidden = true;
    this.people.replaceChildren();
    this.peopleKey = '';
    this.goBtn.hidden = true;
    this.joinBtn.hidden = true;
    this.leaveBtn.hidden = false;
    this.leaveBtn.replaceChildren(pixelCanvas(again, 2, '#e8ece9'));
    (this.nameInput.parentElement as HTMLElement).hidden = true;
    this.setStatus('');
    this.el.hidden = false;
  }

  joined(): void {
    this.joinBtn.disabled = true;
  }

  setCanGo(on: boolean): void {
    this.goBtn.disabled = !on;
  }

  setPeople(list: readonly LobbyPerson[]): void {
    const key = list.map((p) => `${p.name}|${p.host}|${p.me}`).join(',');
    if (key === this.peopleKey) return;
    this.peopleKey = key;
    this.people.replaceChildren(
      pixelCanvas(`CREW ${list.length}/4`, 2, '#9aa59f'),
      ...list.map((p) => pixelCanvas(`${p.host ? '> ' : '  '}${p.name || '...'}${p.me ? ' < YOU' : ''}`, 2, p.me ? '#ffe2a8' : '#e8ece9')),
    );
  }

  setStatus(text: string): void {
    if (text === this.statusText) return;
    this.statusText = text;
    this.status.replaceChildren(...(text ? text.split('\n').map((t) => pixelCanvas(t, 2, '#c9d2cd')) : []));
  }

  get statusLine(): string {
    return this.statusText;
  }

  hide(): void {
    this.el.hidden = true;
  }
}
