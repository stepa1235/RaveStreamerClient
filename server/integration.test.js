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

function nextEvent(socket, event, predicate = () => true) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.off(event, handler);
      reject(new Error(`No matching ${event} event`));
    }, 7000);
    function handler(value) {
      if (!predicate(value)) return;
      clearTimeout(timer);
      socket.off(event, handler);
      resolve(value);
    }
    socket.on(event, handler);
  });
}

test('room collaboration preserves a private session and enforces roles', { timeout: 20000 }, async () => {
  const roomId = 'watch-together';
  const host = await connect(), viewer = await connect(), outsider = await connect();
  await join(host, roomId, 'Host', { password: 'private' });
  const denied = nextEvent(outsider, 'room-error');
  outsider.emit('join-room', { roomId, username: 'Guest', inviteToken: 'invalid' });
  assert.equal((await denied).type, 'INVITE_EXPIRED');

  const { token } = await host.timeout(3000).emitWithAck('room-invite', { roomId, minutes: 15 });
  const session = nextEvent(viewer, 'room-resume-token');
  await join(viewer, roomId, 'Viewer', { inviteToken: token });
  const resumeToken = (await session).token;
  const [ping] = await Promise.all([
    viewer.timeout(3000).emitWithAck('room-ping', { roomId }),
    assert.rejects(viewer.timeout(100).emitWithAck('room-invite', { roomId, minutes: 15 })),
  ]);
  assert.deepEqual(ping, { ok: true });

  const cohost = nextEvent(viewer, 'room-features', state => state.viewers.some(u => u.cohost));
  host.emit('room-cohost', { roomId, targetId: viewer.id, enabled: true });
  await cohost;
  const media = nextEvent(viewer, 'room-features', state => !!state.mediaId);
  viewer.emit('video-change', { roomId, videoUrl: 'https://example.test/movie.mp4', videoName: 'Movie' });
  const { mediaId } = await media;
  const bookmark = nextEvent(host, 'chat-msg', msg => !!msg.bookmark);
  viewer.emit('chat-msg', { roomId, bookmark: { mediaId, seconds: 23 } });
  assert.deepEqual((await bookmark).bookmark, { mediaId, seconds: 23 });

  const suggestion = nextEvent(host, 'room-features', state => state.proposals.length === 1);
  assert.deepEqual(await viewer.timeout(3000).emitWithAck('room-propose', {
    roomId, url: 'https://example.test/next.mp4', title: 'Next',
  }), { ok: true });
  const [{ id }] = (await suggestion).proposals;
  const voted = nextEvent(host, 'room-features', state => state.proposals[0]?.votes === 1);
  viewer.emit('room-vote', { roomId, id });
  await voted;

  const autoPauseEnabled = nextEvent(viewer, 'room-features', state => state.autoPause);
  host.emit('room-auto-pause', { roomId, enabled: true });
  await autoPauseEnabled;
  const playing = nextEvent(viewer, 'played');
  host.emit('play', { roomId, time: 40 });
  await playing;
  const paused = nextEvent(host, 'paused');
  viewer.emit('room-readiness', { roomId, mediaId, readiness: 'buffering' });
  assert.ok((await paused).time >= 40);
  const resumed = nextEvent(host, 'played');
  viewer.emit('room-readiness', { roomId, mediaId, readiness: 'ready' });
  await resumed;

  // Replace the old connection before the server observes its transport closing.
  const replacement = await connect();
  const restored = nextEvent(replacement, 'room-features', state => state.viewers.some(u => u.id === replacement.id));
  const roomState = await join(replacement, roomId, 'Viewer', { resumeToken });
  assert.equal(roomState.isHost, false);
  assert.equal(roomState.videoName, 'Movie');
  assert.ok(roomState.calculatedTime >= 40);
  assert.equal((await restored).viewers.find(u => u.id === replacement.id).cohost, true);
  const unvoted = nextEvent(host, 'room-features', state => state.proposals[0]?.votes === 0);
  replacement.emit('room-vote', { roomId, id });
  await unvoted;
  const queued = nextEvent(host, 'queue-updated');
  replacement.emit('room-review', { roomId, id, accept: true });
  assert.deepEqual((await queued).queue, [{ videoUrl: 'https://example.test/next.mp4', videoName: 'Next' }]);
});
