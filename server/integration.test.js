const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { fork } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { io } = require('socket.io-client');

let child, tempDir, base;
const clients = [];
before(async () => {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'luna-security-test-'));
  // Only omit the automatic third-party binary download; exercise real HTTP/Socket.IO.
  const source = fs.readFileSync(path.join(__dirname, 'index.js'), 'utf8')
    .replace('\ndownloadYtDlp();', '\n// Binary download excluded from integration tests.')
    .replace("server.listen(PORT, '0.0.0.0'", "server.listen(PORT, '127.0.0.1'");
  const fixture = path.join(tempDir, 'server.cjs');
  fs.writeFileSync(fixture, source + "\nserver.on('listening', () => process.send({port: server.address().port}));\n");
  child = fork(fixture, [], {
    env: { ...process.env, NODE_PATH: path.join(__dirname, 'node_modules'), PORT: '0',
      ADMIN_SECRET: 'integration-only-admin-secret', GITHUB_TOKEN: '',
      TURN_SHARED_SECRET: 'integration-only-turn-secret', TURN_URLS: 'turn:relay.example:3478' },
    stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
  });
  const stderr = [];
  child.stderr.on('data', d => stderr.push(d.toString()));
  const [{ port }] = await Promise.race([
    once(child, 'message'),
    once(child, 'exit').then(([code]) => { throw new Error(`Server exited ${code}: ${stderr.join('')}`); }),
    new Promise((_, reject) => { const t = setTimeout(() => reject(new Error('Startup timeout')), 15000); t.unref(); }),
  ]);
  base = `http://127.0.0.1:${port}`;
});
after(async () => {
  clients.forEach(s => s.disconnect());
  if (child && child.exitCode === null) { const stopped = once(child, 'exit'); child.kill(); await stopped; }
  if (tempDir && path.basename(tempDir).startsWith('luna-security-test-') && path.dirname(tempDir) === os.tmpdir()) {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
async function connect(auth) {
  const s = io(base, { autoConnect: false, transports: ['websocket'], reconnection: false, auth });
  clients.push(s);
  const connected = once(s, 'connect'); s.connect(); await connected; return s;
}
async function join(s, roomId, username, extra = {}) {
  const reply = once(s, 'room-state'); s.emit('join-room', { roomId, username, ...extra });
  return (await reply)[0];
}
test('real HTTP auth fails closed and configured token works', async () => {
  assert.equal((await fetch(base + '/health')).status, 200);
  assert.equal((await fetch(base + '/api/stats')).status, 401);
  assert.equal((await fetch(base + '/api/stats', { headers: { 'x-admin-token': 'wrong' } })).status, 401);
  assert.equal((await fetch(base + '/api/stats', { headers: { 'x-admin-token': 'integration-only-admin-secret' } })).status, 200);
});
test('real sockets join, preserve host identity and reject cross-room injection', async () => {
  const a = await connect(), b = await connect(), outsider = await connect();
  const host = await join(a, 'private', 'alice', { clientId: 'device-a', password: 'test-pw' });
  const guest = await join(b, 'private', 'bob', { clientId: 'device-a', password: 'test-pw', isBroadcaster: true });
  assert.equal(host.isHost, true); assert.equal(guest.isHost, false);
  const received = once(b, 'chat-msg');
  a.emit('chat-msg', { roomId: 'private', username: 'System', clientId: 'system', text: 'hello' });
  const [message] = await received;
  assert.equal(message.username, 'alice'); assert.equal(message.clientId, 'device-a');
  const attacks = [];
  b.on('chat-msg', msg => { if (msg.text === 'injected') attacks.push(msg); });
  outsider.emit('chat-msg', { roomId: 'private', text: 'injected' });
  const forwarded = [];
  b.on('webrtc-offer', msg => forwarded.push(msg));
  outsider.emit('webrtc-offer', { roomId: 'private', targetId: b.id, offer: {} });
  await new Promise(resolve => setTimeout(resolve, 120));
  assert.equal(attacks.length, 0); assert.equal(forwarded.length, 0);
  outsider.emit('join-room', null);
  assert.equal((await fetch(base + '/health')).status, 200);
});
