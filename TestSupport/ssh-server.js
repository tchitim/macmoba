// Test SSH server for MacMobaCore integration tests.
// Listens on 127.0.0.1:2299, user "test" / password "secret".
// - shell: prints banner, echoes input back
// - direct-tcpip: forwards to the requested target (for tunnel tests)
// - sftp: serves the real local filesystem (test-only; no chroot)
// Usage: npm install && node ssh-server.js
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const net = require('net');
const path = require('path');
const { Server, utils } = require('ssh2');
const { STATUS_CODE } = utils.sftp;
global.__shellCount = 0;

// NOTE: ECDSA host key — swift-nio-ssh does not support ssh-rsa host keys.
const { privateKey } = crypto.generateKeyPairSync('ec', {
  namedCurve: 'prime256v1',
  privateKeyEncoding: { type: 'sec1', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});

// Minimal SFTP v3 server over the local filesystem (fs-backed, test only).
function attachSftp(sftp) {
  let nextHandle = 1;
  const handles = new Map(); // uint32 -> {fd} | {dirPath, done}

  const mkHandle = (obj) => {
    const id = nextHandle++;
    handles.set(id, obj);
    const b = Buffer.alloc(4);
    b.writeUInt32BE(id, 0);
    return b;
  };
  const getHandle = (buf) => (buf.length === 4 ? handles.get(buf.readUInt32BE(0)) : undefined);
  const fail = (reqid, err) => {
    const code = err && err.code === 'ENOENT' ? STATUS_CODE.NO_SUCH_FILE
      : err && (err.code === 'EACCES' || err.code === 'EPERM') ? STATUS_CODE.PERMISSION_DENIED
      : STATUS_CODE.FAILURE;
    sftp.status(reqid, code, String((err && err.message) || 'failure'));
  };
  const toAttrs = (st) => ({
    mode: st.mode,
    uid: st.uid,
    gid: st.gid,
    size: st.size,
    atime: Math.floor(st.atimeMs / 1000),
    mtime: Math.floor(st.mtimeMs / 1000),
  });

  sftp.on('REALPATH', (reqid, given) => {
    const p = path.resolve(given === '.' ? process.env.HOME || '/' : given);
    sftp.name(reqid, [{ filename: p, longname: p, attrs: {} }]);
  });
  sftp.on('STAT', (reqid, p) => {
    try { sftp.attrs(reqid, toAttrs(fs.statSync(p))); } catch (e) { fail(reqid, e); }
  });
  sftp.on('LSTAT', (reqid, p) => {
    try { sftp.attrs(reqid, toAttrs(fs.lstatSync(p))); } catch (e) { fail(reqid, e); }
  });
  sftp.on('OPENDIR', (reqid, p) => {
    try {
      if (!fs.statSync(p).isDirectory()) return fail(reqid, new Error('not a directory'));
      sftp.handle(reqid, mkHandle({ dirPath: p, done: false }));
    } catch (e) { fail(reqid, e); }
  });
  sftp.on('READDIR', (reqid, handle) => {
    const h = getHandle(handle);
    if (!h || h.dirPath === undefined) return fail(reqid, new Error('bad handle'));
    if (h.done) return sftp.status(reqid, STATUS_CODE.EOF);
    try {
      const names = fs.readdirSync(h.dirPath);
      const entries = names.map((name) => {
        let st;
        try { st = fs.lstatSync(path.join(h.dirPath, name)); } catch (_) { return null; }
        return { filename: name, longname: name, attrs: toAttrs(st) };
      }).filter(Boolean);
      h.done = true;
      sftp.name(reqid, entries);
    } catch (e) { fail(reqid, e); }
  });
  sftp.on('OPEN', (reqid, filename, flags) => {
    try {
      const str = utils.sftp.flagsToString(flags);
      sftp.handle(reqid, mkHandle({ fd: fs.openSync(filename, str) }));
    } catch (e) { fail(reqid, e); }
  });
  sftp.on('READ', (reqid, handle, offset, length) => {
    const h = getHandle(handle);
    if (!h || h.fd === undefined) return fail(reqid, new Error('bad handle'));
    try {
      const buf = Buffer.alloc(length);
      const n = fs.readSync(h.fd, buf, 0, length, Number(offset));
      if (n === 0) return sftp.status(reqid, STATUS_CODE.EOF);
      sftp.data(reqid, buf.subarray(0, n));
    } catch (e) { fail(reqid, e); }
  });
  sftp.on('WRITE', (reqid, handle, offset, data) => {
    const h = getHandle(handle);
    if (!h || h.fd === undefined) return fail(reqid, new Error('bad handle'));
    try {
      fs.writeSync(h.fd, data, 0, data.length, Number(offset));
      sftp.status(reqid, STATUS_CODE.OK);
    } catch (e) { fail(reqid, e); }
  });
  sftp.on('CLOSE', (reqid, handle) => {
    const h = getHandle(handle);
    if (!h) return fail(reqid, new Error('bad handle'));
    if (h.fd !== undefined) { try { fs.closeSync(h.fd); } catch (_) {} }
    handles.delete(handle.readUInt32BE(0));
    sftp.status(reqid, STATUS_CODE.OK);
  });
  sftp.on('MKDIR', (reqid, p) => {
    try { fs.mkdirSync(p); sftp.status(reqid, STATUS_CODE.OK); } catch (e) { fail(reqid, e); }
  });
  sftp.on('RMDIR', (reqid, p) => {
    try { fs.rmdirSync(p); sftp.status(reqid, STATUS_CODE.OK); } catch (e) { fail(reqid, e); }
  });
  sftp.on('REMOVE', (reqid, p) => {
    try { fs.unlinkSync(p); sftp.status(reqid, STATUS_CODE.OK); } catch (e) { fail(reqid, e); }
  });
  sftp.on('RENAME', (reqid, oldPath, newPath) => {
    try { fs.renameSync(oldPath, newPath); sftp.status(reqid, STATUS_CODE.OK); } catch (e) { fail(reqid, e); }
  });
  // chmod via SETSTAT: apply the permission bits to the real file.
  sftp.on('SETSTAT', (reqid, p, attrs) => {
    try {
      if (attrs && typeof attrs.mode === 'number') {
        fs.chmodSync(p, attrs.mode & 0o7777);
      }
      sftp.status(reqid, STATUS_CODE.OK);
    } catch (e) { fail(reqid, e); }
  });
}

const srv = new Server({ hostKeys: [privateKey] }, (client) => {
  client.on('authentication', (ctx) => {
    const ok = ctx.method === 'password' && ctx.username === 'test'
      && ctx.password === 'secret';
    // MM_AUTH_LOG (when set) records the username and result of each attempt,
    // so a test can prove which login actually reached the server.
    if (process.env.MM_AUTH_LOG) {
      require('fs').appendFileSync(process.env.MM_AUTH_LOG,
        'auth ' + (ok ? 'OK' : 'REJECT') + ' user=' + ctx.username
        + ' method=' + ctx.method + '\n');
    }
    if (ok) { return ctx.accept(); }
    ctx.reject(['password']);
  });
  client.on('ready', () => {
    client.on('session', (accept) => {
      const s = accept();
      s.on('pty', (a) => a && a());
      s.on('window-change', (a) => { if (a) a(); });
      s.on('shell', (a2) => {
        const st = a2();
        // Each shell gets a number, and MM_RX_LOG (when set) records what it
        // receives — which is how a test can tell exactly which sessions a
        // broadcast reached.
        const id = ++global.__shellCount;
        st.write('Welcome to smoke-server\r\n$ ');
        st.on('data', (d) => {
          if (process.env.MM_RX_LOG) {
            require('fs').appendFileSync(process.env.MM_RX_LOG,
              'shell' + id + ':' + JSON.stringify(d.toString()) + '\n');
          }
          st.write(d);
        });
      });
      s.on('sftp', (accept) => attachSftp(accept()));
    });
    // Remote (-R) forwarding: listen locally on the requested port, pipe each
    // connection back to the client as a forwarded-tcpip channel.
    client.on('request', (accept, reject, name, info) => {
      if (name !== 'tcpip-forward') { if (reject) reject(); return; }
      const listener = net.createServer((sock) => {
        client.forwardOut(
          info.bindAddr, info.bindPort,
          sock.remoteAddress || '127.0.0.1', sock.remotePort || 0,
          (err, stream) => {
            if (err) return sock.destroy();
            sock.pipe(stream).pipe(sock);
            stream.on('error', () => sock.destroy());
            sock.on('error', () => stream.destroy());
          });
      });
      listener.listen(info.bindPort, '127.0.0.1', () => {
        if (accept) accept(listener.address().port);
      });
      listener.on('error', () => { if (reject) reject(); });
      client.on('close', () => listener.close());
    });
    client.on('tcpip', (accept, reject, info) => {
      // MM_RX_LOG (when set) records every direct-tcpip forward, which is how
      // a test can prove a connection really went THROUGH this host.
      if (process.env.MM_RX_LOG) {
        require('fs').appendFileSync(process.env.MM_RX_LOG,
          'forward:' + info.destIP + ':' + info.destPort + '\n');
      }
      // MM_FORWARD_TO stands in for "a host only this server can reach": the
      // requested address is still logged, so a test can prove what the client
      // asked for, but the connection lands on something that exists locally.
      const target = process.env.MM_FORWARD_TO
        || (info.destIP === 'localhost' ? '127.0.0.1' : info.destIP);
      const socket = net.connect(info.destPort, target);
      socket.on('connect', () => {
        const stream = accept();
        // MM_EOF_ONLY: send CHANNEL_EOF when the origin stops sending, and
        // never CHANNEL_CLOSE. That is legal SSH and is what a server doing a
        // half-close looks like; a client that ignores EOF hangs forever.
        if (process.env.MM_EOF_ONLY) {
          socket.on('end', () => {
            try { client._protocol.channelEOF(stream.outgoing.id); } catch (_) {}
          });
          stream.pipe(socket);
          socket.pipe(stream, { end: false });
          stream.on('error', () => socket.destroy());
          socket.on('error', () => stream.destroy());
          return;
        }
        stream.pipe(socket).pipe(stream);
        stream.on('error', () => socket.destroy());
        socket.on('error', () => stream.destroy());
      });
      socket.on('error', () => { try { reject(); } catch (_) {} });
    });
  });
  client.on('error', () => {});
});

srv.listen(2299, '127.0.0.1', () => console.log('test ssh server on 127.0.0.1:2299'));
