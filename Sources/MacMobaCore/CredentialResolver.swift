// Turning "which login should this session use?" into a concrete answer.
//
// A session can get its credentials three ways, and the whole point of the
// feature is that they compose predictably:
//
//   1. Its own inline fields              (credentialRef nil / "" / "custom")
//   2. A named shared credential          (credentialRef = that credential's id)
//   3. Whatever its group inherits         (credentialRef = "inherit")
//
// Everything downstream — the SSH auth delegate, SFTP, the RDP domain, the
// SOCKS tunnel — reads username/password/key straight off a SessionConfig and
// knows nothing about credentials. So resolution's job is simply to hand back a
// SessionConfig with those fields filled in, leaving host/port/kind untouched.
// Resolve at connect time; never rewrite what is stored.

import Foundation

public enum CredentialResolver {
    /// The sentinel `credentialRef` meaning "use the group's default".
    public static let inherit = "inherit"

    /// Where a session's login actually comes from, for showing in the UI.
    public enum Source: Equatable, Sendable {
        /// The session's own inline fields.
        case custom
        /// A named shared credential.
        case credential(id: String)
        /// The group's default credential resolved to a concrete one.
        case inheritedFromGroup(credentialID: String)
        /// Set to inherit, but the group has no default (or it is missing) —
        /// so the inline fields are used and the UI should say so.
        case inheritedButNone
    }

    /// The credential a session effectively uses, or nil when it uses its own
    /// inline fields. `groupCredentials` maps a group name to a credential id.
    public static func effectiveCredential(
        for session: SessionConfig,
        credentials: [CredentialConfig],
        groupCredentials: [String: String]
    ) -> CredentialConfig? {
        switch source(for: session, credentials: credentials,
                      groupCredentials: groupCredentials) {
        case .custom, .inheritedButNone:
            return nil
        case .credential(let id), .inheritedFromGroup(let id):
            return credentials.first { $0.id == id }
        }
    }

    /// How a session gets its login. Kept separate from `effectiveCredential`
    /// so the editor can tell "inherit, but nothing set" apart from "custom".
    public static func source(
        for session: SessionConfig,
        credentials: [CredentialConfig],
        groupCredentials: [String: String]
    ) -> Source {
        let ref = (session.credentialRef ?? "").trimmingCharacters(in: .whitespaces)
        if ref.isEmpty || ref == "custom" {
            return .custom
        }
        if ref == inherit {
            let group = (session.group ?? "").trimmingCharacters(in: .whitespaces)
            guard !group.isEmpty else { return .inheritedButNone }
            // Walk the folder path upward (Royal TSX-style inheritance): a
            // session in "Production/Linux" uses that folder's default if set,
            // otherwise "Production"'s — the nearest ancestor wins.
            var candidate: String? = group
            while let g = candidate {
                if let id = groupCredentials[g],
                   credentials.contains(where: { $0.id == id }) {
                    return .inheritedFromGroup(credentialID: id)
                }
                candidate = GroupTree.parent(of: g)
            }
            return .inheritedButNone
        }
        // A specific credential id — but only if it still exists. A deleted
        // credential must fall back to the inline fields rather than silently
        // logging in as an empty user.
        if credentials.contains(where: { $0.id == ref }) {
            return .credential(id: ref)
        }
        return .custom
    }

    /// `session` with its login fields filled in from the effective credential.
    /// When the session uses its own inline fields, it is returned unchanged.
    ///
    /// Only the login is replaced. A credential does not carry a domain for a
    /// non-RDP session, and where it has none the session keeps its own — so a
    /// shared credential never blanks out a field the session had set itself.
    public static func resolve(
        _ session: SessionConfig,
        credentials: [CredentialConfig],
        groupCredentials: [String: String]
    ) -> SessionConfig {
        guard let credential = effectiveCredential(for: session, credentials: credentials,
                                                   groupCredentials: groupCredentials) else {
            return session
        }
        var resolved = session
        resolved.username = credential.username
        resolved.authType = credential.authType
        resolved.password = credential.password
        resolved.keyPath = credential.keyPath
        resolved.keyData = credential.keyData
        resolved.passphrase = credential.passphrase
        if let domain = credential.domain, !domain.isEmpty {
            resolved.domain = domain
        }
        return resolved
    }
}
