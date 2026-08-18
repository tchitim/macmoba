// Minimal RFB 3.8 server for testing MacMoba's VNC tab.
// Deliberately tiny and hand-rolled, like ssh-server.js:
//   - VNC authentication (type 2): any 16-byte response is accepted, so the
//     client's auth exchange is exercised without real DES on this side.
//   - Serves a framebuffer split into four solid quadrants, Raw encoded, so a
//     screenshot can be checked against known colours.
//   - Appends every key/pointer event it receives to EVENT_LOG, which is what
//     makes "did input actually reach the server" verifiable.
//
// usage: node vnc-server.js [port] [--auth none|vnc]

const net = require('net');
const fs = require('fs');

const PORT = parseInt(process.argv[2] || '5999', 10);
const AUTH = (process.argv.includes('--auth')
  ? process.argv[process.argv.indexOf('--auth') + 1]
  : 'vnc');
const EVENT_LOG = process.env.VNC_EVENT_LOG || '/tmp/macmoba-vnc-events.log';

const WIDTH = 320;
const HEIGHT = 240;
const NAME = 'macmoba-test';

// Quadrant colours, clockwise from top-left.
const QUADRANTS = [
  { r: 255, g: 0, b: 0 },     // top-left     red
  { r: 0, g: 255, b: 0 },     // top-right    green
  { r: 0, g: 0, b: 255 },     // bottom-left  blue
  { r: 255, g: 255, b: 0 },   // bottom-right yellow
];

function logEvent(line) {
  fs.appendFileSync(EVENT_LOG, line + '\n');
}

/** Server's own pixel format, also the default until the client changes it. */
function defaultFormat() {
  return {
    bitsPerPixel: 32, depth: 24, bigEndian: 0, trueColour: 1,
    redMax: 255, greenMax: 255, blueMax: 255,
    redShift: 16, greenShift: 8, blueShift: 0,
  };
}

function writePixelFormat(buf, off, f) {
  buf.writeUInt8(f.bitsPerPixel, off);
  buf.writeUInt8(f.depth, off + 1);
  buf.writeUInt8(f.bigEndian, off + 2);
  buf.writeUInt8(f.trueColour, off + 3);
  buf.writeUInt16BE(f.redMax, off + 4);
  buf.writeUInt16BE(f.greenMax, off + 6);
  buf.writeUInt16BE(f.blueMax, off + 8);
  buf.writeUInt8(f.redShift, off + 10);
  buf.writeUInt8(f.greenShift, off + 11);
  buf.writeUInt8(f.blueShift, off + 12);
  buf.fill(0, off + 13, off + 16); // padding
}

function readPixelFormat(buf, off) {
  return {
    bitsPerPixel: buf.readUInt8(off),
    depth: buf.readUInt8(off + 1),
    bigEndian: buf.readUInt8(off + 2),
    trueColour: buf.readUInt8(off + 3),
    redMax: buf.readUInt16BE(off + 4),
    greenMax: buf.readUInt16BE(off + 6),
    blueMax: buf.readUInt16BE(off + 8),
    redShift: buf.readUInt8(off + 10),
    greenShift: buf.readUInt8(off + 11),
    blueShift: buf.readUInt8(off + 12),
  };
}

/** Encode one pixel into the client's requested format. */
function encodePixel(colour, f) {
  const scale = (v, max) => Math.round((v / 255) * max);
  const value = (scale(colour.r, f.redMax) << f.redShift)
    | (scale(colour.g, f.greenMax) << f.greenShift)
    | (scale(colour.b, f.blueMax) << f.blueShift);
  const bytes = f.bitsPerPixel / 8;
  const out = Buffer.alloc(bytes);
  if (f.bigEndian) {
    out.writeUIntBE(value >>> 0, 0, bytes);
  } else {
    out.writeUIntLE(value >>> 0, 0, bytes);
  }
  return out;
}

function colourAt(x, y) {
  const right = x >= WIDTH / 2;
  const bottom = y >= HEIGHT / 2;
  if (!bottom && !right) return QUADRANTS[0];
  if (!bottom && right) return QUADRANTS[1];
  if (bottom && !right) return QUADRANTS[2];
  return QUADRANTS[3];
}

/** A full-screen FramebufferUpdate, one Raw-encoded rectangle. */
function framebufferUpdate(format) {
  const bytes = format.bitsPerPixel / 8;
  const header = Buffer.alloc(16);
  header.writeUInt8(0, 0);           // message-type: FramebufferUpdate
  header.writeUInt8(0, 1);           // padding
  header.writeUInt16BE(1, 2);        // number-of-rectangles
  header.writeUInt16BE(0, 4);        // x
  header.writeUInt16BE(0, 6);        // y
  header.writeUInt16BE(WIDTH, 8);
  header.writeUInt16BE(HEIGHT, 10);
  header.writeInt32BE(0, 12);        // encoding-type: Raw

  const pixels = Buffer.alloc(WIDTH * HEIGHT * bytes);
  let off = 0;
  for (let y = 0; y < HEIGHT; y++) {
    for (let x = 0; x < WIDTH; x++) {
      encodePixel(colourAt(x, y), format).copy(pixels, off);
      off += bytes;
    }
  }
  return Buffer.concat([header, pixels]);
}

net.createServer((socket) => {
  let stage = 'version';
  let buffer = Buffer.alloc(0);
  let format = defaultFormat();

  socket.on('error', () => {});
  socket.write(Buffer.from('RFB 003.008\n', 'ascii'));

  // Pull exactly n bytes off the front of the buffer, or null if short.
  function take(n) {
    if (buffer.length < n) return null;
    const out = buffer.subarray(0, n);
    buffer = buffer.subarray(n);
    return out;
  }

  function handleClientMessage() {
    if (buffer.length < 1) return false;
    const type = buffer.readUInt8(0);
    switch (type) {
      case 0: { // SetPixelFormat
        if (buffer.length < 20) return false;
        take(4);
        format = readPixelFormat(take(16), 0);
        logEvent(`SetPixelFormat bpp=${format.bitsPerPixel} depth=${format.depth}`);
        return true;
      }
      case 2: { // SetEncodings
        if (buffer.length < 4) return false;
        const count = buffer.readUInt16BE(2);
        if (buffer.length < 4 + count * 4) return false;
        take(4);
        const encodings = [];
        for (let i = 0; i < count; i++) encodings.push(take(4).readInt32BE(0));
        logEvent(`SetEncodings ${encodings.join(',')}`);
        return true;
      }
      case 3: { // FramebufferUpdateRequest
        if (buffer.length < 10) return false;
        take(10);
        socket.write(framebufferUpdate(format));
        return true;
      }
      case 4: { // KeyEvent
        if (buffer.length < 8) return false;
        const msg = take(8);
        logEvent(`KeyEvent down=${msg.readUInt8(1)} keysym=0x${msg.readUInt32BE(4).toString(16)}`);
        return true;
      }
      case 5: { // PointerEvent
        if (buffer.length < 6) return false;
        const msg = take(6);
        logEvent(`PointerEvent buttons=${msg.readUInt8(1)} x=${msg.readUInt16BE(2)} y=${msg.readUInt16BE(4)}`);
        return true;
      }
      case 6: { // ClientCutText
        if (buffer.length < 8) return false;
        const length = buffer.readUInt32BE(4);
        if (buffer.length < 8 + length) return false;
        take(8);
        logEvent(`ClientCutText ${take(length).toString('utf8')}`);
        return true;
      }
      default:
        logEvent(`unknown client message ${type}`);
        socket.destroy();
        return false;
    }
  }

  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (stage === 'version') {
        if (!take(12)) return;
        if (AUTH === 'none') {
          socket.write(Buffer.from([1, 1])); // one type: None
        } else {
          socket.write(Buffer.from([1, 2])); // one type: VNC authentication
        }
        stage = 'security';
      } else if (stage === 'security') {
        if (!take(1)) return;
        if (AUTH === 'none') {
          socket.write(Buffer.from([0, 0, 0, 0])); // SecurityResult: OK
          stage = 'clientinit';
        } else {
          socket.write(Buffer.alloc(16, 0x41)); // fixed challenge
          stage = 'auth-response';
        }
      } else if (stage === 'auth-response') {
        const response = take(16);
        if (!response) return;
        logEvent(`VNCAuth response ${response.toString('hex')}`);
        socket.write(Buffer.from([0, 0, 0, 0])); // accept any response
        stage = 'clientinit';
      } else if (stage === 'clientinit') {
        if (!take(1)) return;
        const name = Buffer.from(NAME, 'ascii');
        const init = Buffer.alloc(24 + name.length);
        init.writeUInt16BE(WIDTH, 0);
        init.writeUInt16BE(HEIGHT, 2);
        writePixelFormat(init, 4, format);
        init.writeUInt32BE(name.length, 20);
        name.copy(init, 24);
        socket.write(init);
        logEvent(`ServerInit ${WIDTH}x${HEIGHT}`);
        stage = 'ready';
      } else {
        if (!handleClientMessage()) return;
      }
    }
  });
}).listen(PORT, '127.0.0.1', () => {
  fs.writeFileSync(EVENT_LOG, '');
  console.log(`RFB 3.8 test server on 127.0.0.1:${PORT} (auth=${AUTH}), events -> ${EVENT_LOG}`);
});
