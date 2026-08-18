// "Wait for the prompt, then type this." A login that asks 'Username:' then
// 'Password:' then a menu can't be automated by firing commands blindly the
// moment you connect — you have to wait for each prompt. That is what an
// expect/send sequence does, and it's the piece on-connect commands can't do.
//
// The engine here is deliberately transport-agnostic and side-effect-free: you
// feed it output as it arrives and it hands back the strings to send, in order.
// It matches nothing about SSH or serial, so the same code drives a shell over
// any of them, and it can be unit-tested by feeding strings — no I/O at all.

import Foundation

/// One step: wait until `expect` appears in the output, then `send` this.
public struct ExpectStep: Codable, Equatable, Sendable {
    public var expect: String
    public var send: String
    /// Treat `expect` as a regular expression rather than a literal substring.
    public var isRegex: Bool

    public init(expect: String, send: String, isRegex: Bool = false) {
        self.expect = expect
        self.send = send
        self.isRegex = isRegex
    }
}

public extension ExpectStep {
    /// A whole sequence as editable text: one step per line, `expect => send`.
    /// Wrap the expect in slashes for a regex (`/[Pp]assword:/ => secret`).
    /// The send half understands `\n` (Enter), `\t`, `\r` and `\\`. Blank lines
    /// and lines without `=>` are ignored, so a half-typed line never errors.
    static func parseLines(_ text: String) -> [ExpectStep] {
        var steps: [ExpectStep] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let sep = line.range(of: "=>") else { continue }
            var expect = String(line[line.startIndex..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let send = decodeEscapes(String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces))
            guard !expect.isEmpty else { continue }
            var isRegex = false
            if expect.count >= 2, expect.hasPrefix("/"), expect.hasSuffix("/") {
                expect = String(expect.dropFirst().dropLast())
                isRegex = true
            }
            steps.append(ExpectStep(expect: expect, send: send, isRegex: isRegex))
        }
        return steps
    }

    /// The inverse of `parseLines`, for showing a saved sequence in the editor.
    static func formatLines(_ steps: [ExpectStep]) -> String {
        steps.map { step in
            let expect = step.isRegex ? "/\(step.expect)/" : step.expect
            return "\(expect) => \(encodeEscapes(step.send))"
        }.joined(separator: "\n")
    }

    private static func decodeEscapes(_ s: String) -> String {
        var out = ""
        var iter = s.makeIterator()
        while let c = iter.next() {
            if c == "\\", let n = iter.next() {
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\\": out.append("\\")
                default: out.append("\\"); out.append(n)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func encodeEscapes(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\\": out += "\\\\"
            default: out.append(c)
            }
        }
        return out
    }
}

/// Runs an expect/send script against a stream of output. Not thread-safe on its
/// own — feed it from one place (e.g. a connection's receive callback).
public final class ExpectMachine {
    public let steps: [ExpectStep]
    private var buffer = ""
    private(set) public var index = 0

    public init(steps: [ExpectStep]) {
        self.steps = steps
    }

    public var isComplete: Bool { index >= steps.count }

    /// Feed newly-received output. Returns the strings to send in response, in
    /// order — usually zero or one, but more if several prompts arrived in the
    /// same chunk. Once a step matches, the buffer is trimmed past the match so
    /// the next step starts looking at what came after, and the same prompt
    /// text can't satisfy two steps.
    @discardableResult
    public func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var sends: [String] = []
        while !isComplete {
            let step = steps[index]
            guard let matchEnd = matchEnd(of: step, in: buffer) else { break }
            sends.append(step.send)
            index += 1
            buffer = String(buffer[matchEnd...])
        }
        // Keep the buffer from growing without bound while waiting for a prompt
        // that may never come: only the tail can contain the start of a match.
        if buffer.count > 8192 {
            buffer = String(buffer.suffix(4096))
        }
        return sends
    }

    /// The index just past the first match of `step` in `text`, or nil.
    private func matchEnd(of step: ExpectStep, in text: String) -> String.Index? {
        if step.isRegex {
            guard let re = try? NSRegularExpression(pattern: step.expect) else { return nil }
            let ns = text as NSString
            let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            guard let m = match, m.range.location != NSNotFound else { return nil }
            let end = m.range.location + m.range.length
            return String.Index(utf16Offset: end, in: text)
        } else {
            guard !step.expect.isEmpty else { return text.startIndex }
            return text.range(of: step.expect)?.upperBound
        }
    }
}
