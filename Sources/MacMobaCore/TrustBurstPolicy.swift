// "Trust the other new hosts too" — one decision for a burst of first-time
// connections, without weakening the check that actually matters.
//
// Opening a folder of ten machines asks about ten host keys, and nobody
// compares ten fingerprints out of band; they click Trust ten times. That is
// the same trust-on-first-use decision made ten times over, so this lets the
// user make it once, for a short window.
//
// The line this must never cross: a host key that CHANGED is the man-in-the-
// middle signal. A changed key is always asked about individually, no matter
// how wide the window is open — `allowsAutoTrust` refuses it by construction.

import Foundation

public struct TrustBurstPolicy: Equatable, Sendable {
    /// Default width of the window: long enough for a folder of machines to
    /// finish connecting (jump-host chains included), short enough that it
    /// cannot quietly cover a connection made much later.
    public static let defaultDuration: TimeInterval = 120

    /// When the current burst stops applying; nil when no burst is open.
    public private(set) var openUntil: Date?

    public init() {}

    /// Start (or extend) the window.
    public mutating func open(now: Date = Date(),
                              duration: TimeInterval = TrustBurstPolicy.defaultDuration) {
        openUntil = now.addingTimeInterval(duration)
    }

    public mutating func close() {
        openUntil = nil
    }

    /// Whether this prompt can be answered from the burst instead of by the
    /// user. Only ever true for a first-time key inside an open window.
    public func allowsAutoTrust(isChangedKey: Bool, now: Date = Date()) -> Bool {
        // A changed key is exactly what host-key checking exists to catch.
        guard !isChangedKey else { return false }
        guard let openUntil else { return false }
        return now < openUntil
    }

    public func isOpen(now: Date = Date()) -> Bool {
        guard let openUntil else { return false }
        return now < openUntil
    }
}
