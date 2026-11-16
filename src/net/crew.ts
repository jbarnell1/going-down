// The browser session around the network layer: who is in the room, who is the host, names, and
// one NetHost/NetClient pair per run. It knows nothing about the DOM or three.js.
//
// Every tab runs the game the same way. The host's tab also runs NetHost; its own player is a
// NetClient joined to that host by two Pipes in the page (instant, lossless). Playing alone is
// exactly that with nobody else in the room (no transport at all). Other tabs run only a NetClient,
// whose messages travel over the real transport (BroadcastChannel or Trystero).
//
// Who hosts: the tab that pressed START A CREW (or PLAY ALONE). It puts ?room=CODE in its address
// for the others to open and remembers in sessionStorage that it hosts that code (so a reload of the
// host tab hosts again). A tab that opens a ?room= link it did not create is a client. The host
// announces itself with a lobby message every second; clients learn the host's peer id from it.
// There is no host migration: if the host leaves, the clients' session ends.
//
// On the wire every string is either `m|<json>` (this file's lobby messages) or `n<epoch>|<text>`
// (the network layer's own messages for run number <epoch>). A new run on the same crew bumps the
// epoch: the host builds a fresh NetHost and every client a fresh NetClient, so nothing of the old
// run's clock, ticks or events leaks into the new one.

import { NetClient } from './client';
import { NetHost, type HostOptions } from './host';
import { Pipe } from './pipe';
import type { PeerId } from './protocol';
import { TICK } from './session';
import type { Transport } from './transport';

/** The host's own player in its own NetHost goes through this in-page "peer" id. */
const HUB = 'hub';
/** Seconds between the host's lobby messages (also its heartbeat to the room). */
const LOBBY_EVERY = 1;
/** Seconds between a client's hellos until a host answers. */
const HELLO_EVERY = 1.5;

export type Role = 'host' | 'client';

export interface CrewPerson {
  id: string;
  name: string;
  host: boolean;
  me: boolean;
  /** In the room now. */
  here: boolean;
}

interface LobbyMsg {
  t: 'lobby';
  host: PeerId;
  epoch: number;
  names: [string, string][];
  here: string[];
}

interface HelloMsg {
  t: 'hi';
  name: string;
}

type Meta = LobbyMsg | HelloMsg | { t: 'bye' };

export type StartOptions = Pick<HostOptions, 'seed' | 'prepare' | 'step'> & { now: number };

export class CrewSession {
  readonly myId: PeerId;
  /** 0 in the lobby; run number after that. */
  epoch = 0;
  host: NetHost | null = null;
  client: NetClient | null = null;
  /** The host's peer id (this tab's own id when hosting), once known. */
  hostPeer: PeerId | null;
  /** Why the session is over, or null while it is not. */
  ended: null | 'hostLeft' = null;
  /** Local time the last message from the host arrived (clients), for the snapshot age. */
  lastFromHost = -Infinity;
  /** Local time this tab started looking for a host (clients). */
  readonly since: number;
  private readonly names = new Map<string, string>();
  private readonly here = new Set<string>();
  private hub: Pipe | null = null;
  private local: Pipe | null = null;
  private pipe: Pipe | null = null;
  private lastLobby = -Infinity;
  private lastHello = -Infinity;
  private dirty = true;
  /** A client asks to join only after JOIN; the host is always in. */
  private joined: boolean;
  /** The run the host says is in progress (clients), 0 for none. */
  private hostEpoch = 0;

  constructor(
    private readonly remote: Transport | null,
    readonly role: Role,
    private myName: string,
    now: number,
  ) {
    this.myId = remote?.self ?? 'solo';
    this.hostPeer = role === 'host' ? this.myId : null;
    this.names.set(this.myId, myName);
    this.here.add(this.myId);
    this.since = now;
    this.joined = role === 'host';
  }

  /** A client: JOIN pressed. Hellos start, and a run in progress is joined (as a watcher). */
  join(now: number): void {
    if (this.joined) return;
    this.joined = true;
    this.lastHello = -Infinity;
    if (this.hostEpoch > this.epoch) this.joinRun(this.hostEpoch, now);
  }

  get hasJoined(): boolean {
    return this.joined;
  }

  /** The run the host has going (0: still in its lobby). */
  get runningEpoch(): number {
    return this.role === 'host' ? this.epoch : this.hostEpoch;
  }

  /** No room: playing alone. */
  get isSolo(): boolean {
    return this.remote === null;
  }

  get name(): string {
    return this.myName;
  }

  setName(name: string): void {
    this.myName = name;
    this.names.set(this.myId, name);
    this.dirty = true;
    this.lastHello = -Infinity;
  }

  /** The name of a player id ('' if unknown). */
  nameOf(id: string): string {
    return this.names.get(id) ?? '';
  }

  /** Everyone the room knows of: the host first, then in order of arrival. */
  people(): CrewPerson[] {
    const out: CrewPerson[] = [];
    for (const [id, name] of this.names) out.push({ id, name, host: id === this.hostPeer, me: id === this.myId, here: this.here.has(id) });
    return out.sort((a, b) => Number(b.host) - Number(a.host));
  }

  /** Remote peers in the room now (host: its crew; client: everyone it can hear). */
  peers(): string[] {
    return [...this.here].filter((id) => id !== this.myId);
  }

  /** The host: starts a run (the first, or the next one) with everyone in the room. */
  start(opts: StartOptions): void {
    if (this.role !== 'host') throw new Error('only the host starts a run');
    this.hub?.close();
    this.client = null;
    this.epoch++;
    const epoch = this.epoch;
    const roster = [this.myId, ...this.peers().filter((id) => this.names.has(id))];
    const hub = new Pipe(
      HUB,
      (to, data) => {
        if (to === this.myId) this.local?.push(HUB, data);
        else this.remote?.send(to, `n${epoch}|${data}`);
      },
      (data) => {
        this.local?.push(HUB, data);
        this.remote?.broadcast(`n${epoch}|${data}`);
      },
    );
    this.hub = hub;
    this.local = new Pipe(this.myId, (_to, data) => hub.push(this.myId, data), (data) => hub.push(this.myId, data));
    this.host = new NetHost({ transport: hub, seed: opts.seed, roster, now: opts.now, prepare: opts.prepare, step: opts.step, trusted: [this.myId] });
    this.client = new NetClient(this.local, HUB, this.myName, opts.now, { interpDelay: TICK, inputInterval: 0 });
    this.dirty = true;
  }

  /** Takes in everything the room sent; call every frame (and between skipped ticks). */
  pump(now: number): void {
    const r = this.remote;
    if (r) {
      for (const e of r.peerEvents()) this.onPeer(e.kind, e.peer, now);
      for (const d of r.receive()) this.onData(d.from, d.data, now);
    }
    if (this.role === 'host') {
      if (this.dirty || now - this.lastLobby >= LOBBY_EVERY) this.sendLobby(null, now);
    } else if (r && this.joined && this.ended === null && (this.hostPeer === null || this.dirty) && now - this.lastHello >= HELLO_EVERY) {
      this.lastHello = now;
      this.dirty = false;
      r.broadcast(`m|${JSON.stringify({ t: 'hi', name: this.myName } satisfies HelloMsg)}`);
    }
  }

  /** Leaves the room (the page is closing, or the player left the crew). */
  close(): void {
    this.remote?.broadcast(`m|${JSON.stringify({ t: 'bye' })}`);
    this.client?.leave();
    this.host?.close();
    this.remote?.close();
  }

  // -------------------------------------------------------------------------------------------

  private sendLobby(to: PeerId | null, now: number): void {
    this.lastLobby = now;
    this.dirty = false;
    const m: LobbyMsg = { t: 'lobby', host: this.myId, epoch: this.epoch, names: [...this.names], here: [...this.here] };
    const text = `m|${JSON.stringify(m)}`;
    if (to) this.remote?.send(to, text);
    else this.remote?.broadcast(text);
  }

  private onPeer(kind: 'joined' | 'left', peer: PeerId, now: number): void {
    if (kind === 'joined') {
      this.here.add(peer);
      if (this.role === 'host') this.sendLobby(peer, now);
      else this.lastHello = -Infinity;
      return;
    }
    this.gone(peer);
  }

  private gone(peer: PeerId): void {
    if (!this.here.delete(peer)) return;
    this.dirty = true;
    if (this.role === 'host') {
      this.hub?.pushPeer({ kind: 'left', peer });
    } else if (peer === this.hostPeer) {
      this.ended = 'hostLeft';
      this.pipe?.pushPeer({ kind: 'left', peer });
    }
  }

  private onData(from: PeerId, data: string, now: number): void {
    if (data.startsWith('m|')) {
      let m: Meta;
      try {
        m = JSON.parse(data.slice(2)) as Meta;
      } catch {
        return;
      }
      this.onMeta(from, m, now);
      return;
    }
    if (data[0] !== 'n') return;
    const bar = data.indexOf('|');
    const epoch = Number(data.slice(1, bar));
    if (!(bar > 1) || epoch !== this.epoch) return;
    const text = data.slice(bar + 1);
    this.here.add(from);
    if (this.role === 'host') this.hub?.push(from, text);
    else if (from === this.hostPeer) {
      this.lastFromHost = now;
      this.pipe?.push(from, text);
    }
  }

  private onMeta(from: PeerId, m: Meta, now: number): void {
    if (m.t === 'bye') {
      this.gone(from);
      return;
    }
    if (this.role === 'host') {
      if (m.t !== 'hi') return;
      const fresh = !this.names.has(from) || this.names.get(from) !== m.name;
      this.here.add(from);
      this.names.set(from, String(m.name).slice(0, 16));
      if (fresh) this.dirty = true;
      else this.sendLobby(from, now);
      return;
    }
    if (m.t !== 'lobby' || m.host !== from || this.ended) return;
    this.hostPeer = from;
    this.lastFromHost = now;
    for (const [id, name] of m.names) if (id !== this.myId) this.names.set(id, name);
    this.here.clear();
    for (const id of m.here) this.here.add(id);
    this.here.add(this.myId);
    this.hostEpoch = m.epoch;
    if (this.joined && m.epoch > this.epoch) this.joinRun(m.epoch, now);
  }

  /** A client: the host started run `epoch` (or one is in progress when this tab arrives). */
  private joinRun(epoch: number, now: number): void {
    const hostPeer = this.hostPeer;
    if (!hostPeer || !this.remote) return;
    this.pipe?.close();
    this.epoch = epoch;
    const remote = this.remote;
    const pipe = new Pipe(
      this.myId,
      (to, data) => remote.send(to, `n${epoch}|${data}`),
      (data) => remote.send(hostPeer, `n${epoch}|${data}`),
    );
    this.pipe = pipe;
    this.client = new NetClient(pipe, hostPeer, this.myName, now);
  }
}
