import type { Touch } from './protocol';

export class PadFrames {
  private contacts: Touch[] = [];
  private resize = false;
  private frame: number | null = null;
  private sentSinceTick = false;
  private lastTouchTime = 0;

  constructor(private send: (contacts: Touch[], resize: boolean) => void) {}

  update(contacts: Touch[], resize: boolean) {
    this.contacts = contacts;
    this.resize = resize;
    this.sentSinceTick = true;
    this.lastTouchTime = performance.now();
    this.send(contacts, resize);
    if (!contacts.length) this.stop();
    else this.schedule();
  }

  private pump = () => {
    this.frame = null;
    if (!this.contacts.length) return;
    // Touch events already sent this tick's input; keep polling only for held contacts.
    if (!this.sentSinceTick || performance.now() - this.lastTouchTime >= 1000 / 60) {
      this.send(this.contacts, this.resize);
    }
    this.sentSinceTick = false;
    this.schedule();
  };

  private schedule() {
    if (this.contacts.length && this.frame === null) this.frame = requestAnimationFrame(this.pump);
  }

  stop() {
    if (this.frame !== null) cancelAnimationFrame(this.frame);
    this.frame = null;
    this.contacts = [];
    this.sentSinceTick = false;
  }
}
