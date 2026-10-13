import { test } from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { AESEncryptionKey, AESSealedData, aesEncryptAsync, aesDecryptAsync, holdEncryption } from './cryptoMock.ts';

registerHooks({ resolve(specifier, context, next) {
  if (specifier === 'expo-crypto') return { url: new URL('./cryptoMock.ts', import.meta.url).href, shortCircuit: true };
  if (specifier === './protocol' && context.parentURL?.endsWith('/PadConnection.ts')) {
    return { url: new URL('../src/protocol.ts', import.meta.url).href, shortCircuit: true };
  }
  return next(specifier, context);
} });
const { PadConnection } = await import('../src/PadConnection.ts');

class Socket {
  static OPEN = 1;
  static latest: Socket;
  readyState = 1;
  bufferedAmount = 0;
  sent: string[] = [];
  onmessage?: (event: { data: string }) => void;
  onclose?: () => void;
  constructor(_url: string) { Socket.latest = this; }
  send(data: string) { this.sent.push(data); }
  close() { this.readyState = 3; this.onclose?.(); }
  message(data: string) { this.onmessage?.({ data }); }
}
globalThis.WebSocket = Socket as unknown as typeof WebSocket;
const pairing = { v: 1 as const, endpoint: 'wss://pad.example.com', key: Buffer.alloc(32, 7).toString('base64') };
const key = await AESEncryptionKey.import(pairing.key);
const session = 'test-session-challenge';
async function waitFor(condition: () => boolean) {
  const deadline = Date.now() + 1000;
  while (!condition() && Date.now() < deadline) await new Promise<void>(resolve => setImmediate(resolve));
  assert.ok(condition(), 'Transport did not reach the expected state');
}
async function decode(data: string) {
  return JSON.parse((await aesDecryptAsync(AESSealedData.fromCombined(Buffer.from(data, 'base64')), key)).toString());
}
async function authenticated(onInputReset = () => {}, onFeedback = (_packet: unknown) => {}) {
  let ready = false;
  const connection = new PadConnection(pairing, (_, value) => { ready = value; }, onFeedback, onInputReset);
  await connection.connect();
  const socket = Socket.latest;
  socket.message(JSON.stringify({ v: '1', session }));
  await waitFor(() => socket.sent.length === 1);
  const hello = await decode(socket.sent[0]);
  assert.equal(hello.type, 'hello');
  assert.equal(hello.direction, 'phone');
  assert.equal(hello.seq, 0);
  const sealed = await aesEncryptAsync(new TextEncoder().encode(JSON.stringify({ v: 1, session, direction: 'mac', seq: 0, type: 'ready', time: 1 })), key);
  socket.message(await sealed.combined());
  await waitFor(() => ready);
  return { connection, socket };
}

test('Android byte-only sealed-data API authenticates the encrypted Mac response', async () => {
  const { connection, socket } = await authenticated();
  try {
    assert.equal(socket.readyState, Socket.OPEN);
  } finally { connection.close(); }
});

test('cancel discards a touch frame whose encryption is still in flight', async () => {
  const { connection, socket } = await authenticated();
  const release = holdEncryption();
  try {
    connection.frame([{ id: 1, x: 0.5, y: 0.5 }], false);
    connection.cancel();
    release();
    await waitFor(() => socket.sent.length >= 3);
    const packets = await Promise.all(socket.sent.slice(1).map(decode));
    assert.deepEqual(packets.map(packet => packet.type), ['cancel', 'frame']);
    assert.deepEqual(packets[1].contacts, []);
  } finally { release(); connection.close(); }
});

test('closing a connection prevents input finishing encryption from being sent', async () => {
  const { connection, socket } = await authenticated();
  const release = holdEncryption();
  connection.frame([{ id: 1, x: 0.5, y: 0.5 }], false);
  connection.close();
  release();
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(socket.sent.length, 1);
  assert.equal(socket.readyState, 3);
});

test('backpressure disconnects before it accumulates input', async () => {
  const { connection, socket } = await authenticated();
  try {
    socket.bufferedAmount = 16385;
    connection.frame([{ id: 1, x: 0.5, y: 0.5 }], false);
    assert.equal(socket.readyState, 3);
    assert.equal(socket.sent.length, 1);
  } finally { connection.close(); }
});


test('a burst of movement coalesces while encryption is busy instead of disconnecting', async () => {
  const { connection, socket } = await authenticated();
  const release = holdEncryption();
  try {
    for (let i = 0; i < 100; i++) connection.frame([{ id: 1, x: i / 100, y: 0.5 }], false);
    assert.equal(socket.readyState, Socket.OPEN);
    release();
    await waitFor(() => socket.sent.length === 3);
    const frames = await Promise.all(socket.sent.slice(1).map(decode));
    assert.equal(frames[0].contacts[0].x, 0);
    assert.equal(frames[1].contacts[0].x, 0.99);
  } finally { release(); connection.close(); }
});

test('coalescing preserves finger lifts and new contact sequences', async () => {
  const { connection, socket } = await authenticated();
  const release = holdEncryption();
  try {
    connection.frame([{ id: 1, x: 0.1, y: 0.5 }], false);
    connection.frame([{ id: 1, x: 0.2, y: 0.5 }], false);
    connection.frame([], false);
    connection.frame([{ id: 2, x: 0.3, y: 0.5 }], false);
    connection.frame([{ id: 2, x: 0.4, y: 0.5 }], false);
    release();
    await waitFor(() => socket.sent.length === 6);
    const frames = await Promise.all(socket.sent.slice(1).map(decode));
    assert.deepEqual(frames.map(packet => packet.contacts), [
      [{ id: 1, x: 0.1, y: 0.5 }], [{ id: 1, x: 0.2, y: 0.5 }], [],
      [{ id: 2, x: 0.3, y: 0.5 }], [{ id: 2, x: 0.4, y: 0.5 }],
    ]);
  } finally { release(); connection.close(); }
});


test('a delayed encryption cancels input without closing the authenticated connection', async () => {
  let resets = 0;
  const { connection, socket } = await authenticated(() => { resets++; });
  const release = holdEncryption();
  try {
    connection.frame([{ id: 1, x: 0.5, y: 0.5 }], false);
    await new Promise(resolve => setTimeout(resolve, 300));
    release();
    await waitFor(() => socket.sent.length >= 3 || socket.readyState === 3);
    assert.equal(socket.readyState, Socket.OPEN);
    const packets = await Promise.all(socket.sent.slice(1).map(decode));
    assert.deepEqual(packets.map(packet => packet.type), ['cancel', 'frame']);
    assert.deepEqual(packets[1].contacts, []);
    assert.equal(resets, 1);
  } finally { release(); connection.close(); }
});

test('heartbeat tolerates a brief tunnel gap but still closes a dead connection', async t => {
  let time = 0;
  t.mock.method(performance, 'now', () => time * 1000);
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { connection, socket } = await authenticated();
  try {
    time = 4;
    t.mock.timers.tick(4000);
    assert.equal(socket.readyState, Socket.OPEN);
    time = 11;
    t.mock.timers.tick(7000);
    assert.equal(socket.readyState, 3);
  } finally { connection.close(); }
});


test('Mac cancellation acknowledges a fresh lift even when the phone pump has stopped', async () => {
  let cancelled = false;
  const { connection, socket } = await authenticated(() => {}, packet => {
    if ((packet as { type: string }).type === 'cancelled') cancelled = true;
  });
  const release = holdEncryption();
  try {
    connection.frame([{ id: 1, x: 0.5, y: 0.5 }], false);
    connection.frame([], false); // This release is still queued behind encryption.
    const sealed = await aesEncryptAsync(new TextEncoder().encode(JSON.stringify({
      v: 1, session, direction: 'mac', seq: 1, type: 'cancelled', time: 2,
    })), key);
    socket.message(await sealed.combined());
    await waitFor(() => cancelled);
    release();
    await waitFor(() => socket.sent.length >= 2);
    const packets = await Promise.all(socket.sent.slice(1).map(decode));
    assert.deepEqual(packets.map(packet => packet.type), ['frame']);
    assert.deepEqual(packets[0].contacts, []);
    assert.equal(socket.readyState, Socket.OPEN);
  } finally { release(); connection.close(); }
});
