import XCTest

@testable import MacMobaCore

final class SessionSearchTests: XCTestCase {
    private func session(name: String = "prod-web-01", host: String = "10.0.0.5",
                         username: String = "root", group: String? = "Production",
                         notes: String? = nil, tags: [String]? = nil,
                         webURL: String? = nil) -> SessionConfig {
        var s = SessionConfig(id: "s", name: name, host: host, port: 22,
                              username: username, authType: "password")
        s.group = group
        s.notes = notes
        s.tags = tags
        s.webURL = webURL
        return s
    }

    // MARK: - matching

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(SessionSearch.matches(session(), query: ""))
        XCTAssertTrue(SessionSearch.matches(session(), query: "   "))
    }

    func testMatchesNameHostUserGroupCaseInsensitively() {
        let s = session()
        XCTAssertTrue(SessionSearch.matches(s, query: "PROD"))
        XCTAssertTrue(SessionSearch.matches(s, query: "10.0.0"))
        XCTAssertTrue(SessionSearch.matches(s, query: "root"))
        XCTAssertTrue(SessionSearch.matches(s, query: "production"))
        XCTAssertFalse(SessionSearch.matches(s, query: "staging"))
    }

    func testMatchesTagsAndNotes() {
        let s = session(notes: "renew TLS cert in March", tags: ["kubernetes", "eu-west"])
        XCTAssertTrue(SessionSearch.matches(s, query: "kubern"))
        XCTAssertTrue(SessionSearch.matches(s, query: "EU-WEST"))
        XCTAssertTrue(SessionSearch.matches(s, query: "tls cert"))
        XCTAssertFalse(SessionSearch.matches(s, query: "postgres"))
    }

    func testMatchesWebURL() {
        let s = session(host: "", webURL: "http://internal.corp:8080/status")
        XCTAssertTrue(SessionSearch.matches(s, query: "internal.corp"))
    }

    // MARK: - tag normalisation

    func testNormalizeTrimsDropsEmptiesAndDedupes() {
        XCTAssertEqual(SessionSearch.normalizedTags("prod, web ,, prod ,PROD"),
                       ["prod", "web"])
    }

    func testNormalizeEmptyInputGivesNoTags() {
        XCTAssertEqual(SessionSearch.normalizedTags(""), [])
        XCTAssertEqual(SessionSearch.normalizedTags("  ,  , "), [])
    }

    func testNormalizeKeepsFirstSpelling() {
        XCTAssertEqual(SessionSearch.normalizedTags("Prod, prod"), ["Prod"])
    }

    func testTagStringRoundTrips() {
        let tags = SessionSearch.normalizedTags("db, eu-west, primary")
        XCTAssertEqual(SessionSearch.tagString(tags), "db, eu-west, primary")
        XCTAssertEqual(SessionSearch.tagString(nil), "")
    }
}
