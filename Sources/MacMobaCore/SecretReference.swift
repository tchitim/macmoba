// A password that is fetched at connect time instead of stored in the vault.
//
// Two forms are understood:
//
//   op://vault/item/field   — read from 1Password with its `op` CLI
//   cmd:some shell command  — run the command; its output is the secret
//
// The `cmd:` form is the general escape hatch — `security find-generic-password`
// for the macOS Keychain, `pass`, `lpass show`, `keepassxc-cli`, anything that
// prints a secret — so one mechanism covers every password manager. Anything
// else is a literal password, exactly as before.
//
// This type only decides WHAT to run; running it (a subprocess) belongs to the
// app, so the classification stays pure and testable.

import Foundation

public enum SecretReference: Equatable, Sendable {
    case literal(String)
    case onePassword(String)   // the whole "op://…" reference
    case command(String)       // the shell command, without the "cmd:" prefix

    public static let onePasswordPrefix = "op://"
    public static let commandPrefix = "cmd:"

    /// Classify a stored password.
    ///
    /// People paste references straight out of shell examples, quotes and all —
    /// `"op://Vault/item/password"` — and macOS may curl the quotes on the way.
    /// If unwrapping whitespace and one pair of quotes reveals a reference, it
    /// is honored (unquoted). Otherwise the RAW string is the literal password,
    /// untouched: quotes and spaces are legal in real passwords, so nothing is
    /// stripped from a value that is not a reference.
    public static func parse(_ raw: String) -> SecretReference {
        let unwrapped = unquoted(raw)
        if unwrapped.hasPrefix(onePasswordPrefix) {
            return .onePassword(unwrapped)
        }
        if unwrapped.hasPrefix(commandPrefix) {
            return .command(String(unwrapped.dropFirst(commandPrefix.count)))
        }
        return .literal(raw)
    }

    /// `raw` minus surrounding whitespace and ONE matching pair of quotes —
    /// straight ("", '') or the curly ones macOS smart-substitution produces.
    private static func unquoted(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
        ]
        if s.count >= 2, let first = s.first, let last = s.last,
           pairs.contains(where: { $0.0 == first && $0.1 == last }) {
            s = String(s.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    public var isReference: Bool {
        switch self {
        case .literal: return false
        case .onePassword, .command: return true
        }
    }

    /// The argv to run to fetch this secret, or nil for a literal (nothing to
    /// run). `op` is invoked through `env` so it is found on the user's PATH;
    /// `--no-newline` keeps its output from carrying a trailing newline.
    public func fetchArgv() -> [String]? {
        switch self {
        case .literal:
            return nil
        case .onePassword(let ref):
            return ["/usr/bin/env", "op", "read", "--no-newline", ref]
        case .command(let cmd):
            return ["/bin/sh", "-c", cmd]
        }
    }
}
