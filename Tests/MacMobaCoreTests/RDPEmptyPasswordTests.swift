import CMacMobaRDP
import XCTest

@testable import MacMobaCore

/// An EMPTY password must not stop the handshake.
///
/// The regression: `mm_authenticate` refused to supply credentials unless BOTH
/// a user name and a password were set, which aborted the connection during
/// the TLS handshake — before the server was ever asked. A CyberArk PSM file
/// carries a one-time token as the user name and no password at all, so it
/// could never connect. Whether an empty password is acceptable is the
/// server's decision to make.
///
/// Needs any TLS-capable RDP server; skipped when there is none:
///
///     docker run -d --name mm-xrdp -p 33890:3389 danielguerra/ubuntu-xrdp:20.04
final class RDPEmptyPasswordTests: XCTestCase {
    final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        var certificateSeen = false
        func note(_ text: String) { lock.lock(); events.append(text); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    func testTLSHandshakeReachesTheCertificateStage() throws {
        let port: Int32 = 33890
        // Skip unless the tunnel is up.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let reachable = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
        close(sock)
        try XCTSkipUnless(reachable, "no RDP server on 127.0.0.1:\(port)")

        let result = Result()
        let box = Unmanaged.passRetained(result).toOpaque()

        let onState: @convention(c) (UnsafeMutableRawPointer?, MacMobaRDPState,
                                     UnsafePointer<CChar>?) -> Void = { userData, state, message in
            guard let userData else { return }
            let result = Unmanaged<Result>.fromOpaque(userData).takeUnretainedValue()
            let text = message.map { String(cString: $0) } ?? ""
            result.note("state \(state.rawValue) \(text)")
        }
        let onCertificate: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
                                           UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                           Bool) -> Bool = { userData, _, commonName, _, _ in
            guard let userData else { return false }
            let result = Unmanaged<Result>.fromOpaque(userData).takeUnretainedValue()
            result.certificateSeen = true
            result.note("certificate offered, CN=\(commonName.map { String(cString: $0) } ?? "?")")
            // Refuse: this is a probe, it must not proceed into the session.
            return false
        }
        let onRelease: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
            guard let userData else { return }
            Unmanaged<Result>.fromOpaque(userData).release()
        }

        guard let rdp = macmoba_rdp_create(box, nil, onState, onCertificate, onRelease) else {
            return XCTFail("could not create the session")
        }
        XCTAssertTrue(macmoba_rdp_connect(rdp, "127.0.0.1", port, "probe", "", nil,
                                          1024, 768, 2 /* TLS */, false, nil, nil, 0, nil, 0),
                      "connection thread did not start")

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !result.certificateSeen,
              !result.all.contains(where: { $0.hasPrefix("state 2") }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        macmoba_rdp_free(rdp)

        print("PROBE EVENTS:")
        for event in result.all { print("   ", event) }
        XCTAssertTrue(result.certificateSeen,
                      "an empty password must still reach the certificate stage: \(result.all)")
        XCTAssertFalse(result.all.contains { $0.contains("no user name") },
                       "an empty PASSWORD is a credential; only a missing user name is fatal")
    }
}
