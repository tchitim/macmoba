import AppKit
import Foundation
import RoyalVNCKit
import XCTest

/// Does copy/paste actually work in a VNC tab?
///
/// RoyalVNCKit does this itself when `isClipboardRedirectionEnabled` is set —
/// it watches NSPasteboard and sends ClientCutText, and writes ServerCutText
/// back to NSPasteboard — but "the setting is on" is not evidence, so this
/// drives both directions against a small RFB server that logs what it sees.
///
/// Needs that server:
///
///     python3 TestSupport/vnc-server.py 5999 /tmp/vnc-clip.log
///
/// Set MM_VNC_CLIPBOARD=/tmp/vnc-clip.log to run.
final class VNCClipboardTests: XCTestCase, VNCConnectionDelegate {
    private let connected = XCTestExpectation(description: "connected")
    private var lastError: String?

    private var logPath: String? {
        ProcessInfo.processInfo.environment["MM_VNC_CLIPBOARD"]
    }

    func testClipboardTravelsBothWays() throws {
        // Skipped, not failed, when the test server is not running — it also
        // takes over the clipboard, so it should not run unasked.
        try XCTSkipIf(logPath == nil, "set MM_VNC_CLIPBOARD to the server's log")
        let logPath = logPath!
        try XCTSkipUnless(FileManager.default.fileExists(atPath: logPath),
                          "RFB test server not running")

        // The developer's own clipboard is not ours to keep.
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("SENTINEL-BEFORE-VNC", forType: .string)

        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: "127.0.0.1",
            port: 5999,
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            // The setting under test.
            isClipboardRedirectionEnabled: true,
            colorDepth: .depth24Bit,
            frameEncodings: [.raw])
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        connection.connect()
        wait(for: [connected], timeout: 20)
        XCTAssertNil(lastError, "could not connect to the test RFB server")

        // Remote -> Mac: the server sends its clipboard 1.5s after connecting.
        var arrived: String?
        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let current = pasteboard.string(forType: .string)
            if current == "VNC-SERVER-COPIED-THIS" { arrived = current; break }
        }
        XCTAssertEqual(arrived, "VNC-SERVER-COPIED-THIS",
                       "text copied on the remote machine never reached the Mac clipboard")

        // Mac -> remote: copying here must arrive as a ClientCutText.
        let outgoing = "MAC-COPIED-THIS-4242"
        pasteboard.clearContents()
        pasteboard.setString(outgoing, forType: .string)

        var sawIt = false
        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            if log.contains("RECEIVED-CLIENT-CUT-TEXT: \(outgoing)") { sawIt = true; break }
        }
        XCTAssertTrue(sawIt, "the server never received what was copied on the Mac")

        connection.disconnect()
    }

    // MARK: - VNCConnectionDelegate

    func connection(_ connection: VNCConnection,
                    stateDidChange state: VNCConnection.ConnectionState) {
        switch state.status {
        case .connected:
            connected.fulfill()
        case .disconnected:
            if let error = state.error {
                lastError = error.localizedDescription
                connected.fulfill()
            }
        default: break
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        completion(nil)  // the test server asks for none
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {}
    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}
    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {}
    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}
