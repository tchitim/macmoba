// JSON-backed store of pinned server identities, keyed "host:port".
//
// Used twice over: SSH host keys (known_hosts.json) and RDP server certificate
// fingerprints (rdp_certs.json). Lives here rather than in the app target
// because it is plain Foundation — and because the parsing in `allEntries` is
// worth testing.

import Foundation

/// known_hosts.json: { "host:port": "SHA256:..." }. Not secret material, so it
/// lives next to the vault rather than inside it (same as OpenSSH's model).
public final class KnownHostsStore: HostKeyStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: String]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public func storedFingerprint(host: String, port: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries["\(host):\(port)"]
    }

    public func store(fingerprint: String, host: String, port: Int) {
        lock.lock()
        entries["\(host):\(port)"] = fingerprint
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
    }

    /// Everything currently trusted, for review and revocation.
    public func allEntries() -> [(host: String, port: Int, fingerprint: String)] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.compactMap { key, fingerprint in
            // Split on the LAST colon: a bare IPv6 address is full of them, and
            // splitting on the first would turn "::1:22" into host "" port nil.
            guard let separator = key.lastIndex(of: ":"),
                  let port = Int(key[key.index(after: separator)...]) else { return nil }
            return (String(key[key.startIndex..<separator]), port, fingerprint)
        }
        .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    /// Forget one host. The next connection to it is treated as a first
    /// meeting — a prompt, not a "this changed" warning.
    public func remove(host: String, port: Int) {
        lock.lock()
        entries["\(host):\(port)"] = nil
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
    }

    /// Saves happen off the caller's thread — this is on the path of a
    /// connection being established — but on a **serial** queue.
    ///
    /// A concurrent queue is wrong here even though each write is atomic: two
    /// saves in quick succession can complete in either order, so the file can
    /// end up holding the earlier snapshot. Pinning a host and then forgetting
    /// it could leave the host still pinned on disk, which for a trust store is
    /// the wrong way to fail.
    private static let writeQueue = DispatchQueue(label: "dev.macmoba.known-hosts.write",
                                                  qos: .utility)

    private func persist(_ snapshot: [String: String]) {
        let url = fileURL
        Self.writeQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
