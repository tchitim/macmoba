// Turning what someone types into a URL worth loading.
//
// An address bar takes "10.0.0.5:8080", "wiki", "https://host/path" and
// "how do I restart nginx" and has to tell them apart. Getting it wrong sends
// an internal hostname to a search engine — which, for a host reachable only
// through a bastion, means leaking the name of a private machine to Google.
// So the rule here is deliberately conservative: anything that could be a host
// is treated as one.

import Foundation

public enum WebAddress {
    /// A URL for `text`, or nil when it is not addressable.
    ///
    /// - Parameter searchTemplate: where to send things that are clearly not
    ///   addresses. Nil means "never search" — the safe default for a browser
    ///   whose whole purpose is reaching private hosts.
    public static func url(for rawText: String, searchTemplate: String? = nil) -> URL? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Already a URL with a scheme we can load.
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" || scheme == "file" || scheme == "about" {
                return url
            }
            // Some other scheme — mailto:, ssh:, javascript: — is not ours to
            // open in a web view.
            return nil
        }

        if looksLikeHost(text) {
            return URL(string: "http://" + text)
        }
        guard let searchTemplate, let escaped = text.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: escaped))
    }

    /// Whether this could be a host, and so must not be sent to a search engine.
    ///
    /// A bare word counts: on a corporate network "wiki" and "jenkins" are real
    /// hostnames, and they are exactly the names that must not leak.
    static func looksLikeHost(_ text: String) -> Bool {
        // A space means a sentence, not a host.
        if text.contains(" ") { return false }
        let head = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard !head.isEmpty else { return false }

        // host:port
        let hostPart: String
        if let colon = head.lastIndex(of: ":"), !head.hasPrefix("[") {
            let portText = head[head.index(after: colon)...]
            guard !portText.isEmpty, portText.allSatisfy(\.isNumber),
                  let port = Int(portText), (1...65535).contains(port) else { return false }
            hostPart = String(head[head.startIndex..<colon])
        } else {
            hostPart = head
        }
        guard !hostPart.isEmpty else { return false }

        // IPv6 in brackets.
        if hostPart.hasPrefix("["), hostPart.hasSuffix("]") { return true }
        // Hostname characters only. A trailing dot is legal (a rooted name).
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard hostPart.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // "-lead" and ".lead" are not hostnames.
        guard let first = hostPart.first, first.isLetter || first.isNumber else { return false }
        return true
    }

    /// What to show in the address bar: the full URL, minus the noise.
    public static func display(_ url: URL) -> String {
        var text = url.absoluteString
        if text.hasPrefix("http://") { text.removeFirst("http://".count) }
        if text.hasSuffix("/"), url.path == "/" || url.path.isEmpty { text.removeLast() }
        return text
    }
}
