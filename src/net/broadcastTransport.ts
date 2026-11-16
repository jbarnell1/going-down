// A Transport between tabs of one browser on one machine (testing a crew on one PC, ?net=local):
// a BroadcastChannel per room. No internet, no server. Every tab announces itself when it opens and
// every second after; a tab silent for PEER_TIMEOUT seconds (or one that says goodbye on closing) has
// left. Messages carry their sender and, when sent to one peer, their addressee; the channel itself
// reaches every tab of the room, which drops what is not for it.

import type { PeerId } from './protocol';
import type { Delivered, PeerEvent, Transport } from './transport';

/** Bumped when the wire changes, so tabs of different builds never share a channel. */
export const NET_NAMESPACE = 'going-down/net1';
const HEARTBEAT_MS = 1000;
const PEER_TIMEOUT_MS = 5000;

type Wire = { k: 'hi' | 'hb' | 'bye'; from: PeerId } | { k: 'd'; from: PeerId; to: PeerId | null; data: string };

export function randomPeerId(): PeerId {
  const a = new Uint8Array(6);
  crypto.getRandomValues(a);
  return [...a].map((b) => b.toString(36).padStart(2, '0')).join('').slice(0, 10);
}

export class BroadcastTransport implements Transport {
  readonly self: PeerId = randomPeerId();
  private readonly ch: BroadcastChannel;
  private inbox: Delivered[] = [];
  private events: PeerEvent[] = [];
  private readonly seen = new Map<PeerId, number>();
  private readonly timer: ReturnType<typeof setInterval>;
  private closed = false;

  constructor(room: string) {
    this.ch = new BroadcastChannel(`${NET_NAMESPACE}/${room}`);
    this.ch.onmessage = (e: MessageEvent<Wire>) => this.onWire(e.data);
    this.post({ k: 'hi', from: this.self });
    this.timer = setInterval(() => this.beat(), HEARTBEAT_MS);
  }

  private post(w: Wire): void {
    if (!this.closed) this.ch.postMessage(w);
  }

  private beat(): void {
    this.post({ k: 'hb', from: this.self });
    const now = performance.now();
    for (const [p, at] of this.seen) {
      if (now - at > PEER_TIMEOUT_MS) {
        this.seen.delete(p);
        this.events.push({ kind: 'left', peer: p });
      }
    }
  }

  private onWire(w: Wire): void {
    if (this.closed || !w || w.from === this.self) return;
    if (w.k === 'bye') {
      if (this.seen.delete(w.from)) this.events.push({ kind: 'left', peer: w.from });
      return;
    }
    if (!this.seen.has(w.from)) {
      this.events.push({ kind: 'joined', peer: w.from });
      // A newcomer: answer at once so it need not wait a heartbeat to learn of us.
      if (w.k === 'hi') this.post({ k: 'hb', from: this.self });
    }
    this.seen.set(w.from, performance.now());
    if (w.k === 'd' && (w.to === null || w.to === this.self)) this.inbox.push({ from: w.from, data: w.data });
  }

  send(to: PeerId, data: string): void {
    if (to !== this.self && this.seen.has(to)) this.post({ k: 'd', from: this.self, to, data });
  }

  broadcast(data: string): void {
    this.post({ k: 'd', from: this.self, to: null, data });
  }

  receive(): Delivered[] {
    const r = this.inbox;
    this.inbox = [];
    return r;
  }

  peerEvents(): PeerEvent[] {
    const r = this.events;
    this.events = [];
    return r;
  }

  close(): void {
    if (this.closed) return;
    this.post({ k: 'bye', from: this.self });
    this.closed = true;
    clearInterval(this.timer);
    this.ch.close();
  }
}
