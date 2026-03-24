import Foundation

/// Client-side streaming keyword highlighter (MobaXterm-like post-processing).
/// It does not rely on remote ANSI colors and injects style escapes before terminal rendering.
final class TerminalKeywordHighlighter {
    struct Rule {
        let name: String
        let regex: NSRegularExpression
        let prefix: String
        let suffix: String
        let priority: Int
    }

    struct Match {
        let range: NSRange
        let rule: Rule
    }

    private let rules: [Rule]
    private let resetSequence = "\u{001B}[0m"

    init() {
        rules = Self.buildRules()
    }

    func highlight(data: Data) -> Data {
        guard !data.isEmpty else { return data }

        // Keep terminal control-heavy chunks intact to avoid corrupting cursor/OSC operations.
        if data.contains(0x1B) {
            return data
        }

        // Skip chunks with non-printable control bytes (except tab/newline/carriage return).
        if data.contains(where: { byte in
            if byte == 0x09 || byte == 0x0A || byte == 0x0D { return false }
            return byte < 0x20 || byte == 0x7F
        }) {
            return data
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return data
        }

        if text.contains("\u{0000}") {
            return data
        }
        let highlighted = highlight(text: text)
        return highlighted.data(using: .utf8) ?? data
    }

    private func highlight(text: String) -> String {
        let nsText = text as NSString
        let whole = NSRange(location: 0, length: nsText.length)
        var candidates: [Match] = []
        candidates.reserveCapacity(64)

        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
                guard let match else { return }
                guard match.range.location != NSNotFound, match.range.length > 0 else { return }
                candidates.append(Match(range: match.range, rule: rule))
            }
        }

        guard !candidates.isEmpty else { return text }

        candidates.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            if lhs.rule.priority != rhs.rule.priority {
                return lhs.rule.priority > rhs.rule.priority
            }
            return lhs.range.length > rhs.range.length
        }

        var accepted: [Match] = []
        accepted.reserveCapacity(candidates.count)
        var lastEnd = 0

        for item in candidates {
            let start = item.range.location
            let end = item.range.location + item.range.length
            if start < lastEnd {
                continue
            }
            accepted.append(item)
            lastEnd = end
        }

        guard !accepted.isEmpty else { return text }

        var output = String()
        output.reserveCapacity(text.utf8.count + accepted.count * 20)

        var cursor = 0
        for item in accepted {
            let start = item.range.location
            let end = item.range.location + item.range.length

            if start > cursor {
                output.append(nsText.substring(with: NSRange(location: cursor, length: start - cursor)))
            }

            let segment = nsText.substring(with: item.range)
            output.append(item.rule.prefix)
            output.append(segment)
            output.append(item.rule.suffix)
            output.append(resetSequence)
            cursor = end
        }

        if cursor < nsText.length {
            output.append(nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor)))
        }

        return output
    }

    private static func buildRules() -> [Rule] {
        var index = 100
        func make(
            _ name: String,
            _ pattern: String,
            _ ansiPrefix: String
        ) -> Rule {
            defer { index -= 1 }
            return Rule(
                name: name,
                regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                prefix: ansiPrefix,
                suffix: "\u{001B}[22;39m",
                priority: index
            )
        }

        return [
            // Errors / critical
            make("critical", #"(?<![A-Za-z])(fatal|panic|critical|traceback|segmentation fault|unhandled exception|permission denied|authentication failed)(?![A-Za-z])"#, "\u{001B}[1;38;2;255;88;88m"),
            // Warning / deprecations
            make("warning", #"(?<![A-Za-z])(warn|warning|deprecated|timeout|retry|unable|refused|forbidden)(?![A-Za-z])"#, "\u{001B}[1;38;2;255;179;71m"),
            // Success states
            make("success", #"(?<![A-Za-z])(ok|success|connected|ready|done|completed|running|started|listening)(?![A-Za-z])"#, "\u{001B}[38;2;79;214;126m"),
            // Log levels
            make("log-level", #"\b(INFO|DEBUG|TRACE|NOTICE|ERROR|WARN|CRITICAL)\b"#, "\u{001B}[1;38;2;130;201;255m"),
            // IPv4
            make("ipv4", #"\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b"#, "\u{001B}[38;2;128;224;255m"),
            // URLs / hosts
            make("url-host", #"\b(?:https?|ssh|sftp)://[^\s]+|\b[a-z0-9][a-z0-9.-]+\.[a-z]{2,}\b"#, "\u{001B}[38;2;147;197;253m"),
            // Paths (unix + windows)
            make("path", #"(?:(?:~|/)[^\s:;,'"]+|[A-Za-z]:\\[^\s:;,'"]+)"#, "\u{001B}[38;2;180;146;255m"),
            // Time stamps
            make("timestamp", #"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?)?\b|\b\d{2}:\d{2}:\d{2}\b"#, "\u{001B}[38;2;196;208;224m"),
            // HTTP code
            make("http-code", #"\b[1-5]\d{2}\b"#, "\u{001B}[1;38;2;241;250;140m"),
            // Shell/Cisco/network keywords
            make("net-keywords", #"\b(interface|ip address|vlan|route|gateway|nat|firewall|policy|access-list)\b"#, "\u{001B}[1;38;2;255;121;198m")
        ]
    }
}
