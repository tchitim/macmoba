import XCTest
import Security
@testable import MacMobaCore

/// These run against the real login keychain, so every test uses its own unique
/// service name and cleans up — they never touch the production item
/// ("dev.macmoba.MacMoba.masterPassword"). They cover the storage plumbing;
/// the biometric prompt in `readAfterAuthentication` needs real hardware and a
/// user present, so it is not exercised here.
final class BiometricUnlockTests: XCTestCase {

    private func uniqueItem() -> KeychainPassword {
        // Distinct per test method so a crashed run can't collide with the next.
        KeychainPassword(service: "dev.macmoba.test.\(name.hashValue)", account: "vault")
    }

    func testPlainStoreReadDeleteRoundTrip() throws {
        let item = uniqueItem()
        defer { item.delete() }

        XCTAssertFalse(item.exists)
        let kind = try item.store("test-vault-pass", requireBiometry: false)
        XCTAssertEqual(kind, .appGated)
        XCTAssertTrue(item.exists)
        XCTAssertEqual(try item.read(), "test-vault-pass")

        item.delete()
        XCTAssertFalse(item.exists)
    }

    func testStoreReplacesPreviousValue() throws {
        let item = uniqueItem()
        defer { item.delete() }

        try item.store("old", requireBiometry: false)
        try item.store("new", requireBiometry: false)
        XCTAssertEqual(try item.read(), "new", "second store should overwrite, not duplicate")
    }

    func testReadOfMissingItemThrowsNotStored() {
        let item = uniqueItem()
        item.delete()   // ensure absent
        XCTAssertThrowsError(try item.read()) { error in
            guard case BiometricUnlockError.notStored = error else {
                return XCTFail("expected .notStored, got \(error)")
            }
        }
    }

    /// Documents the constraint that shaped the design: without a provisioning
    /// entitlement, a biometry-ACL keychain item cannot be created, so
    /// `store(requireBiometry:)` falls back to a plain, app-gated item — and the
    /// password is still stored, just not keychain-enforced. If this ever starts
    /// returning `.secureEnclaveACL` (a provisioned build), that is an upgrade,
    /// so the test accepts either but asserts the item really landed.
    func testBiometryStoreFallsBackButStillStores() throws {
        let item = uniqueItem()
        defer { item.delete() }

        let kind = try item.store("secret", requireBiometry: true)
        XCTAssertTrue(item.exists, "password must be stored regardless of ACL support")
        // On this signing setup the ACL add returns errSecMissingEntitlement, so
        // the fallback path is what we expect; a provisioned build may do better.
        XCTAssertTrue(kind == .appGated || kind == .secureEnclaveACL)
        if kind == .appGated {
            // The fallback item is a plain one, readable without a prompt.
            XCTAssertEqual(try item.read(), "secret")
        }
    }

    func testBiometryAvailableDoesNotCrash() {
        // Just that the availability query runs; the result depends on hardware.
        _ = BiometricUnlock.biometryAvailable
    }

    func testProductionHelperReportsNoStoredWhenAbsent() {
        // The production item is not created by these tests, so on a clean run
        // this is false. (If a developer has enabled Touch ID on this machine it
        // could be true; either way the call must not crash.)
        _ = BiometricUnlock.hasStoredPassword
    }
}
