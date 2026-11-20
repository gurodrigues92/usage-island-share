import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, copyFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = await mkdtemp(join(tmpdir(), 'usage-island-bridge-tests-'));
const file = join(dir, 'bridge.mjs');
await copyFile(new URL('../Sources/UsageIsland/Resources/usage-island-opencode.js', import.meta.url), file);
const { UsageIslandActivity } = await import(file);
const output = join(dir, 'activity');
const bridge = await UsageIslandActivity({ directory: '/test/project', activityDirectory: output });
const state = async () => JSON.parse(await readFile(join(output, `opencode-${process.pid}.json`), 'utf8'));

test('busy, waiting and idle are recorded without prompt or tool arguments', async () => {
  await bridge.event({ event: { type: 'session.status', properties: { sessionID: 'one', status: { type: 'busy' } } } });
  assert.equal((await state()).sessions[0].state, 'busy');
  await bridge.event({ event: { type: 'permission.asked', properties: { sessionID: 'one', command: 'PRIVATE COMMAND', prompt: 'PRIVATE PROMPT' } } });
  assert.equal((await state()).sessions[0].state, 'waiting');
  assert.ok(!JSON.stringify(await state()).includes('PRIVATE'));
  await bridge.event({ event: { type: 'permission.replied', properties: { sessionID: 'one' } } });
  assert.equal((await state()).sessions[0].state, 'busy');
  await bridge.event({ event: { type: 'session.idle', properties: { sessionID: 'one' } } });
  assert.equal((await state()).sessions[0].state, 'idle');
});

test('deletion removes the session without claiming completion', async () => {
  await bridge.event({ event: { type: 'session.deleted', properties: { sessionID: 'one' } } });
  assert.equal((await state()).sessions.length, 0);
});

test('concurrent events produce a valid bounded snapshot', async () => {
  await Promise.all(Array.from({ length: 90 }, (_, n) => bridge.event({ event: { type: 'session.status', properties: { sessionID: `s-${n}`, status: { type: 'busy' } } } })));
  const saved = await state();
  assert.equal(saved.sessions.length, 64);
  assert.equal(new Set(saved.sessions.map(s => s.id)).size, 64);
});

test('telemetry failure does not fail a tool session', async () => {
  const broken = await UsageIslandActivity({ directory: '/test', activityDirectory: '/dev/null/invalid' });
  await assert.doesNotReject(broken.event({ event: { type: 'session.status', properties: { sessionID: 'a', status: { type: 'busy' } } } }));
});

after(async () => { await rm(dir, { recursive: true, force: true }); });
