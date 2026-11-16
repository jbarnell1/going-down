// The real peer-to-peer Transport: WebRTC data channels between the players' browsers, set up by
// Trystero over public Nostr relays (they only introduce the peers; game traffic goes directly
// between them). No accounts, keys or servers of ours. The app id names this game and the room id
// carries the wire namespace, so different builds never meet in one room.
//
// Loaded on demand (playing alone never downloads it). open() resolves once this peer knows its
// own id; peers arrive later, as the signalling finds them, or never (the lobby says so).

import { NET_NAMESPACE } from './broadcastTransport';
import type { PeerId } from './protocol';
import type { Delivered, PeerEvent, Transport } from './transport';

export const APP_ID = 'going-down-coop-horror';

type TrysteroRoom = import('trystero').Room;

export class TrysteroTransport implements Transport {
  private inbox: Delivered[] = [];
  private events: PeerEvent[] = [];
  private readonly peers = new Set<PeerId>();
  private closed = false;
  /** Signalling or connection problems, newest last (shown in the lobby, read by tests). */
  readonly errors: string[] = [];

  private constructor(
    readonly self: PeerId,
    private readonly room: TrysteroRoom,
    private readonly sendRaw: (data: string, target: PeerId | null) => Promise<void>,
  ) {}

  static async open(code: string): Promise<TrysteroTransport> {
    const { joinRoom } = await import('trystero');
    const room = joinRoom({ appId: APP_ID, identity: 'none', relayConfig: { warnOnRelayFailure: false } }, `${NET_NAMESPACE}/${code}`);
    const action = room.makeAction<string>('gd');
    const me = await room.getSelf();
    const t = new TrysteroTransport(me.peerId, room, (data, target) => action.send(data, target ? { target } : {}));
    action.onMessage((data, ctx) => {
      if (!t.closed && typeof data === 'string') t.inbox.push({ from: ctx.peerId, data });
    });
    room.onPeerJoin(({ peerId }) => {
      if (t.closed || t.peers.has(peerId)) return;
      t.peers.add(peerId);
      t.events.push({ kind: 'joined', peer: peerId });
    });
    room.onPeerLeave(({ peerId }) => {
      if (t.closed || !t.peers.delete(peerId)) return;
      t.events.push({ kind: 'left', peer: peerId });
    });
    room.onError((e) => {
      t.errors.push(e.code);
      if (t.errors.length > 20) t.errors.shift();
    });
    return t;
  }

  /** Peers connected now. */
  connected(): number {
    return this.peers.size;
  }

  send(to: PeerId, data: string): void {
    if (this.closed || !this.peers.has(to)) return;
    this.sendRaw(data, to).catch(() => {});
  }

  broadcast(data: string): void {
    if (this.closed || this.peers.size === 0) return;
    this.sendRaw(data, null).catch(() => {});
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
    this.closed = true;
    this.room.leave().catch(() => {});
  }
}
