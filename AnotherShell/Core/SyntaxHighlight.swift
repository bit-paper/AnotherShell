import Foundation
import SwiftUI
import AppKit
import Combine

struct SyntaxHighlightRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var pattern: String
    var colorHex: String
    var isEnabled: Bool = true
    var isCaseInsensitive: Bool = true
    var isBold: Bool = false
}

enum TerminalSyntaxHighlighter {
    static func highlightedString(
        text: String,
        rules: [SyntaxHighlightRule],
        baseForeground: NSColor,
        baseBackground: NSColor
    ) -> NSAttributedString {
        let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: baseForeground,
                .backgroundColor: baseBackground
            ]
        )

        let nsRange = NSRange(location: 0, length: (text as NSString).length)

        for rule in rules where rule.isEnabled {
            let options: NSRegularExpression.Options = rule.isCaseInsensitive ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: options) else { continue }

            let color = NSColor(hex: rule.colorHex) ?? .systemOrange
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: rule.isBold ? .semibold : .regular)

            regex.enumerateMatches(in: text, options: [], range: nsRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                attributed.addAttribute(.foregroundColor, value: color, range: range)
                attributed.addAttribute(.font, value: font, range: range)
            }
        }

        return attributed
    }
}

@MainActor
final class SyntaxHighlightStore: ObservableObject {
    @Published private(set) var rules: [SyntaxHighlightRule] = SyntaxHighlightStore.mobaXtermStyleRules

    init() {
    }

    private static let mobaXtermStyleRules: [SyntaxHighlightRule] = [
        SyntaxHighlightRule(name: "Error/Fatal", pattern: "\\b(error|failed|fatal|panic|exception|segmentation fault|traceback)\\b", colorHex: "#FF5F56", isEnabled: true, isCaseInsensitive: true, isBold: true),
        SyntaxHighlightRule(name: "Warning", pattern: "\\b(warn|warning|deprecated|timeout|retry|unable|denied)\\b", colorHex: "#FFB86C", isEnabled: true, isCaseInsensitive: true, isBold: true),
        SyntaxHighlightRule(name: "Success/OK", pattern: "\\b(ok|success|connected|ready|done|started|running)\\b", colorHex: "#50FA7B", isEnabled: true, isCaseInsensitive: true, isBold: false),
        SyntaxHighlightRule(name: "IP/Host", pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b|\\b[a-z0-9.-]+\\.(?:com|net|org|io|cn|local)\\b", colorHex: "#8BE9FD", isEnabled: true, isCaseInsensitive: true, isBold: false),
        SyntaxHighlightRule(name: "Path", pattern: "(?:~|/|[A-Za-z]:\\\\)[^\\s]+", colorHex: "#BD93F9", isEnabled: true, isCaseInsensitive: false, isBold: false),
        SyntaxHighlightRule(name: "HTTP/Code", pattern: "\\b(?:[1-5][0-9]{2}|0x[0-9A-Fa-f]+)\\b", colorHex: "#F1FA8C", isEnabled: true, isCaseInsensitive: false, isBold: true),
        SyntaxHighlightRule(name: "Timestamp", pattern: "\\b\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2}\\b|\\b\\d{2}:\\d{2}:\\d{2}\\b", colorHex: "#C0C5CE", isEnabled: true, isCaseInsensitive: false, isBold: false)
    ]
}

extension NSColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }

        guard cleaned.count == 6,
              let rgb = Int(cleaned, radix: 16) else {
            return nil
        }

        let red = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let green = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let blue = CGFloat(rgb & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else {
            return "#FFFFFF"
        }

        let red = Int(round(rgb.redComponent * 255))
        let green = Int(round(rgb.greenComponent * 255))
        let blue = Int(round(rgb.blueComponent * 255))

        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
