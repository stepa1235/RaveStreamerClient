// No network, child processes or production data: execute actual handlers in an isolated harness.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function harness(secret = 'test-admin-secret', env = {}) {
  const routes = new Map(), intervals = [], emissions = [], sockets = new Map();
  const app = { set() {}, use() {}, get(p, ...h) { routes.set(`GET ${p}`, h); }, post(p, ...h) { routes.set(`POST ${p}`, h); } };
  const express = () => app;
  express.json = express.urlencoded = express.static = () => () => {};
  let connection;
  class Server {
    constructor() { this.sockets = { sockets }; }
    on(event, handler) { if (event === 'connection') connection = handler; }
    to(room) { return { emit: (event, data) => emissions.push({ room, event, data }) }; }
    emit(event, data) { emissions.push({ room: '*', event, data }); }
  }
  const fakeFs = { existsSync: () => false, mkdirSync() {}, writeFileSync() {} };
  const source = fs.readFileSync(__dirname + '/index.js', 'utf8')
    .replace('downloadYtDlp();', '')
    .split('const PORT = process.env.PORT || 3000;')[0];
  const context = {
    require(name) {
      if (name === 'express') return express;
      if (name === 'http') return { createServer: () => ({}) };
      if (name === 'socket.io') return { Server };
      if (name === 'cors') return () => () => {};
      if (name === 'fs') return fakeFs;
      return require(name);
    },
    __dirname, Buffer, Uint8Array, URL, AbortController,
    process: { env: { ADMIN_SECRET: secret, ...env }, uptime: () => 0, memoryUsage: () => ({}) },
    console: { log() {}, warn() {}, error() {} },
    setInterval: fn => intervals.push(fn), setTimeout: () => 1, clearTimeout() {},
  };
  vm.runInNewContext(source, context);
  function connect(id, adminToken) {
    const handlers = new Map(), output = [];
    let middleware;
    const socket = {
      id, rooms: new Set([id]), handshake: { address: '127.0.0.1', auth: { adminToken } },
      use(fn) { middleware = fn; }, on(e, fn) { handlers.set(e, fn); },
      emit(event, data) { output.push({ event, data }); },
      join(room) { this.rooms.add(room); }, leave(room) { this.rooms.delete(room); },
      to(room) { return { emit: (event, data) => emissions.push({ room, event, data }) }; },
      send(event, data) { middleware([event, data], () => handlers.get(event)?.(data)); },
      output,
    };
    sockets.set(id, socket); connection(socket); return socket;
  }
  return { connect, emissions, intervals, routes };
}
const join = (socket, roomId, extra = {}) => socket.send('join-room', { roomId, username: socket.id, clientId: socket.id, ...extra });
const state = s => s.output.findLast(e => e.event === 'room-state')?.data;

test('first creator becomes host and a second user can join without TDZ exception', () => {
  const h = harness(), a = h.connect('alice'), b = h.connect('bob');
  join(a, 'test'); join(b, 'test');
  assert.equal(state(a).isHost, true); assert.equal(state(b).isHost, false);
  assert.equal(state(b).hostToken, null);
});
test('public device ID cannot take over host or remove an existing socket', () => {
  const h = harness(), a = h.connect('alice'), b = h.connect('bob');
  join(a, 'test'); join(b, 'test', { clientId: 'alice', isBroadcaster: true });
  assert.equal(state(b).isHost, false);
  const users = h.emissions.findLast(e => e.event === 'room-users').data;
  assert.equal(users.length, 2); assert.equal(users.find(u => u.id === 'alice').isHost, true);
});
test('host reconnects using secret token', () => {
  const h = harness(), a = h.connect('alice'), b = h.connect('alice2');
  join(a, 'test'); join(b, 'test', { hostToken: state(a).hostToken });
  assert.equal(state(b).isHost, true);
});
test('outsider cannot inject chat or signal a private room', () => {
  const h = harness(), a = h.connect('alice'), b = h.connect('bob'); join(a, 'private', { password: 'pw' });
  const before = h.emissions.length;
  b.send('chat-msg', { roomId: 'private', text: 'injected', username: 'alice' });
  b.send('webrtc-offer', { roomId: 'private', targetId: 'alice', offer: {} });
  assert.equal(h.emissions.length, before);
});
test('chat identity comes from server membership', () => {
  const h = harness(), a = h.connect('alice'); join(a, 'test');
  a.send('chat-msg', { roomId: 'test', text: 'hello', username: 'System', clientId: 'system' });
  const m = h.emissions.findLast(e => e.event === 'chat-msg').data;
  assert.equal(m.username, 'alice'); assert.equal(m.clientId, 'alice');
});
test('malformed packets and overlong chat are rejected without exceptions', () => {
  const h = harness(), a = h.connect('alice');
  for (const data of [null, undefined, [], 'text', {}, { roomId: 1 }, { roomId: 'test', username: {} }]) a.send('join-room', data);
  join(a, 'test'); const before = h.emissions.length;
  a.send('chat-msg', { roomId: 'test', text: 'a'.repeat(4001) });
  assert.equal(h.emissions.length, before);
});
test('reactions cannot impersonate another member or create arbitrary keys', () => {
  const h = harness(), a = h.connect('alice'); join(a, 'test');
  a.send('chat-msg', { roomId: 'test', text: 'hello' });
  const id = h.emissions.findLast(e => e.event === 'chat-msg').data.id;
  a.send('chat-reaction', { roomId: 'test', messageId: id, emoji: '👍', username: 'bob' });
  assert.equal(h.emissions.findLast(e => e.event === 'chat-reaction-updated').data.reactions['👍'][0], 'alice');
  const n = h.emissions.length;
  a.send('chat-reaction', { roomId: 'test', messageId: id, emoji: '__proto__', username: 'bob' });
  assert.equal(h.emissions.length, n);
});
test('admin stats are broadcast only to authenticated admin room', () => {
  const h = harness(), a = h.connect('alice'), admin = h.connect('admin', 'test-admin-secret');
  join(a, 'test'); h.intervals.forEach(fn => fn());
  assert.equal(a.rooms.has('luna:admin'), false); assert.equal(admin.rooms.has('luna:admin'), true);
  assert.ok(h.emissions.filter(e => e.event === 'admin-stats').every(e => e.room === 'luna:admin'));
  a.send('join-room', { roomId: 'luna:admin' }); assert.equal(a.rooms.has('luna:admin'), false);
});
test('admin API fails closed without configured secret', () => {
  const h = harness(''), middleware = h.routes.get('GET /api/stats')[0];
  let status, passed = false;
  middleware({ headers: { 'x-admin-token': 'anything' }, query: {}, path: '/api/stats' }, { status(c) { status = c; return this; }, json() {} }, () => { passed = true; });
  assert.equal(status, 401); assert.equal(passed, false);
});
test('live data accepted only from room host', () => {
  const h = harness(), a = h.connect('alice'), b = h.connect('bob'); join(a, 'test'); join(b, 'test');
  assert.doesNotThrow(() => b.send('live-stream-chunk', { roomId: 'test', chunk: {} }));
  assert.doesNotThrow(() => a.send('live-stream-chunk', { roomId: 'test', chunk: {} }));
});
test('TURN credentials are temporary, signed and issued only after joining', () => {
  const h = harness('test-admin-secret', { TURN_SHARED_SECRET: 'test-only-key', TURN_URLS: 'turn:relay.example:3478' });
  const a = h.connect('alice');
  const latestIce = () => a.output.findLast(e => e.event === 'ice-servers').data;
  assert.equal(latestIce().some(s => s.credential), false);
  a.send('get-ice-servers'); assert.equal(latestIce().some(s => s.credential), false);
  join(a, 'test');
  const relay = latestIce().find(s => s.credential);
  assert.ok(relay); assert.ok(Number(relay.username.split(':')[0]) > Date.now() / 1000);
  assert.equal(relay.credential, require('crypto').createHmac('sha1', 'test-only-key').update(relay.username).digest('base64'));
});
