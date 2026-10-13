import { AESEncryptionKey, AESSealedData, aesEncryptAsync, aesDecryptAsync } from 'expo-crypto';
import { parsePairing, validateResponse } from './protocol';
import type { Packet, Pairing, Touch } from './protocol';

type Pending = { type: string; time: number; contacts?: Touch[]; resize?: boolean };
const now = () => performance.now() / 1000;

export class PadConnection {
  private socket?: WebSocket;
  private key?: AESEncryptionKey;
  private session = '';
  private sequence = 0;
  private received = -1;
  private ready = false;
  private closed = false;
  private queue: Pending[] = [];
  private sending = false;
  private inFlight?: Pending;
  private sendGeneration = 0;
  private receiving = Promise.resolve();
  private incoming = 0;
  private heartbeat?: ReturnType<typeof setInterval>;
  private lastResponse = now();
  constructor(private pairing: Pairing, private onStatus: (message: string, ready: boolean) => void, private onFeedback: (packet: Packet) => void, private onInputReset: () => void = () => {}) {}

  async connect() {
    try {
      this.pairing = parsePairing(JSON.stringify(this.pairing));
      this.key = await AESEncryptionKey.import(this.pairing.key, 'base64');
      if (this.closed) return;
      const socket = new WebSocket(this.pairing.endpoint);
      this.socket = socket;
      this.onStatus('Connecting to your Mac…', false);
      socket.onmessage = event => {
        if (this.closed) return;
        if (typeof event.data !== 'string' || event.data.length > 24576 || ++this.incoming > 8) {
          this.close('Connection overloaded. Reconnect.'); return;
        }
        this.receiving = this.receiving.then(() => this.receive(event.data)).catch(() => {
          this.close('Connection verification failed. Create a new pairing on your Mac.');
        }).finally(() => { this.incoming--; });
      };
      socket.onerror = () => this.close('Cannot reach your Mac. Check the tunnel and reconnect.');
      socket.onclose = () => this.close('Disconnected. Reconnect when your Mac is ready.');
      this.heartbeat = setInterval(() => {
        if (now() - this.lastResponse > (this.ready ? 10 : 8)) this.close('Connection timed out. Reconnect.');
        else if (this.ready) this.enqueue({ type: 'ping', time: now() });
      }, 1000);
    } catch { this.close('Pairing could not be opened. Scan a new QR on your Mac.'); }
  }

  private async receive(data: string) {
    if (this.closed || !this.key) return;
    if (!this.session) {
      const challenge = JSON.parse(data);
      if (challenge?.v !== '1' || typeof challenge.session !== 'string' || challenge.session.length > 64 || challenge.session.length < 16) throw new Error('Invalid challenge');
      this.session = challenge.session;
      this.enqueue({ type: 'hello', time: now() });
      return;
    }
    // Android's native fromCombined requires bytes, despite Expo's broader type.
    const bytes = Uint8Array.from(atob(data), character => character.charCodeAt(0));
    const plain = await aesDecryptAsync(AESSealedData.fromCombined(bytes), this.key);
    if (this.closed) return;
    const packet = validateResponse(JSON.parse(new TextDecoder().decode(plain)), this.session, this.received);
    if (!this.ready && (packet.type !== 'ready' || packet.seq !== 0)) throw new Error('Missing authentication');
    this.received = packet.seq;
    this.lastResponse = now();
    if (packet.type === 'ready') {
      this.ready = true;
      this.onStatus('Connected to your Mac', true);
    }
    if (packet.type === 'cancelled') {
      // A release may itself have been delayed. Acknowledge the reset even if
      // the UI stopped pumping after lift, and discard movement still encrypting.
      this.sendGeneration++;
      this.queue = [];
      this.frame([], false);
    }
    this.onFeedback(packet);
  }

  frame(contacts: Touch[], resize: boolean) {
    if (this.ready) this.enqueue({ type: 'frame', time: now(), contacts, resize });
  }

  cancel() {
    if (!this.ready) return;
    // Invalidate movement already being encrypted as well as queued input.
    this.sendGeneration++;
    this.queue = [];
    this.enqueue({ type: 'cancel', time: now() });
    this.frame([], false);
  }

  private enqueue(message: Pending) {
    if (this.closed || !this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    if (this.socket.bufferedAmount > 16384) { this.close('Connection is too slow. Reconnect.'); return; }
    const last = this.queue[this.queue.length - 1];
    const previous = this.queue[this.queue.length - 2] ?? this.inFlight;
    const sameContacts = (a: Pending | undefined, b: Pending) => a?.type === 'frame' && b.type === 'frame' &&
      a.resize === b.resize && a.contacts?.length === b.contacts?.length &&
      a.contacts!.every(touch => b.contacts!.some(other => other.id === touch.id));
    // Keep contact transitions (including lifts and pinch starts), but replace
    // redundant movement with the latest sample while native encryption runs.
    if (last && ((sameContacts(last, message) && sameContacts(previous, last)) ||
        (last.type === 'ping' && message.type === 'ping'))) this.queue[this.queue.length - 1] = message;
    else this.queue.push(message);
    if (this.queue.length > 8) { this.close('Connection is too slow. Reconnect.'); return; }
    void this.flush();
  }

  private async flush() {
    if (this.sending || this.closed || !this.key) return;
    this.sending = true;
    try {
      while (this.queue.length && !this.closed) {
        const next = this.queue.shift()!;
        this.inFlight = next;
        const generation = this.sendGeneration;
        if (next.type === 'frame' && now() - next.time > 0.25) { this.resetDelayedInput(); continue; }
        const packet: Packet = { v: 1, session: this.session, direction: 'phone', seq: this.sequence++, ...next };
        const sealed = await aesEncryptAsync(new TextEncoder().encode(JSON.stringify(packet)), this.key);
        const data = await sealed.combined('base64');
        if (this.closed) return;
        if (generation !== this.sendGeneration) continue;
        if (next.type === 'frame' && now() - next.time > 0.25) { this.resetDelayedInput(); continue; }
        this.socket?.send(data);
      }
    } catch { this.close('Connection is too slow. Lift your fingers and reconnect.'); }
    finally { this.sending = false; this.inFlight = undefined; }
  }

  private resetDelayedInput() {
    this.cancel();
    if (this.closed) return;
    this.onInputReset();
    this.onStatus('Connected — delay cancelled input. Lift all fingers to continue.', true);
  }

  close(message = 'Disconnected') {
    if (this.closed) return;
    this.closed = true;
    this.ready = false;
    this.queue = [];
    this.key = undefined;
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.socket?.close();
    this.socket = undefined;
    this.onStatus(message, false);
  }
}
