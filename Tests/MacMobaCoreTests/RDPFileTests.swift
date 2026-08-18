import XCTest

@testable import MacMobaCore

/// Reading .rdp files — the ones mstsc writes, and the ones CyberArk PSM
/// generates per session.
final class RDPFileTests: XCTestCase {
    private let sample = """
    screen mode id:i:2
    use multimon:i:1
    desktopwidth:i:1920
    desktopheight:i:1080
    session bpp:i:32
    full address:s:psm.example.com:3389
    username:s:TESTDOMAIN\\PSMConnect
    audiomode:i:0
    redirectclipboard:i:1
    enablecredsspsupport:i:1
    alternate shell:s:psm /u admin@target /a 10.0.0.5 /c PSM-RDP
    """

    // MARK: Encoding

    /// Windows writes these as UTF-16LE with a BOM. Read as UTF-8 the file
    /// looks like every character has a NUL after it and nothing parses at all.
    func testUTF16LittleEndianWithBOM() {
        var data = Data([0xFF, 0xFE])
        data.append("full address:s:host.example.com\r\n".data(using: .utf16LittleEndian)!)
        let file = RDPFileParser.parse(data)
        XCTAssertEqual(file.string("full address"), "host.example.com")
    }

    func testUTF16BigEndianWithBOM() {
        var data = Data([0xFE, 0xFF])
        data.append("full address:s:host.example.com".data(using: .utf16BigEndian)!)
        XCTAssertEqual(RDPFileParser.parse(data).string("full address"), "host.example.com")
    }

    func testUTF8WithAndWithoutBOM() {
        let plain = "full address:s:plain.example.com".data(using: .utf8)!
        XCTAssertEqual(RDPFileParser.parse(plain).string("full address"), "plain.example.com")
        var withBOM = Data([0xEF, 0xBB, 0xBF])
        withBOM.append(plain)
        XCTAssertEqual(RDPFileParser.parse(withBOM).string("full address"), "plain.example.com")
    }

    /// Some tools strip the BOM but keep UTF-16 bytes.
    func testUTF16WithoutABOMIsStillReadable() {
        let data = "full address:s:nobom.example.com".data(using: .utf16LittleEndian)!
        XCTAssertEqual(RDPFileParser.parse(data).string("full address"), "nobom.example.com")
    }

    // MARK: Parsing

    /// The value routinely contains colons, so only the first two may split.
    func testValuesMayContainColons() {
        let file = RDPFileParser.parse(text: "full address:s:host.example.com:3389")
        XCTAssertEqual(file.string("full address"), "host.example.com:3389")
    }

    func testKeysAreCaseInsensitiveAndBlankValuesAreNil() {
        let file = RDPFileParser.parse(text: "Full Address:s:HOST\r\ndomain:s:\r\n")
        XCTAssertEqual(file.string("full address"), "HOST")
        XCTAssertNil(file.string("domain"), "an empty value is not a value")
    }

    func testMalformedLinesAreIgnored() {
        let file = RDPFileParser.parse(text: "not a setting\r\n\r\n:s:novalue\r\nusername:s:tim")
        XCTAssertEqual(file.settings.count, 1)
        XCTAssertEqual(file.string("username"), "tim")
    }

    // MARK: Mapping to a session

    func testHostPortUserAndDomain() {
        let file = RDPFileParser.parse(text: sample)
        let (config, _) = RDPFileParser.session(from: file, name: "PSM")
        XCTAssertEqual(config.host, "psm.example.com")
        XCTAssertEqual(config.port, 3389)
        XCTAssertEqual(config.username, "PSMConnect", "DOMAIN\\\\user must be split")
        XCTAssertEqual(config.domain, "TESTDOMAIN")
        XCTAssertEqual(config.sessionKind, .rdp)
    }

    func testAddressWithoutAPortUsesTheDefault() {
        let file = RDPFileParser.parse(text: "full address:s:host.example.com")
        let (config, _) = RDPFileParser.session(from: file, name: "x")
        XCTAssertEqual(config.host, "host.example.com")
        XCTAssertEqual(config.port, 3389)
    }

    func testIPv6AddressKeepsItsColons() {
        XCTAssertEqual(RDPFileParser.splitAddress("[2001:db8::1]:3390").host, "2001:db8::1")
        XCTAssertEqual(RDPFileParser.splitAddress("[2001:db8::1]:3390").port, 3390)
        XCTAssertEqual(RDPFileParser.splitAddress("2001:db8::1").host, "2001:db8::1",
                       "a bare IPv6 address must not be split on its last colon")
        XCTAssertNil(RDPFileParser.splitAddress("2001:db8::1").port)
    }

    /// Full-screen mode means "follow the window" here, not a fixed size.
    func testFullScreenModeFollowsTheWindow() {
        let file = RDPFileParser.parse(text: sample)
        let (config, _) = RDPFileParser.session(from: file, name: "x")
        XCTAssertEqual(config.displayMode, .fitWindow)
        XCTAssertNil(config.rdpWidth)
        XCTAssertEqual(config.rdpUseAllDisplays, true, "use multimon:i:1")
    }

    func testWindowedModeWithASizeBecomesAFixedSize() {
        let file = RDPFileParser.parse(text: """
        screen mode id:i:1
        desktopwidth:i:1600
        desktopheight:i:900
        full address:s:host
        """)
        let (config, _) = RDPFileParser.session(from: file, name: "x")
        XCTAssertEqual(config.displayMode, .fixed)
        XCTAssertEqual(config.rdpWidth, 1600)
        XCTAssertEqual(config.rdpHeight, 900)
    }

    func testCredSSPMapsToTheSecurityMode() {
        let nla = RDPFileParser.parse(text: "enablecredsspsupport:i:1\nfull address:s:h")
        XCTAssertEqual(RDPFileParser.session(from: nla, name: "x").0.rdpSecurity, "nla")
        let off = RDPFileParser.parse(text: "enablecredsspsupport:i:0\nfull address:s:h")
        XCTAssertEqual(RDPFileParser.session(from: off, name: "x").0.rdpSecurity, "tls")
    }

    /// CyberArk PSM routes the session through this field; dropping it would
    /// connect to the jump server and go nowhere.
    func testAlternateShellIsCarriedAcross() {
        let file = RDPFileParser.parse(text: sample)
        let (config, warnings) = RDPFileParser.session(from: file, name: "x")
        XCTAssertEqual(config.rdpAlternateShell, "psm /u admin@target /a 10.0.0.5 /c PSM-RDP")
        XCTAssertTrue(warnings.contains { $0.contains("Start program carried across") })
    }

    // MARK: What cannot be honoured

    /// A DPAPI blob is tied to the Windows account that wrote it. Silently
    /// ignoring it would leave the user wondering why the password did not work.
    func testAnEncryptedPasswordIsReportedNotIgnored() {
        let file = RDPFileParser.parse(text: "full address:s:h\npassword 51:b:01000000D08C9DDF")
        let (config, warnings) = RDPFileParser.session(from: file, name: "x")
        XCTAssertNil(config.password)
        XCTAssertTrue(warnings.contains { $0.contains("DPAPI") }, "\(warnings)")
    }

    func testAGatewayIsReported() {
        let file = RDPFileParser.parse(text: """
        full address:s:host
        gatewayhostname:s:gw.example.com
        gatewayusagemethod:i:1
        """)
        let (_, warnings) = RDPFileParser.session(from: file, name: "x")
        XCTAssertTrue(warnings.contains { $0.contains("RD Gateway") }, "\(warnings)")
    }

    /// A gateway that is configured but switched off is not worth a warning.
    func testAnUnusedGatewayIsNotReported() {
        let file = RDPFileParser.parse(text: """
        full address:s:host
        gatewayhostname:s:gw.example.com
        gatewayusagemethod:i:0
        """)
        let (_, warnings) = RDPFileParser.session(from: file, name: "x")
        XCTAssertFalse(warnings.contains { $0.contains("RD Gateway") })
    }

    func testRemoteAppAndLoadBalanceInfoAreReported() {
        let file = RDPFileParser.parse(text: """
        full address:s:host
        remoteapplicationmode:i:1
        remoteapplicationprogram:s:||notepad
        loadbalanceinfo:s:tsv://MS Terminal Services Plugin.1.Farm
        """)
        let (_, warnings) = RDPFileParser.session(from: file, name: "x")
        XCTAssertTrue(warnings.contains { $0.contains("published app") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("load-balance") }, "\(warnings)")
    }

    func testAFileWithNothingUsefulStillProducesASession() {
        let (config, _) = RDPFileParser.session(from: RDPFileParser.parse(text: ""), name: "empty")
        XCTAssertEqual(config.name, "empty")
        XCTAssertEqual(config.host, "")
        XCTAssertEqual(config.sessionKind, .rdp)
    }
}

/// A file with the exact shape CyberArk PSM generates. The values are
/// placeholders; the keys, casing, types and CRLF endings are as it writes
/// them — including the port arriving as its own setting rather than as part
/// of the address, which is what mstsc does instead.
final class CyberArkRDPFileTests: XCTestCase {
    private let psmFile = "full address:s:10.0.0.1\r\n"
        + "server port:i:3389\r\n"
        + "username:s:localhost\\PSM@00000000-1111-2222-3333-444444444444\r\n"
        + "alternate shell:s:PSM@00000000-1111-2222-3333-444444444444\r\n"
        + "desktopwidth:i:1024\r\n"
        + "desktopheight:i:768\r\n"
        + "screen mode id:i:2\r\n"
        + "redirectdrives:i:0\r\n"
        + "drivestoredirect:s:\r\n"
        + "redirectsmartcards:i:0\r\n"
        + "EnableCredSspSupport:i:0\r\n"
        + "redirectcomports:i:0\r\n"
        + "remoteapplicationmode:i:0\r\n"
        + "use multimon:i:0\r\n"
        + "span monitors:i:0\r\n"

    /// The port is its own key here. Reading it only out of `full address`
    /// would silently connect to 3389 by luck and to the wrong port whenever
    /// PSM is published elsewhere.
    func testServerPortKeyIsUsed() {
        let file = RDPFileParser.parse(text: psmFile)
        let (config, _) = RDPFileParser.session(from: file, name: "psm")
        XCTAssertEqual(config.host, "10.0.0.1")
        XCTAssertEqual(config.port, 3389)

        var moved = psmFile.replacingOccurrences(of: "server port:i:3389",
                                                 with: "server port:i:3391")
        moved += "\r\n"
        let onAnotherPort = RDPFileParser.session(
            from: RDPFileParser.parse(text: moved), name: "psm").0
        XCTAssertEqual(onAnotherPort.port, 3391)
    }

    /// An explicit `server port` beats one folded into the address.
    func testTheExplicitPortWins() {
        let file = RDPFileParser.parse(text: "full address:s:host:3389\r\nserver port:i:4489")
        XCTAssertEqual(RDPFileParser.session(from: file, name: "x").0.port, 4489)
    }

    /// PSM's session token lives in the username, and its routing in the
    /// alternate shell. Losing either connects to the jump host and stops.
    func testTokenAndRoutingSurvive() {
        let file = RDPFileParser.parse(text: psmFile)
        let (config, _) = RDPFileParser.session(from: file, name: "psm")
        XCTAssertEqual(config.username, "PSM@00000000-1111-2222-3333-444444444444")
        XCTAssertEqual(config.domain, "localhost")
        XCTAssertEqual(config.rdpAlternateShell,
                       "PSM@00000000-1111-2222-3333-444444444444")
    }

    /// CredSSP is off in these files, so NLA must not be forced.
    func testCredSSPOffDoesNotAskForNLA() {
        let file = RDPFileParser.parse(text: psmFile)
        XCTAssertEqual(RDPFileParser.session(from: file, name: "x").0.rdpSecurity, "tls")
    }

    /// Empty values are not settings: an empty `drivestoredirect` must not
    /// produce a warning about redirected drives.
    func testEmptyValuesRaiseNoWarnings() {
        let file = RDPFileParser.parse(text: psmFile)
        let (_, warnings) = RDPFileParser.session(from: file, name: "x")
        XCTAssertFalse(warnings.contains { $0.contains("redirects Windows drives") },
                       "\(warnings)")
        XCTAssertFalse(warnings.contains { $0.contains("published app") }, "\(warnings)")
        XCTAssertFalse(warnings.contains { $0.contains("RD Gateway") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("Start program carried across") })
    }
}
