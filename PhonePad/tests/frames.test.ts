import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PadFrames } from '../src/PadFrames.ts';
import { animationFrames } from './animationFrames.ts';
import type { Touch } from '../src/protocol.ts';

const one = (x = 0.5, id = 1): Touch[] => [{ id, x, y: 0.5 }];
const pair = (x = 0.5): Touch[] => [{ id: 1, x: x - 0.1, y: 0.5 }, { id: 2, x: x + 0.1, y: 0.5 }];

test('240 touch moves and 60 display ticks preserve every event without duplicate polling frames', t => {
  const clock = animationFrames(t);
  const sent: Touch[][] = [];
  const frames = new PadFrames(contacts => sent.push(contacts));
  frames.update(one(), false);
  for (let tick = 0; tick < 60; tick++) {
    for (let sample = 0; sample < 4; sample++) {
      clock.advance(1000 / 240);
      frames.update(one(0.5 + (tick * 4 + sample) / 1000), false);
    }
    assert.equal(clock.pending, 1);
    clock.tick(0);
    assert.equal(sent.at(-1)?.[0].x, 0.5 + (tick * 4 + 3) / 1000);
  }
  frames.update([], false);
  console.log(`Phone workload: touch moves=240, ticks=60, frame sends=${sent.length}, pending callbacks=${clock.pending}`);
  assert.equal(sent.length, 242);
  assert.equal(clock.pending, 0);
});

test('stationary contacts keep sending hold frames and fully lifted input stops the loop', t => {
  const clock = animationFrames(t);
  const sent: { contacts: Touch[]; resize: boolean }[] = [];
  const frames = new PadFrames((contacts, resize) => sent.push({ contacts, resize }));
  frames.update(pair(), true);
  for (let tick = 0; tick < 30; tick++) clock.tick();
  assert.equal(sent.length, 31);
  assert.ok(sent.every(packet => packet.contacts.length === 2 && packet.resize));
  frames.update([], true);
  clock.tick();
  assert.equal(sent.length, 32);
  assert.equal(clock.pending, 0);
});

test('movement and contact changes are immediate, including a final move before release', t => {
  const clock = animationFrames(t);
  const sent: Touch[][] = [];
  const frames = new PadFrames(contacts => sent.push(contacts));
  frames.update(one(), false);
  frames.update(one(0.6), false);
  assert.deepEqual(sent, [one(), one(0.6)]);
  frames.update(pair(0.6), false);
  assert.deepEqual(sent, [one(), one(0.6), pair(0.6)]);
  frames.update(pair(0.7), false);
  frames.update(one(0.8), false);
  assert.deepEqual(sent.slice(-2), [pair(0.7), one(0.8)]);
  frames.update(one(0.9), false);
  frames.update([], false);
  assert.deepEqual(sent.slice(-2), [one(0.9), []]);
  assert.equal(clock.pending, 0);
});

test('contact replacement and reordering preserve every recognizer input', t => {
  const clock = animationFrames(t);
  const sent: Touch[][] = [];
  const frames = new PadFrames(contacts => sent.push(contacts));
  frames.update(pair(), false);
  frames.update(pair().reverse(), false);
  assert.equal(sent.length, 2);
  clock.tick(0);
  assert.equal(sent.length, 2);
  frames.update([one(0.5, 3)[0], pair()[1]], false);
  assert.equal(sent.length, 3);
  frames.stop();
});

test('stop cancels held-contact callbacks before a fresh gesture', t => {
  const clock = animationFrames(t);
  const sent: Touch[][] = [];
  const frames = new PadFrames(contacts => sent.push(contacts));
  frames.update(one(), false);
  frames.update(one(0.8), false);
  frames.stop();
  clock.tick();
  assert.deepEqual(sent, [one(), one(0.8)]);
  assert.equal(clock.pending, 0);
  frames.update(one(0.2), false);
  assert.deepEqual(sent, [one(), one(0.8), one(0.2)]);
  frames.stop();
});

test('synchronous disconnect during a send cannot restart the sampling loop', t => {
  const clock = animationFrames(t);
  let frames: PadFrames;
  let sends = 0;
  frames = new PadFrames(() => { sends++; frames.stop(); });
  frames.update(one(), false);
  assert.equal(sends, 1);
  assert.equal(clock.pending, 0);

  let disconnect = false;
  frames = new PadFrames(() => { sends++; if (disconnect) frames.stop(); });
  frames.update(one(), false);
  frames.update(one(0.8), false);
  disconnect = true;
  frames.update([], false);
  assert.equal(sends, 4);
  assert.equal(clock.pending, 0);
});

test('a fast out-and-back movement before release is retained so it cannot become a tap', t => {
  const clock = animationFrames(t);
  const sent: Touch[][] = [];
  const frames = new PadFrames(contacts => sent.push(contacts));
  frames.update(one(), false);
  frames.update(one(0.8), false);
  frames.update(one(), false);
  frames.update([], false);
  assert.deepEqual(sent, [one(), one(0.8), one(), []]);
  assert.equal(clock.pending, 0);
});

test('held frames resume after a moving interval with at most one skipped tick', t => {
  const clock = animationFrames(t);
  const sent: Touch[][] = [];
  const frames = new PadFrames(contacts => sent.push(contacts));
  frames.update(pair(), false);
  clock.tick(0);
  clock.tick();
  assert.equal(sent.length, 2);
  frames.update(pair(0.6), false);
  frames.update(pair(0.7), false);
  clock.tick(0);
  assert.equal(sent.length, 4);
  clock.tick();
  assert.equal(sent.length, 5);
  assert.deepEqual(sent.at(-1), pair(0.7));
  frames.stop();
});

test('a delayed display tick sends held contacts even if input was sent since the previous tick', t => {
  const clock = animationFrames(t);
  const sent: Touch[][] = [];
  const frames = new PadFrames(contacts => sent.push(contacts));
  frames.update(pair(), false);
  clock.tick(250);
  assert.deepEqual(sent, [pair(), pair()]);
  frames.stop();
});
