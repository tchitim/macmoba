// A terminal carried over a serial line, so a pane can drive a switch console,
// a microcontroller or a modem the same way it drives SSH.
//
// Opening the device, setting the line parameters with termios, and pumping
// bytes both ways is all there is to it — there is no protocol above the wire.
// A background thread selects on the device and forwards bytes to onData;
// write() pokes the fd directly. resize() is a no-op: a serial line has no idea
// how big the terminal is.
//
// close() cannot just close the fd: on macOS closing an fd that another thread
// is parked reading does not reliably wake that read(), so the thread would
// leak. Instead the read loop selects on both the device and one end of a
// self-pipe; close() writes a byte to the pipe, the select returns, the loop
// sees the stopping flag and exits, and only then is the device fd closed.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

public final class SerialConnection: @unchecked Sendable {
    private let fd: Int32
    private let wakePipe: (read: Int32, write: Int32)
    private let onData: (Data) -> Void
    private let onExit: (String) -> Void
    private let readThread: Thread
    private let stopping = ManagedAtomicFlag()

    private init(fd: Int32, wakePipe: (read: Int32, write: Int32),
                 onData: @escaping (Data) -> Void,
                 onExit: @escaping (String) -> Void) {
        self.fd = fd
        self.wakePipe = wakePipe
        self.onData = onData
        self.onExit = onExit
        let box = ReadLoopBox(fd: fd, wakeFd: wakePipe.read, onData: onData,
                              onExit: onExit, stopping: stopping)
        readThread = Thread { box.run() }
        readThread.name = "macmoba.serial.read"
        readThread.stackSize = 1 << 20
        readThread.start()
    }

    /// Open `device` (a `/dev/cu.*` path) and configure the line. Throws if the
    /// device cannot be opened or configured — a friendlier failure than a pane
    /// that silently shows nothing.
    public static func connect(
        device: String,
        settings: SerialSettings,
        onData: @escaping (Data) -> Void,
        onExit: @escaping (String) -> Void
    ) throws -> SerialConnection {
        let fd = open(device, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw SerialError.openFailed(device, String(cString: strerror(errno)))
        }
        do {
            try configure(fd: fd, settings: settings)
        } catch {
            Darwin.close(fd)
            throw error
        }
        // Back to blocking so the read thread parks in select() instead of spinning.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        // Self-pipe used by close() to wake the parked select().
        var pipeFds: [Int32] = [0, 0]
        guard pipe(&pipeFds) == 0 else {
            Darwin.close(fd)
            throw SerialError.configureFailed("could not create wake pipe")
        }
        // If the read loop reaches EOF first it closes the pipe's read end, so a
        // later close() would write to a reader-less pipe. Ask for EPIPE instead
        // of a process-killing SIGPIPE.
        _ = fcntl(pipeFds[1], F_SETNOSIGPIPE, 1)
        return SerialConnection(fd: fd, wakePipe: (pipeFds[0], pipeFds[1]),
                                onData: onData, onExit: onExit)
    }

    private static func configure(fd: Int32, settings: SerialSettings) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            throw SerialError.configureFailed(String(cString: strerror(errno)))
        }
        cfmakeraw(&options)                 // no echo, no line editing, no translation
        let speed = speed_t(settings.baud)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        options.c_cflag |= tcflag_t(CLOCAL | CREAD)   // ignore modem lines, enable receiver
        // Data bits.
        options.c_cflag &= ~tcflag_t(CSIZE)
        switch settings.dataBits {
        case 5: options.c_cflag |= tcflag_t(CS5)
        case 6: options.c_cflag |= tcflag_t(CS6)
        case 7: options.c_cflag |= tcflag_t(CS7)
        default: options.c_cflag |= tcflag_t(CS8)
        }
        // Parity.
        switch settings.parity {
        case .none: options.c_cflag &= ~tcflag_t(PARENB)
        case .even: options.c_cflag |= tcflag_t(PARENB); options.c_cflag &= ~tcflag_t(PARODD)
        case .odd: options.c_cflag |= tcflag_t(PARENB | PARODD)
        }
        // Stop bits.
        if settings.stopBits == 2 { options.c_cflag |= tcflag_t(CSTOPB) }
        else { options.c_cflag &= ~tcflag_t(CSTOPB) }
        // No hardware flow control.
        options.c_cflag &= ~tcflag_t(CRTSCTS)

        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            throw SerialError.configureFailed(String(cString: strerror(errno)))
        }
    }

    public func write(_ data: Data) {
        guard !stopping.isSet else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    public func resize(cols: Int, rows: Int) { /* a serial line has no window size */ }

    public func close() {
        guard !stopping.testAndSet() else { return }
        // Wake the parked select() so the read loop notices the flag and returns
        // before we pull the device fd out from under it.
        var byte: UInt8 = 1
        _ = Darwin.write(wakePipe.write, &byte, 1)
        readThread.cancel()
        // The loop closes `fd`; we own the pipe ends.
        Darwin.close(wakePipe.write)
    }
}

public enum SerialError: Error, CustomStringConvertible {
    case openFailed(String, String)
    case configureFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let device, let reason):
            return "Could not open \(device): \(reason)"
        case .configureFailed(let reason):
            return "Could not configure the serial port: \(reason)"
        }
    }
}

/// The read loop, kept off the main actor. It owns nothing but the fd it was
/// given and the callbacks; the connection outlives it via the stopping flag.
private final class ReadLoopBox: @unchecked Sendable {
    let fd: Int32
    let wakeFd: Int32
    let onData: (Data) -> Void
    let onExit: (String) -> Void
    let stopping: ManagedAtomicFlag

    init(fd: Int32, wakeFd: Int32, onData: @escaping (Data) -> Void,
         onExit: @escaping (String) -> Void, stopping: ManagedAtomicFlag) {
        self.fd = fd
        self.wakeFd = wakeFd
        self.onData = onData
        self.onExit = onExit
        self.stopping = stopping
    }

    func run() {
        // The loop owns the device fd and the read end of the wake pipe: it is
        // the last one to touch them, so it closes them on the way out and
        // close() never races a read() against a freed fd.
        defer { Darwin.close(fd); Darwin.close(wakeFd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let maxFd = max(fd, wakeFd)
        while !stopping.isSet {
            var set = fd_set()
            fdZero(&set)
            fdSet(fd, &set)
            fdSet(wakeFd, &set)
            let ready = select(maxFd + 1, &set, nil, nil, nil)
            if ready < 0 {
                if errno == EINTR { continue }
                if !stopping.isSet { onExit(String(cString: strerror(errno))) }
                return
            }
            // close() poked the wake pipe — leave quietly, no onExit.
            if stopping.isSet || fdIsSet(wakeFd, &set) { return }
            guard fdIsSet(fd, &set) else { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onData(Data(buffer[0..<n]))
            } else if n == 0 {
                if !stopping.isSet { onExit("serial device closed") }
                return
            } else {
                if errno == EINTR || errno == EAGAIN { continue }
                if !stopping.isSet { onExit(String(cString: strerror(errno))) }
                return
            }
        }
    }
}

// fd_set helpers — Swift does not surface the FD_ZERO/FD_SET/FD_ISSET macros.
private func fdZero(_ set: inout fd_set) {
    bzero(&set, MemoryLayout<fd_set>.size)
}
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: Int(FD_SETSIZE) / 32) {
            $0[Int(fd) / 32] |= Int32(1) << (Int32(fd) % 32)
        }
    }
}
private func fdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: Int(FD_SETSIZE) / 32) {
            ($0[Int(fd) / 32] & (Int32(1) << (Int32(fd) % 32))) != 0
        }
    }
}

/// A minimal thread-safe flag — set once, never cleared. Avoids pulling in
/// swift-atomics for one boolean.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }

    /// Set the flag; returns the PREVIOUS value.
    @discardableResult
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = true
        return old
    }
}
