// Virtual transports the browser glue (crew.ts) hands to NetHost and NetClient. A Pipe is one end:
// the glue pushes what arrives for it, and its sends go wherever the glue says. The host's own
// player talks to the host through two Pipes joined in the page (a perfect, instant link: what
// "playing alone" is), and every other player through the real transport behind the glue.

import type { PeerId } from './protocol';
import type { Delivered, PeerEvent, Transport } from './transport';

export class Pipe implements Transport {
  private inbox: Delivered[] = [];
  private events: PeerEvent[] = [];
  private closed = false;

  constructor(
    readonly self: PeerId,
    private readonly out: (to: PeerId, data: string) => void,
    private readonly outAll: (data: string) => void,
    private readonly onClose: () => void = () => {},
  ) {}

  /** The glue: a message for this end. */
  push(from: PeerId, data: string): void {
    if (!this.closed) this.inbox.push({ from, data });
  }

  /** The glue: a peer came or went. */
  pushPeer(e: PeerEvent): void {
    if (!this.closed) this.events.push(e);
  }

  send(to: PeerId, data: string): void {
    if (!this.closed) this.out(to, data);
  }

  broadcast(data: string): void {
    if (!this.closed) this.outAll(data);
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
    this.inbox = [];
    this.onClose();
  }
}
