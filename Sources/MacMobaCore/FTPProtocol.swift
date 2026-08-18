// The parsing half of FTP (RFC 959, plus MLSD from RFC 3659).
//
// Kept apart from the sockets because this is where FTP is actually hard: the
// protocol is nearly fifty years old, the directory listing was never
// standardised until MLSD arrived in 2007, and half the servers in the world
// still answer LIST with whatever their local `ls` prints. None of that needs a
// connection to test.

import Foundation

public enum FTPProtocol {
    // MARK: - Replies

    public struct Reply: Equatable, Sendable {
        /// Three-digit status. 2xx succeeded, 3xx wants more, 4xx/5xx failed.
        public var code: Int
        /// Every line of the reply, newlines included for multi-line ones.
        public var text: String

        public init(code: Int, text: String) {
            self.code = code
            self.text = text
        }

        public var isPositive: Bool { (200..<400).contains(code) }
        public var isPreliminary: Bool { (100..<200).contains(code) }
    }

    /// Whether `lines` form a complete reply, and what it is.
    ///
    /// A reply is one line — `220 ready` — unless the code is followed by a
    /// hyphen, which opens a block that ends at a line starting with the SAME
    /// code and a space. Treating any 3-digit line as the end is the classic
    /// bug: a FEAT listing or a login banner can contain a line that begins
    /// with digits, and the connection then desynchronises for good.
    public static func parseReply(_ lines: [String]) -> Reply? {
        guard let first = lines.first, first.count >= 4 else { return nil }
        guard let code = Int(first.prefix(3)) else { return nil }
        let separator = first[first.index(first.startIndex, offsetBy: 3)]

        if separator == " " {
            return Reply(code: code, text: String(first.dropFirst(4)))
        }
        guard separator == "-" else { return nil }

        // Multi-line: closed only by "<same code> <text>".
        let terminator = "\(code) "
        for (index, line) in lines.enumerated() where index > 0 {
            if line.hasPrefix(terminator) {
                let body = lines[0...index].map { line -> String in
                    line.count >= 4 && Int(line.prefix(3)) == code ? String(line.dropFirst(4)) : line
                }
                return Reply(code: code, text: body.joined(separator: "\n"))
            }
        }
        return nil
    }

    // MARK: - Passive mode

    /// Host and port from a PASV reply: `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)`.
    ///
    /// The numbers are located by scanning for the six-number group rather than
    /// by matching the sentence, because the wording varies by server and some
    /// omit the brackets entirely.
    public static func parsePASV(_ text: String) -> (host: String, port: Int)? {
        var numbers: [Int] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else {
                if let value = Int(current) { numbers.append(value) }
                current = ""
                // Any non-digit that is not a separator breaks the group up.
                if character != "," && character != "(" && character != ")" && !numbers.isEmpty
                    && numbers.count < 6 {
                    numbers.removeAll()
                }
            }
        }
        if let value = Int(current) { numbers.append(value) }
        // The reply opens with its own status code; drop leading numbers until
        // exactly six are left, which is the address.
        guard numbers.count >= 6 else { return nil }
        let address = Array(numbers.suffix(6))
        guard address.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let host = address[0...3].map(String.init).joined(separator: ".")
        return (host, address[4] << 8 | address[5])
    }

    /// Port from an EPSV reply: `229 Entering Extended Passive Mode (|||49152|)`.
    ///
    /// Preferred over PASV because the server gives no address — the data
    /// connection goes to the same host as the control connection, which is
    /// what actually works through NAT, and is the only form defined for IPv6.
    public static func parseEPSV(_ text: String) -> Int? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"),
              open < close else { return nil }
        let inner = text[text.index(after: open)..<close]
        // Delimiter is whatever character follows the "(" — usually "|".
        guard let delimiter = inner.first else { return nil }
        let fields = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        // (|||port|) → ["", "", "", "port", ""]
        for field in fields.reversed() where !field.isEmpty {
            if let port = Int(field), (1...65535).contains(port) { return port }
        }
        return nil
    }

    // MARK: - Directory listings

    /// One MLSD line: `type=dir;size=4096;modify=20240102030405; name`.
    ///
    /// Machine-readable and unambiguous, which is the whole point of RFC 3659.
    /// Facts are case-insensitive by the spec, and the name is everything after
    /// the FIRST space — names may contain spaces and semicolons.
    public static func parseMLSD(_ line: String) -> SFTPItem? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var attributes = SFTPAttributes()
        var isDirectory = false
        var isSymlink = false
        for fact in line[line.startIndex..<space].split(separator: ";") {
            let parts = fact.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1])
            switch key {
            case "type":
                let type = value.lowercased()
                // cdir/pdir are "." and ".." under another name.
                if type == "cdir" || type == "pdir" { return nil }
                isDirectory = type == "dir"
                isSymlink = type.hasPrefix("os.unix=slink") || type == "link"
            case "size":
                attributes.size = UInt64(value)
            case "modify":
                attributes.mtime = parseMLSDTime(value)
            case "unix.mode":
                if let mode = UInt32(value, radix: 8) {
                    attributes.permissions = (attributes.permissions ?? 0) | mode
                }
            case "unix.owner", "unix.uid":
                attributes.uid = UInt32(value)
            case "unix.group", "unix.gid":
                attributes.gid = UInt32(value)
            default:
                break
            }
        }
        // The browser decides "is this a folder" from the permission bits, so
        // the file-type bits have to be there even when the server sent no mode.
        let typeBits: UInt32 = isSymlink ? 0o120000 : (isDirectory ? 0o040000 : 0o100000)
        attributes.permissions = (attributes.permissions ?? 0o644) & 0o7777 | typeBits
        return SFTPItem(name: name, longname: name, attributes: attributes)
    }

    /// `YYYYMMDDHHMMSS` (optionally with fractional seconds), always UTC.
    public static func parseMLSDTime(_ value: String) -> UInt32? {
        let digits = value.prefix(while: \.isNumber)
        guard digits.count >= 14 else { return nil }
        var components = DateComponents()
        func number(_ start: Int, _ length: Int) -> Int? {
            let from = digits.index(digits.startIndex, offsetBy: start)
            let to = digits.index(from, offsetBy: length)
            return Int(digits[from..<to])
        }
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2)
        components.minute = number(10, 2)
        components.second = number(12, 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = calendar.date(from: components), date.timeIntervalSince1970 >= 0 else {
            return nil
        }
        return UInt32(date.timeIntervalSince1970)
    }

    /// One line of a Unix-style LIST, the fallback when MLSD is unavailable:
    ///
    ///     drwxr-xr-x   2 owner group     4096 Jan  2 03:04 folder name
    ///     -rw-r--r--   1 owner group      123 Jan  2  2023 file.txt
    ///
    /// Deliberately conservative: anything that does not look like this is
    /// skipped rather than guessed at, because a wrong size or type is worse
    /// than a missing row. `now` is injectable so the year-inference rule can
    /// be tested without waiting for December.
    public static func parseUnixListing(_ line: String, now: Date = Date()) -> SFTPItem? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 9 else { return nil }
        let modeField = String(fields[0])
        guard modeField.count >= 10 else { return nil }
        let kind = modeField.first!
        // "total 12" and DOS-style listings both fail this.
        guard "-dlbcps".contains(kind) else { return nil }

        var attributes = SFTPAttributes()
        attributes.permissions = permissionBits(modeField)
        attributes.size = UInt64(fields[4])

        // Name starts after the three date fields. Splitting on whitespace
        // would lose spaces inside the name, so the offset is measured in the
        // ORIGINAL line: find where field 8 begins and take everything from
        // there, which keeps "My Documents" intact.
        let dateFields = fields[5...7].map(String.init)
        attributes.mtime = parseListingTime(dateFields, now: now)

        var remaining = Substring(line)
        for field in fields[0...7] {
            guard let range = remaining.range(of: field) else { return nil }
            remaining = remaining[range.upperBound...]
        }
        let name = String(remaining.drop(while: { $0 == " " }))
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        // "link -> target": the browser wants the link's own name.
        if kind == "l", let arrow = name.range(of: " -> ") {
            let linkName = String(name[name.startIndex..<arrow.lowerBound])
            guard !linkName.isEmpty else { return nil }
            return SFTPItem(name: linkName, longname: line, attributes: attributes)
        }
        return SFTPItem(name: name, longname: line, attributes: attributes)
    }

    /// `rwxr-xr-x` plus the type character, as the mode bits the browser reads.
    static func permissionBits(_ mode: String) -> UInt32 {
        var bits: UInt32
        switch mode.first {
        case "d": bits = 0o040000
        case "l": bits = 0o120000
        case "b": bits = 0o060000
        case "c": bits = 0o020000
        case "p": bits = 0o010000
        case "s": bits = 0o140000
        default: bits = 0o100000
        }
        let flags = Array(mode.dropFirst().prefix(9))
        guard flags.count == 9 else { return bits }
        for (index, flag) in flags.enumerated() where flag != "-" {
            // r/w/x in each of the three triples, high bit first.
            if flag == "r" || flag == "w" || flag == "x" {
                bits |= UInt32(1) << (8 - index)
            } else {
                // s/S/t/T occupy the execute slot and also set a special bit.
                if flag == "s" || flag == "t" { bits |= UInt32(1) << (8 - index) }
                switch index {
                case 2: bits |= 0o4000
                case 5: bits |= 0o2000
                case 8: bits |= 0o1000
                default: break
                }
            }
        }
        return bits
    }

    /// `Jan  2 03:04` (this year, roughly) or `Jan  2  2023` (a given year).
    ///
    /// The first form has no year at all. Unix `ls` omits it for anything
    /// within about six months, so a date more than a day ahead of now belongs
    /// to LAST year — otherwise every file from December looks like it is from
    /// the future each January.
    static func parseListingTime(_ fields: [String], now: Date) -> UInt32? {
        guard fields.count == 3 else { return nil }
        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let month = months.firstIndex(of: fields[0].lowercased()),
              let day = Int(fields[1]) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var components = DateComponents()
        components.month = month + 1
        components.day = day

        if fields[2].contains(":") {
            let time = fields[2].split(separator: ":")
            guard time.count == 2, let hour = Int(time[0]), let minute = Int(time[1]) else {
                return nil
            }
            components.hour = hour
            components.minute = minute
            components.year = calendar.component(.year, from: now)
            guard var date = calendar.date(from: components) else { return nil }
            if date.timeIntervalSince(now) > 86_400 {
                components.year = components.year! - 1
                guard let corrected = calendar.date(from: components) else { return nil }
                date = corrected
            }
            return date.timeIntervalSince1970 >= 0 ? UInt32(date.timeIntervalSince1970) : nil
        }

        guard let year = Int(fields[2]) else { return nil }
        components.year = year
        components.hour = 0
        components.minute = 0
        guard let date = calendar.date(from: components), date.timeIntervalSince1970 >= 0 else {
            return nil
        }
        return UInt32(date.timeIntervalSince1970)
    }

    /// Parse a whole listing, preferring MLSD and falling back per line.
    public static func parseListing(_ text: String, isMLSD: Bool,
                                    now: Date = Date()) -> [SFTPItem] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.isEmpty }
            .compactMap { isMLSD ? parseMLSD($0) : parseUnixListing($0, now: now) }
    }

    /// Which extensions a FEAT reply advertised, upper-cased.
    public static func parseFEAT(_ text: String) -> Set<String> {
        var features: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).uppercased()
            guard !trimmed.isEmpty, !trimmed.hasPrefix("211") else { continue }
            if trimmed.hasPrefix("FEATURES") || trimmed.hasPrefix("END") { continue }
            // "MLST type*;size*;modify*;" → MLST
            features.insert(String(trimmed.prefix(while: { !$0.isWhitespace })))
        }
        return features
    }

    /// Join a directory and a name the way a remote POSIX path works. Same rule
    /// as the SFTP browser uses, so paths behave identically in both.
    public static func join(_ base: String, _ name: String) -> String {
        if base.isEmpty || base == "/" { return "/" + name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
