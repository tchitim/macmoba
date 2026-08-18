import Foundation
import RoyalVNCKit
import XCTest

/// Can MacMoba reach macOS Screen Sharing? Screen Sharing offers only Apple's
/// own security types (30/33/35/36), not classic VNC password auth, so the
/// question is whether our VNC stack speaks Apple's Diffie-Hellman handshake.
///
/// Run with MM_VNC_PROBE=1 and Screen Sharing enabled on this Mac. Credentials
/// are deliberately fake: reaching an authentication FAILURE proves the
/// handshake and ARD key exchange completed, which is the part in question.
final class VNCScreenSharingProbe: XCTestCase, VNCConnectionDelegate {
    private let done = XCTestExpectation(description: "connection settled")
    private var outcome = "no callback"
    private var askedForCredentialOfType = "none"
    private var negotiatedType: VNCAuthenticationType?

    func testProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MM_VNC_PROBE"] == "1", "probe")
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: "127.0.0.1",
            port: 5900,
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            // Same list the app uses.
            frameEncodings: [.copyRect, .zrle, .zlib, .hextile, .coRRE, .rre, .raw])
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        connection.connect()
        wait(for: [done], timeout: 25)
        connection.disconnect()
        print("PROBE-CREDENTIAL-TYPE: \(askedForCredentialOfType)")
        print("PROBE-OUTCOME: \(outcome)")

        // Screen Sharing offers only Apple's security types, so being asked for
        // an Apple Remote Desktop credential is the thing worth checking: it
        // means the RFB 003.889 handshake and the type-30 negotiation worked.
        XCTAssertEqual(negotiatedType, .appleRemoteDesktop,
                       "expected macOS Screen Sharing to negotiate ARD auth")
        // The credentials above are fake on purpose, so a rejection is success:
        // it can only come after the Diffie-Hellman exchange completed.
        XCTAssertTrue(outcome.contains("Authentication") || outcome == "CONNECTED",
                      "expected to reach authentication, got: \(outcome)")
    }

    func connection(_ connection: VNCConnection,
                    stateDidChange state: VNCConnection.ConnectionState) {
        switch state.status {
        case .connected: outcome = "CONNECTED"; done.fulfill()
        case .disconnected:
            outcome = "disconnected: " + (state.error?.localizedDescription ?? "no error")
            done.fulfill()
        default: break
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        negotiatedType = authenticationType
        askedForCredentialOfType = "\(authenticationType) requiresUsername="
            + "\(authenticationType.requiresUsername)"
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: "macmoba-probe-not-real",
                                                     password: "not-a-real-password"))
        } else {
            completion(VNCPasswordCredential(password: "not-a-real-password"))
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {}
    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}
    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {}
    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}
