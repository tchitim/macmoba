// Minimal Telnet server for driving MacMoba's client.
//
// Negotiates the options a real server would (ECHO, SGA, TERMINAL-TYPE, NAWS),
// logs what the client answered, and runs a tiny line-based shell so the
// terminal has something to show. Logs go to /tmp/macmoba-telnet-events.log so
// a test can assert on what actually arrived rather than on a screenshot.

const net = require('net');
const fs = require('fs');

const PORT = Number(process.env.PORT || 2323);
const LOG = process.env.LOG || '/tmp/macmoba-telnet-events.log';

const IAC = 255, SE = 240, SB = 250, WILL = 251, WONT = 252, DO = 253, DONT = 254;
const OPT_ECHO = 1, OPT_SGA = 3, OPT_TTYPE = 24, OPT_NAWS = 31;

const NAMES = { 251: 'WILL', 252: 'WONT', 253: 'DO', 254: 'DONT' };
const OPT_NAMES = { 1: 'ECHO', 3: 'SGA', 24: 'TTYPE', 31: 'NAWS' };

fs.writeFileSync(LOG, '');
const log = (line) => {
  fs.appendFileSync(LOG, line + '\n');
  console.log(line);
};

net.createServer((socket) => {
  log('CONNECT');
  let state = 'data';
  let command = 0;
  let sub = [];
  let line = '';

  // Ask for everything a real server would, so the client's answers are
  // exercised rather than assumed.
  socket.write(Buffer.from([
    IAC, WILL, OPT_ECHO,
    IAC, WILL, OPT_SGA,
    IAC, DO, OPT_TTYPE,
    IAC, DO, OPT_NAWS,
    IAC, DO, 99,           // an option nothing supports: must be refused, not ignored
  ]));
  socket.write('MacMoba telnet test server\r\nlogin: ');

  const handleSub = () => {
    const option = sub[0];
    if (option === OPT_TTYPE && sub[1] === 0) {
      log('TTYPE=' + Buffer.from(sub.slice(2)).toString('latin1'));
    } else if (option === OPT_NAWS && sub.length >= 5) {
      log(`NAWS=${(sub[1] << 8) | sub[2]}x${(sub[3] << 8) | sub[4]}`);
    }
    sub = [];
  };

  socket.on('data', (chunk) => {
    for (const byte of chunk) {
      if (state === 'data') {
        if (byte === IAC) { state = 'iac'; continue; }
        // Echo like a real server would, then act on complete lines.
        if (byte === 0x0d) {
          socket.write('\r\n');
          log('LINE=' + line);
          if (line === 'quit') { socket.end('bye\r\n'); return; }
          socket.write(line ? `you said: ${line}\r\n$ ` : '$ ');
          line = '';
        } else if (byte === 0x00) {
          // NUL after CR: the RFC 854 line terminator, not input.
        } else if (byte === 0x7f || byte === 0x08) {
          line = line.slice(0, -1);
          socket.write('\b \b');
        } else {
          line += String.fromCharCode(byte);
          socket.write(Buffer.from([byte]));
        }
        continue;
      }
      if (state === 'iac') {
        if (byte === IAC) { line += '\xff'; state = 'data'; }
        else if (byte === SB) { sub = []; state = 'sb'; }
        else if (byte >= WILL && byte <= DONT) { command = byte; state = 'opt'; }
        else state = 'data';
        continue;
      }
      if (state === 'opt') {
        log(`${NAMES[command]} ${OPT_NAMES[byte] || byte}`);
        // A client saying WILL TERMINAL-TYPE has only agreed to be asked; the
        // name itself comes from a separate subnegotiation that the SERVER has
        // to request. Without this the client is left waiting, correctly.
        if (command === WILL && byte === OPT_TTYPE) {
          socket.write(Buffer.from([IAC, SB, OPT_TTYPE, 1, IAC, SE])); // SEND
        }
        state = 'data';
        continue;
      }
      if (state === 'sb') {
        if (byte === IAC) state = 'sbiac';
        else sub.push(byte);
        continue;
      }
      if (state === 'sbiac') {
        if (byte === SE) { handleSub(); state = 'data'; }
        else if (byte === IAC) { sub.push(IAC); state = 'sb'; }
        else state = 'sb';
      }
    }
  });

  socket.on('error', (e) => log('ERROR ' + e.message));
  socket.on('close', () => log('DISCONNECT'));
}).listen(PORT, '127.0.0.1', () => {
  log(`listening on 127.0.0.1:${PORT}`);
});
