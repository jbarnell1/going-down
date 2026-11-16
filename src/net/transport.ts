// What a transport must provide, and an in-memory one for tests. Transports move opaque strings
// (protocol.ts makes them); they promise nothing about delivery: messages may be late, lost,
// reordered or duplicated, and the host and clients are written to cope.
//
// The in-memory network runs on an explicit clock (`now`, seconds, set by the test) and draws every
// delay, loss, duplicate and reordering from seeded generators, one per link, so the same seed and
// the same sends give the same deliveries. Browser transports (WebRTC, WebSocket) live elsewhere.

import { hashSeed, makeRng, type Rng } from '../sim/rng';
import type { PeerId } from './protocol';

export interface Delivered {
  from: PeerId;
  data: string;
}

export interface PeerEvent {
  kind: 'joined' | 'left';
  peer: PeerId;
}

export interface Transport {
  readonly self: PeerId;
  /** Sends to one peer (dropped silently if it is not connected). */
  send(to: PeerId, data: string): void;
  /** Sends to every other connected peer. */
  broadcast(data: string): void;
  /** Messages that have arrived since the last call, in arrival order. */
  receive(): Delivered[];
  /** Peers that joined or left since the last call. */
  peerEvents(): PeerEvent[];
  /** Leaves the network. */
  close(): void;
}

/** One direction of one link. */
export interface LinkConfig {
  /** Base one-way delay, seconds. */
  delay: number;
  /** Extra delay drawn uniformly from [0, jitter] per message, seconds. */
  jitter: number;
  /** Chance a message is lost. */
  loss: number;
  /** Chance a message is held back an extra [0, reorderDelay] seconds (so later ones overtake it). */
  reorder: number;
  reorderDelay: number;
  /** Chance a message is delivered twice (the copy with its own delay). */
  duplicate: number;
}

export const PERFECT_LINK: LinkConfig = { delay: 0, jitter: 0, loss: 0, reorder: 0, reorderDelay: 0, duplicate: 0 };

interface InFlight {
  at: number;
  n: number;
  from: PeerId;
  data: string;
}

export interface LinkStats {
  sent: number;
  bytes: number;
  lost: number;
  duplicated: number;
}

/** A simulated network of peers on an explicit clock. */
export class MemoryNetwork {
  /** The network clock, seconds. Set it, then let peers receive. */
  now = 0;
  private readonly peers = new Map<PeerId, MemoryTransport>();
  private readonly links = new Map<string, LinkConfig>();
  private readonly rngs = new Map<string, Rng>();
  private readonly queues = new Map<PeerId, InFlight[]>();
  private n = 0;
  readonly stats = new Map<string, LinkStats>();
  /** A running hash of every message sent (sender, receiver, time, text): equal streams give equal hashes. */
  streamHash = 2166136261;

  constructor(
    readonly seed: string,
    private readonly defaults: LinkConfig = PERFECT_LINK,
  ) {}

  /** Configures the link from `a` to `b` (one direction). */
  setLink(a: PeerId, b: PeerId, cfg: Partial<LinkConfig>): void {
    this.links.set(`${a}>${b}`, { ...this.link(a, b), ...cfg });
  }

  link(a: PeerId, b: PeerId): LinkConfig {
    return this.links.get(`${a}>${b}`) ?? this.defaults;
  }

  /** Joins a peer to the network. */
  connect(id: PeerId): MemoryTransport {
    if (this.peers.has(id)) throw new Error(`peer ${id} already connected`);
    const t = new MemoryTransport(this, id);
    for (const other of this.peers.values()) {
      other.pushPeer({ kind: 'joined', peer: id });
      t.pushPeer({ kind: 'joined', peer: other.self });
    }
    this.peers.set(id, t);
    this.queues.set(id, []);
    return t;
  }

  disconnect(id: PeerId): void {
    if (!this.peers.delete(id)) return;
    this.queues.delete(id);
    for (const other of this.peers.values()) other.pushPeer({ kind: 'left', peer: id });
  }

  connected(id: PeerId): boolean {
    return this.peers.has(id);
  }

  peerIds(): PeerId[] {
    return [...this.peers.keys()];
  }

  /** Earliest time something is due to arrive, or null. */
  nextDelivery(): number | null {
    let best: number | null = null;
    for (const q of this.queues.values()) for (const m of q) if (best === null || m.at < best) best = m.at;
    return best;
  }

  private rng(key: string): Rng {
    let r = this.rngs.get(key);
    if (!r) {
      r = makeRng(hashSeed(`${this.seed}|${key}`));
      this.rngs.set(key, r);
    }
    return r;
  }

  /** @internal */
  post(from: PeerId, to: PeerId, data: string): void {
    const q = this.queues.get(to);
    if (!q) return;
    const key = `${from}>${to}`;
    const cfg = this.link(from, to);
    const rng = this.rng(key);
    let st = this.stats.get(key);
    if (!st) {
      st = { sent: 0, bytes: 0, lost: 0, duplicated: 0 };
      this.stats.set(key, st);
    }
    st.sent++;
    st.bytes += data.length;
    const text = `${from}>${to}@${this.now.toFixed(6)}:${data}`;
    for (let i = 0; i < text.length; i++) this.streamHash = Math.imul(this.streamHash ^ text.charCodeAt(i), 16777619) >>> 0;
    // Draw everything for this message up front, whatever happens, so one outcome never shifts the next.
    const lost = rng.next() < cfg.loss;
    const dup = rng.next() < cfg.duplicate;
    const d1 = this.drawDelay(rng, cfg);
    const d2 = this.drawDelay(rng, cfg);
    if (lost) {
      st.lost++;
      return;
    }
    q.push({ at: this.now + d1, n: this.n++, from, data });
    if (dup) {
      st.duplicated++;
      q.push({ at: this.now + d2, n: this.n++, from, data });
    }
  }

  private drawDelay(rng: Rng, cfg: LinkConfig): number {
    const j = rng.next() * cfg.jitter;
    const r = rng.next() < cfg.reorder ? rng.next() * cfg.reorderDelay : 0;
    return Math.max(0, cfg.delay + j + r);
  }

  /** @internal Everything for `to` due by now, in arrival order. */
  take(to: PeerId): Delivered[] {
    const q = this.queues.get(to);
    if (!q || q.length === 0) return [];
    const due: InFlight[] = [];
    const rest: InFlight[] = [];
    for (const m of q) (m.at <= this.now + 1e-12 ? due : rest).push(m);
    if (due.length === 0) return [];
    this.queues.set(to, rest);
    due.sort((a, b) => a.at - b.at || a.n - b.n);
    return due.map((m) => ({ from: m.from, data: m.data }));
  }
}

export class MemoryTransport implements Transport {
  private events: PeerEvent[] = [];
  private closed = false;

  constructor(
    private readonly net: MemoryNetwork,
    readonly self: PeerId,
  ) {}

  /** @internal */
  pushPeer(e: PeerEvent): void {
    this.events.push(e);
  }

  send(to: PeerId, data: string): void {
    if (this.closed || to === this.self) return;
    this.net.post(this.self, to, data);
  }

  broadcast(data: string): void {
    if (this.closed) return;
    for (const p of this.net.peerIds()) if (p !== this.self) this.net.post(this.self, p, data);
  }

  receive(): Delivered[] {
    if (this.closed) return [];
    return this.net.take(this.self);
  }

  peerEvents(): PeerEvent[] {
    const out = this.events;
    this.events = [];
    return out;
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.net.disconnect(this.self);
  }
}
