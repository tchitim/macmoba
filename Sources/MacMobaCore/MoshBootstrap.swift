// Starting a Mosh session.
//
// Mosh is two halves. The SSH half runs `mosh-server new` on the remote and
// reads back a UDP port and a session key; the UDP half is mosh-client talking
// SSP to that port. This file is the first half plus the parsing between them,
// kept separate from any process spawning so it can be tested.

import Foundation

public struct MoshSession: Equatable {
    /// UDP port mosh-server is listening on.
    public let port: Int
    /// Base64 session key. This is the whole security of the session — it is
    /// passed to mosh-client through the environment rather than argv, because
    /// argv is world-readable in `ps`.
    public let key: String

    public init(port: Int, key: String) {
        self.port = port
        self.key = key
    }
}

public enum MoshError: Error, LocalizedError, Equatable {
    case serverNotFound
    case noConnectLine(String)
    case malformedConnectLine(String)

    public var errorDescription: String? {
        switch self {
        case .serverNotFound:
            return "mosh-server is not installed on the remote host. "
                 + "Install it there (for example: apt install mosh, or dnf install mosh)."
        case .noConnectLine(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "mosh-server produced no output."
                : "mosh-server did not start. It said:\n\(trimmed)"
        case .malformedConnectLine(let line):
            return "Could not understand mosh-server's reply: \(line)"
        }
    }
}

public enum MoshBootstrap {
    /// The command run over SSH. `new` asks for a fresh session; `-s` binds to
    /// the address SSH came from, which is what makes this work through a NAT
    /// or a jump host without naming an address ourselves.
    ///
    /// The locale matters more than it looks: mosh-server refuses to start
    /// unless it is in a UTF-8 locale, and the message it gives is not obvious.
    public static func serverCommand(locale: String = "en_US.UTF-8") -> String {
        "LANG=\(locale) LC_ALL=\(locale) mosh-server new -s -c 256"
    }

    /// Pulls the port and key out of mosh-server's greeting.
    ///
    /// The line looks like:
    ///     MOSH CONNECT 60001 rEzBna3rEz9zLTMHtLYQEg
    ///
    /// It is not necessarily alone: a login shell may have printed a banner,
    /// motd, or warnings first, so this scans rather than assuming line one.
    public static func parse(_ output: String) throws -> MoshSession {
        // A missing binary shows up as the shell's own complaint, and saying so
        // plainly is far more useful than "could not parse".
        //
        // The wording is per-shell and the word order differs: bash and sh put
        // the name first ("mosh-server: command not found"), zsh puts it last
        // ("command not found: mosh-server"). Match on both parts being
        // present rather than on either phrasing.
        let lowered = output.lowercased()
        let looksMissing = ["command not found", "not found", "no such file or directory"]
            .contains { lowered.contains($0) }
        if looksMissing && lowered.contains("mosh-server") {
            throw MoshError.serverNotFound
        }

        guard let line = output
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("MOSH CONNECT") })
        else {
            throw MoshError.noConnectLine(output)
        }

        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4,
              let port = Int(fields[2]),
              (1...65535).contains(port)
        else {
            throw MoshError.malformedConnectLine(line)
        }
        let key = String(fields[3])
        guard !key.isEmpty else { throw MoshError.malformedConnectLine(line) }
        return MoshSession(port: port, key: key)
    }

    /// Where mosh-client should send its UDP packets.
    ///
    /// Deliberately the address the *session* was configured with, not anything
    /// mosh-server reports: with `-s` the server binds to whatever interface the
    /// SSH connection arrived on, and that is reachable from here by definition.
    public static func datagramHost(for config: SessionConfig) -> String {
        config.host
    }
}
