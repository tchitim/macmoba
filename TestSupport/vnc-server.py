# A minimal RFB 3.8 server with no authentication, just enough to test the
# clipboard in both directions:
#   - sends a ServerCutText after connecting  (remote -> Mac)
#   - logs any ClientCutText it receives      (Mac -> remote)
import socket, struct, sys, threading, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5999
LOG = sys.argv[2] if len(sys.argv) > 2 else "/dev/stdout"
SEND_TEXT = "VNC-SERVER-COPIED-THIS"
W, H = 64, 64


def log(message):
    with open(LOG, "a") as f:
        f.write(message + "\n")


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def handle(conn):
    try:
        conn.sendall(b"RFB 003.008\n")
        log("client version: %s" % recv_exact(conn, 12).decode().strip())

        conn.sendall(bytes([1, 1]))               # one security type: None
        chosen = recv_exact(conn, 1)[0]
        log("client chose security type %d" % chosen)
        conn.sendall(struct.pack(">I", 0))        # SecurityResult: OK

        shared = recv_exact(conn, 1)[0]
        log("ClientInit shared=%d" % shared)

        name = b"MacMoba Clipboard Test"
        pixel_format = struct.pack(">BBBBHHHBBBxxx",
                                   32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        conn.sendall(struct.pack(">HH", W, H) + pixel_format
                     + struct.pack(">I", len(name)) + name)

        # Remote -> Mac: hand the client something to put on the pasteboard.
        def send_cut_text():
            time.sleep(1.5)
            payload = SEND_TEXT.encode("latin-1")
            try:
                conn.sendall(bytes([3, 0, 0, 0]) + struct.pack(">I", len(payload)) + payload)
                log("sent ServerCutText: %s" % SEND_TEXT)
            except Exception as exc:
                log("could not send cut text: %s" % exc)

        threading.Thread(target=send_cut_text, daemon=True).start()

        while True:
            kind = recv_exact(conn, 1)[0]
            if kind == 0:                                  # SetPixelFormat
                recv_exact(conn, 19)
            elif kind == 2:                                # SetEncodings
                recv_exact(conn, 1)
                count = struct.unpack(">H", recv_exact(conn, 2))[0]
                recv_exact(conn, 4 * count)
            elif kind == 3:                                # FramebufferUpdateRequest
                recv_exact(conn, 9)
                body = struct.pack(">BxH", 0, 1) + struct.pack(">HHHHi", 0, 0, W, H, 0)
                conn.sendall(body + bytes([0, 0, 128, 255]) * (W * H))
            elif kind == 4:                                # KeyEvent
                body = recv_exact(conn, 7)
                down, keysym = struct.unpack(">BxxI", body)
                log("KEY %s keysym=0x%x" % ("down" if down else "up  ", keysym))
            elif kind == 5:                                # PointerEvent
                recv_exact(conn, 5)
            elif kind == 6:                                # ClientCutText
                recv_exact(conn, 3)
                length = struct.unpack(">I", recv_exact(conn, 4))[0]
                text = recv_exact(conn, length).decode("latin-1")
                log("RECEIVED-CLIENT-CUT-TEXT: %s" % text)
            else:
                log("unknown message type %d" % kind)
                return
    except Exception as exc:
        log("connection ended: %s" % exc)
    finally:
        conn.close()


server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", PORT))
server.listen(8)
log("rfb server on %d" % PORT)
while True:
    c, _ = server.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
