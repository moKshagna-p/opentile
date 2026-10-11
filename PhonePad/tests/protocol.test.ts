import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parsePairing, validateResponse, normalizeTouches } from '../src/protocol.ts';

const pairing = { v: 1, endpoint: 'wss://pad.example.com', key: Buffer.alloc(32).toString('base64') };
test('pairing accepts Android and iPhone endpoint format and rejects unsafe URLs', () => {
  assert.equal(parsePairing(JSON.stringify(pairing)).endpoint, 'wss://pad.example.com/');
  for (const endpoint of ['ws://pad.example.com', 'https://pad.example.com', 'wss://a:b@pad.example.com', 'wss://pad.example.com#key', 'wss://pad.example.com?key=x']) {
    assert.throws(() => parsePairing(JSON.stringify({ ...pairing, endpoint })));
  }
  for (const value of [null, {}, { ...pairing, key: 'short' }, { ...pairing, v: 2 }]) assert.throws(() => parsePairing(JSON.stringify(value)));
});
test('authenticated responses reject reflection, replay, old sessions, and bad sequences', () => {
  const packet = { v: 1, session: 's', direction: 'mac', seq: 1, type: 'armed', time: 12 };
  assert.equal(validateResponse(packet, 's', 0).type, 'armed');
  for (const invalid of [null, { ...packet, direction: 'phone' }, { ...packet, seq: 0 }, { ...packet, seq: 1.5 }, { ...packet, session: 'old' }, { ...packet, time: NaN }, { ...packet, type: 'frame' }]) {
    assert.throws(() => validateResponse(invalid, 's', 0));
  }
});
test('touch coordinates match the upward-positive trackpad space and stay within bounds', () => {
  assert.deepEqual(normalizeTouches([{ identifier: 3, locationX: 50, locationY: 25 }], 100, 100), [{ id: 3, x: 0.5, y: 0.75 }]);
  assert.deepEqual(normalizeTouches([{ identifier: 3, locationX: -5, locationY: 120 }], 100, 100), [{ id: 3, x: 0, y: 0 }]);
  assert.deepEqual(normalizeTouches([{ identifier: '3', locationX: 50, locationY: 25 }], 100, 100), [{ id: 3, x: 0.5, y: 0.75 }]);
  assert.throws(() => normalizeTouches([], 0, 1));
  assert.throws(() => normalizeTouches([], NaN, 1));
  assert.throws(() => normalizeTouches([{ identifier: 'bad', locationX: 1, locationY: 1 }], 100, 100));
  assert.throws(() => normalizeTouches([{ identifier: 1, locationX: NaN, locationY: 1 }], 100, 100));
  assert.throws(() => normalizeTouches(Array(2).fill({ identifier: 1, locationX: 0, locationY: 0 }), 100, 100));
  assert.throws(() => normalizeTouches(Array(3).fill({ identifier: 1, locationX: 0, locationY: 0 }), 100, 100));
});
