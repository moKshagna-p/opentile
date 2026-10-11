export type Pairing = { v: 1; endpoint: string; key: string };
export type Touch = { id: number; x: number; y: number };
export type Packet = {
  v: 1; session: string; direction: 'phone' | 'mac'; seq: number;
  type: string; time: number; contacts?: Touch[]; resize?: boolean; message?: string;
};

export function parsePairing(text: string): Pairing {
  const value = JSON.parse(text);
  if (value?.v !== 1 || typeof value.endpoint !== 'string' || typeof value.key !== 'string') throw new Error('Scan an OpenTile pairing QR.');
  const url = new URL(value.endpoint);
  if (url.protocol !== 'wss:' || !url.hostname || url.username || url.password || url.hash || url.search || !/^[A-Za-z0-9+/]{43}=$/.test(value.key)) {
    throw new Error('This pairing is invalid. Create a new QR on your Mac.');
  }
  return { v: 1, endpoint: url.toString(), key: value.key };
}

export function validateResponse(value: unknown, session: string, previous: number): Packet {
  const packet = value as Packet;
  if (!packet || packet.v !== 1 || packet.session !== session || packet.direction !== 'mac' ||
      !Number.isSafeInteger(packet.seq) || packet.seq <= previous || !Number.isFinite(packet.time) ||
      !['ready', 'status', 'armed', 'cancelled', 'pong'].includes(packet.type) ||
      (packet.message !== undefined && (typeof packet.message !== 'string' || packet.message.length > 512))) {
    throw new Error('Connection verification failed. Pair again.');
  }
  return packet;
}

export function normalizeTouches(touches: readonly { identifier: number | string; locationX: number; locationY: number }[], width: number, height: number): Touch[] {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 || touches.length > 2) throw new Error('Lift all fingers to continue.');
  const result = touches.map(t => ({ id: Number(t.identifier), x: Math.max(0, Math.min(1, t.locationX / width)), y: 1 - Math.max(0, Math.min(1, t.locationY / height)) }));
  if (result.some(t => !Number.isSafeInteger(t.id) || t.id < 0 || t.id > 1_000_000 || !Number.isFinite(t.x) || !Number.isFinite(t.y)) || new Set(result.map(t => t.id)).size !== result.length) throw new Error('Lift all fingers to continue.');
  return result;
}
