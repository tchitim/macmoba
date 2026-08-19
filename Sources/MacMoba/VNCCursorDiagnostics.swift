// Why the remote cursor never changes shape.
//
// Over a Screen Sharing session the pointer stays an arrow: it does not become
// an I-beam over a text field, captured or not. Reading the library settles
// what is NOT wrong — the cursor pseudo-encoding is advertised to the server
// (`VNCConnection.swift:155`) and the reader follows the RFB layout — so the
// answer is in what actually arrives, and only a live session can say.
//
// Every cursor update passes through our own delegate, so counting them here
// separates the three possibilities without touching the library:
//
//   no updates at all      the server never sends this encoding
//   updates, all empty     decoding reads them as fully transparent, and
//                          RoyalVNC substitutes the arrow (VNCCursor+NSCursor
//                          .swift:12) — a library fix
//   updates, not empty     the cursor IS changing and our drawing is stale
//
// Kept because a "nothing happens" report is otherwise unanswerable.

import AppKit
import Foundation
import RoyalVNCKit

@MainActor
final class VNCCursorDiagnostics {
    private(set) var updates = 0
    private(set) var empty = 0
    private var lastDescription = "none"

    func record(_ cursor: VNCCursor) {
        updates += 1
        if cursor.isEmpty {
            empty += 1
            lastDescription = "empty (server sent it, or it decoded fully transparent)"
        } else {
            let hasImage = cursor.cgImage != nil
            lastDescription = "\(Int(cursor.size.width))×\(Int(cursor.size.height)), "
                + "\(cursor.bitsPerPixel) bpp, hotspot \(Int(cursor.hotspot.x)),\(Int(cursor.hotspot.y))"
                + (hasImage ? "" : " — but no CGImage could be built")
        }
    }

    var report: String {
        """
        MacMoba VNC cursor diagnostics
        cursor updates received: \(updates)
        of those, empty: \(empty)
        last cursor: \(lastDescription)
        """
    }

    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
