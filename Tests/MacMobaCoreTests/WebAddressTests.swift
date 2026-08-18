import XCTest

@testable import MacMobaCore

/// The address bar of a browser whose reason to exist is reaching private
/// hosts. The dangerous mistake is treating an internal hostname as a search
/// term, which hands the name of a private machine to a search engine.
final class WebAddressTests: XCTestCase {
    func testFullURLsPassThrough() {
        XCTAssertEqual(WebAddress.url(for: "https://example.com/a?b=c")?.absoluteString,
                       "https://example.com/a?b=c")
        XCTAssertEqual(WebAddress.url(for: "http://10.0.0.5:8080/status")?.absoluteString,
                       "http://10.0.0.5:8080/status")
    }

    func testBareHostsGetHTTP() {
        XCTAssertEqual(WebAddress.url(for: "internal.corp")?.absoluteString,
                       "http://internal.corp")
        XCTAssertEqual(WebAddress.url(for: "192.0.2.5")?.absoluteString,
                       "http://192.0.2.5")
        XCTAssertEqual(WebAddress.url(for: "192.0.2.5:8080/x")?.absoluteString,
                       "http://192.0.2.5:8080/x")
    }

    /// On a corporate network "wiki" IS a hostname. Searching for it would
    /// send an internal name off the machine.
    func testABareWordIsTreatedAsAHostNotASearch() {
        XCTAssertEqual(WebAddress.url(for: "wiki", searchTemplate: "https://s/?q=%s")?
                        .absoluteString, "http://wiki")
        XCTAssertEqual(WebAddress.url(for: "jenkins")?.absoluteString, "http://jenkins")
    }

    /// A sentence is not a host.
    func testTextWithSpacesSearchesWhenAsked() {
        XCTAssertEqual(
            WebAddress.url(for: "how to restart nginx", searchTemplate: "https://s/?q=%s")?
                .absoluteString,
            "https://s/?q=how%20to%20restart%20nginx")
    }

    /// With no search engine configured, a phrase is simply not addressable —
    /// better nothing than an accidental leak.
    func testNoSearchTemplateMeansNoSearch() {
        XCTAssertNil(WebAddress.url(for: "how to restart nginx"))
    }

    func testEmptyInputIsNil() {
        XCTAssertNil(WebAddress.url(for: ""))
        XCTAssertNil(WebAddress.url(for: "   "))
    }

    /// A web view has no business opening these.
    func testOtherSchemesAreRefused() {
        XCTAssertNil(WebAddress.url(for: "mailto:someone@example.com"))
        XCTAssertNil(WebAddress.url(for: "ssh://host"))
        XCTAssertNil(WebAddress.url(for: "javascript:alert(1)"))
    }

    func testHostShapes() {
        XCTAssertTrue(WebAddress.looksLikeHost("host"))
        XCTAssertTrue(WebAddress.looksLikeHost("host.example.com"))
        XCTAssertTrue(WebAddress.looksLikeHost("host:8080"))
        XCTAssertTrue(WebAddress.looksLikeHost("host/path/here"))
        XCTAssertTrue(WebAddress.looksLikeHost("192.168.1.1"))
        XCTAssertTrue(WebAddress.looksLikeHost("[2001:db8::1]"))

        XCTAssertFalse(WebAddress.looksLikeHost("two words"))
        XCTAssertFalse(WebAddress.looksLikeHost("-leading-dash"))
        XCTAssertFalse(WebAddress.looksLikeHost("host:notaport"))
        XCTAssertFalse(WebAddress.looksLikeHost("host:99999"))
        XCTAssertFalse(WebAddress.looksLikeHost("what?"))
    }

    func testDisplayDropsTheNoise() {
        XCTAssertEqual(WebAddress.display(URL(string: "http://wiki/")!), "wiki")
        XCTAssertEqual(WebAddress.display(URL(string: "https://example.com/a")!),
                       "https://example.com/a")
        XCTAssertEqual(WebAddress.display(URL(string: "http://10.0.0.5:8080/x")!),
                       "10.0.0.5:8080/x")
    }
}
