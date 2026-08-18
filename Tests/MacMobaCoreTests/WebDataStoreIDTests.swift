import XCTest

@testable import MacMobaCore

final class WebDataStoreIDTests: XCTestCase {
    /// Stability is the feature: a different id each launch would throw the
    /// cache away every time, which is the bug this replaced.
    func testTheSameSessionAlwaysGetsTheSameIdentifier() {
        XCTAssertEqual(WebDataStoreID.identifier(for: "langflow"),
                       WebDataStoreID.identifier(for: "langflow"))
    }

    /// Two internal sites must not share cookies.
    func testDifferentSessionsGetDifferentIdentifiers() {
        XCTAssertNotEqual(WebDataStoreID.identifier(for: "langflow"),
                          WebDataStoreID.identifier(for: "langfuse"))
        XCTAssertNotEqual(WebDataStoreID.identifier(for: ""),
                          WebDataStoreID.identifier(for: " "))
    }

    /// WebKit rejects the all-zero UUID.
    func testTheIdentifierIsNeverAllZeroes() {
        for id in ["", "a", "langflow", UUID().uuidString] {
            XCTAssertNotEqual(WebDataStoreID.identifier(for: id),
                              UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        }
    }
}
