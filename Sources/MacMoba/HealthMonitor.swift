// Background reachability polling for the sidebar's status lights.
//
// Off by default — probing every saved host on a timer is network noise you
// should opt into. When on, it walks the checkable sessions on a background
// queue (so the UI never blocks on a slow host), throttles concurrency so a
// hundred hosts do not open a hundred sockets at once, and republishes results
// on the main actor for the rows to read.

import Combine
import Foundation
import MacMobaCore

@MainActor
final class HealthMonitor: ObservableObject {
    /// Latest result per session id. Absent means "not checked yet".
    @Published var status: [String: Reachability] = [:]
    @Published var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    /// How often a full sweep runs, and how long each probe waits.
    private let interval: TimeInterval = 15
    private let timeout: TimeInterval = 2
    private var timer: Timer?
    private var sweeping = false

    /// The sessions to watch — refreshed by the view from the vault each sweep.
    var sessionsProvider: () -> [SessionConfig] = { [] }
    /// How to test a host that only the bastion can see. Set by AppState.
    var jumpProbe: ((SessionConfig) async -> Reachability)?
    /// True while a jump-host check is running, so the button can say so.
    @Published private(set) var checkingViaJump = false

    /// Check hosts behind a bastion, on demand. Sequential on purpose: these
    /// are SSH logins, and a folder of ten machines must not open ten at once.
    func checkViaJump(_ sessions: [SessionConfig]) {
        guard let jumpProbe, !checkingViaJump else { return }
        let targets = sessions.filter { !$0.isDirectlyProbeable && $0.reachabilityTarget != nil }
        guard !targets.isEmpty else { return }
        checkingViaJump = true
        Task {
            for session in targets {
                let result = await jumpProbe(session)
                status[session.id] = result
            }
            checkingViaJump = false
        }
    }

    private func start() {
        sweep()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        status = [:]
    }

    /// Probe every checkable session once, now. Safe to call from the UI.
    func sweep() {
        guard isEnabled, !sweeping else { return }
        let targets: [(id: String, host: String, port: Int)] = sessionsProvider().compactMap {
            // Jump-host sessions are deliberately not polled — see
            // isDirectlyProbeable. They show as unchecked, not as down.
            guard $0.isDirectlyProbeable, let t = $0.reachabilityTarget else { return nil }
            return ($0.id, t.host, t.port)
        }
        guard !targets.isEmpty else { return }
        sweeping = true
        let timeout = self.timeout

        Task.detached(priority: .utility) {
            // Bounded concurrency: a handful of probes in flight, not all of them.
            let results = await withTaskGroup(of: (String, Reachability).self) { group -> [(String, Reachability)] in
                var out: [(String, Reachability)] = []
                var iterator = targets.makeIterator()
                let limit = 8
                var inFlight = 0
                func addNext() {
                    guard let t = iterator.next() else { return }
                    inFlight += 1
                    group.addTask {
                        (t.id, ReachabilityProbe.check(host: t.host, port: t.port, timeout: timeout))
                    }
                }
                for _ in 0..<limit { addNext() }
                while let r = await group.next() {
                    out.append(r)
                    inFlight -= 1
                    addNext()
                }
                return out
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, r) in results { self.status[id] = r }
                self.sweeping = false
            }
        }
    }
}
