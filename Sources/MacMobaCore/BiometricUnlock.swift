// Touch ID convenience unlock: the vault master password is kept in the user's
// login keychain and handed back after a LocalAuthentication check succeeds.
//
// What actually protects the password here, honestly:
//
//   * The login keychain's own per-item ACL: by default only the app that
//     created the item can read it, so another app on the machine cannot.
//   * A LocalAuthentication gate we run before reading it, so a Touch ID (or
//     device-password) check stands between a click and the password.
//
// What does NOT happen, and why: the stronger option — a keychain item or a
// Secure Enclave key with a biometry SecAccessControl, where the *keychain*
// refuses to release the secret without biometry — needs the app to carry an
// `application-identifier` / `keychain-access-groups` entitlement, which in
// turn needs a provisioning profile from a paid membership. This build is
// Developer ID signed but has no such profile, so those calls fail with
// errSecMissingEntitlement (-34018), verified on this machine. The ACL attempt
// is still made (a future provisioned build lights it up automatically) but the
// working path is the login-keychain item above. The consequence to be aware
// of: the check is app-enforced, not cryptographically keychain-enforced, so
// the master password is recoverable by the app itself without biometry.
//
// The keychain plumbing lives in `KeychainPassword`, parameterised by
// service/account so it can be tested against an isolated item without ever
// touching the real one.

import Foundation
import LocalAuthentication
import Security

public enum BiometricUnlockError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case notStored
    case cancelled

    public var description: String {
        switch self {
        case .keychain(let status): return "keychain error \(status)"
        case .notStored: return "no stored master password"
        case .cancelled: return "cancelled"
        }
    }
}

/// A single generic-password item in the login keychain, with the ACL attempt
/// and plain fallback in one place so both are exercised by tests.
public struct KeychainPassword: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public enum StoreKind: Equatable, Sendable {
        /// The keychain itself enforces biometry (needs the entitlement).
        case secureEnclaveACL
        /// A plain item; a caller-side LocalAuthentication check is the gate.
        case appGated
    }

    private var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: account]
    }

    public var exists: Bool {
        SecItemCopyMatching(baseQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Store `password`, replacing any existing item. Tries a biometry ACL first
    /// when `requireBiometry` is set and reports which kind actually landed;
    /// throws only if even the plain write fails.
    @discardableResult
    public func store(_ password: String, requireBiometry: Bool) throws -> StoreKind {
        delete()
        if requireBiometry,
           let access = SecAccessControlCreateWithFlags(
               nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) {
            var guarded = baseQuery
            guarded[kSecAttrLabel] = "MacMoba vault master password"
            guarded[kSecAttrAccessControl] = access
            guarded[kSecValueData] = Data(password.utf8)
            if SecItemAdd(guarded as CFDictionary, nil) == errSecSuccess {
                return .secureEnclaveACL
            }
            // Fell through (typically errSecMissingEntitlement) — plain item.
        }
        var add = baseQuery
        add[kSecAttrLabel] = "MacMoba vault master password"
        add[kSecValueData] = Data(password.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw BiometricUnlockError.keychain(status) }
        return .appGated
    }

    /// Read the password. For an ACL item this triggers the keychain's own
    /// biometric prompt; for a plain item it returns immediately, so the caller
    /// is responsible for gating with LocalAuthentication first. Pass an
    /// already-authenticated `context` to avoid a second prompt on ACL items.
    public func read(using context: LAContext? = nil) throws -> String {
        var query = baseQuery
        query[kSecReturnData] = true
        if let context { query[kSecUseAuthenticationContext] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw status == errSecItemNotFound
                ? BiometricUnlockError.notStored
                : BiometricUnlockError.keychain(status)
        }
        return password
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

public enum BiometricUnlock {
    private static let item = KeychainPassword(
        service: "dev.macmoba.MacMoba.masterPassword", account: "vault")

    /// Touch ID (or Apple Watch) present and enrolled?
    public static var biometryAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public static var hasStoredPassword: Bool { item.exists }

    /// True when the last successful `store` used a keychain-enforced biometry
    /// ACL rather than the app-gated fallback. False on this build (no
    /// provisioning entitlement); see the file header.
    public private(set) static var usesSecureEnclaveACL = false

    public static func store(_ password: String) throws {
        let kind = try item.store(password, requireBiometry: true)
        usesSecureEnclaveACL = (kind == .secureEnclaveACL)
    }

    public static func delete() { item.delete() }

    /// Prompt Touch ID (falls back to the device password), then return the
    /// stored master password.
    public static func readAfterAuthentication() async throws -> String {
        let context = LAContext()
        context.localizedCancelTitle = "Use Master Password"
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "unlock the MacMoba vault")
        } catch let laError as LAError
            where laError.code == .userCancel || laError.code == .appCancel
                || laError.code == .systemCancel || laError.code == .userFallback {
            throw BiometricUnlockError.cancelled
        }
        // Reuse the authenticated context so an ACL item (provisioned builds)
        // does not prompt a second time; a plain item ignores it.
        return try item.read(using: context)
    }
}
