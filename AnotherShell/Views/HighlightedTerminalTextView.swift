import SwiftUI
import AppKit

struct HighlightedTerminalTextView: NSViewRepresentable {
    let text: String
    let rules: [SyntaxHighlightRule]
    let autoScroll: Bool
    let baseTextColor: Color
    let backgroundColor: Color
    let onSendText: (String) -> Void
    let onSendData: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSendText: onSendText, onSendData: onSendData)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let textView = TerminalTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.terminalDelegate = context.coordinator
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        let bg = backgroundColor.nsColor
        let fg = baseTextColor.nsColor

        nsView.backgroundColor = bg
        textView.backgroundColor = bg
        textView.insertionPointColor = fg
        let rulesSignature = rules
            .map { "\($0.id.uuidString)|\($0.name)|\($0.pattern)|\($0.colorHex)|\($0.isEnabled)|\($0.isCaseInsensitive)|\($0.isBold)" }
            .joined(separator: ";")
        let fgHex = fg.hexRGBA
        let bgHex = bg.hexRGBA
        let shouldRerender =
            context.coordinator.lastRenderedText != text ||
            context.coordinator.lastRulesSignature != rulesSignature ||
            context.coordinator.lastForegroundHex != fgHex ||
            context.coordinator.lastBackgroundHex != bgHex

        if shouldRerender {
            let attributed = TerminalSyntaxHighlighter.highlightedString(
                text: text,
                rules: rules,
                baseForeground: fg,
                baseBackground: bg
            )
            textView.textStorage?.setAttributedString(attributed)
            context.coordinator.lastRenderedText = text
            context.coordinator.lastRulesSignature = rulesSignature
            context.coordinator.lastForegroundHex = fgHex
            context.coordinator.lastBackgroundHex = bgHex
        }
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(textView)
        }

        if autoScroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    final class Coordinator: NSObject, TerminalTextViewDelegate, NSTextViewDelegate {
        weak var textView: NSTextView?
        private let onSendText: (String) -> Void
        private let onSendData: (Data) -> Void
        var lastRenderedText: String?
        var lastRulesSignature: String?
        var lastForegroundHex: String?
        var lastBackgroundHex: String?

        init(onSendText: @escaping (String) -> Void, onSendData: @escaping (Data) -> Void) {
            self.onSendText = onSendText
            self.onSendData = onSendData
        }

        fileprivate func terminalTextView(_ textView: TerminalTextView, send text: String) {
            onSendText(text)
        }

        fileprivate func terminalTextView(_ textView: TerminalTextView, send data: Data) {
            onSendData(data)
        }
    }
}

private extension NSColor {
    var hexRGBA: String {
        guard let converted = usingColorSpace(.deviceRGB) else { return "00000000" }
        let r = Int(round(converted.redComponent * 255))
        let g = Int(round(converted.greenComponent * 255))
        let b = Int(round(converted.blueComponent * 255))
        let a = Int(round(converted.alphaComponent * 255))
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }
}

fileprivate protocol TerminalTextViewDelegate: AnyObject {
    func terminalTextView(_ textView: TerminalTextView, send text: String)
    func terminalTextView(_ textView: TerminalTextView, send data: Data)
}

fileprivate final class TerminalTextView: NSTextView {
    weak var terminalDelegate: TerminalTextViewDelegate?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        guard didBecome else { return false }

        if let layoutManager, let textContainer {
            _ = layoutManager.glyphRange(for: textContainer)
        }

        setSelectedRange(NSRange(location: string.count, length: 0))
        needsDisplay = true
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if processKeyEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    @discardableResult
    fileprivate func processKeyEvent(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            return false
        }

        if let controlData = controlCharacter(for: event) {
            terminalDelegate?.terminalTextView(self, send: controlData)
            return true
        }

        if let specialSequence = specialSequence(for: event) {
            terminalDelegate?.terminalTextView(self, send: specialSequence)
            return true
        }

        if let characters = event.characters, !characters.isEmpty {
            terminalDelegate?.terminalTextView(self, send: characters)
            return true
        }

        return false
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let string = insertString as? String, !string.isEmpty {
            terminalDelegate?.terminalTextView(self, send: string)
            return
        }

        if let attributed = insertString as? NSAttributedString, attributed.length > 0 {
            terminalDelegate?.terminalTextView(self, send: attributed.string)
            return
        }

        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard let content = NSPasteboard.general.string(forType: .string), !content.isEmpty else {
            super.paste(sender)
            return
        }
        terminalDelegate?.terminalTextView(self, send: content)
    }

    private func controlCharacter(for event: NSEvent) -> Data? {
        guard event.modifierFlags.contains(.control),
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }

        let value = scalar.value
        guard value <= 0x7A else { return nil }
        let control = UInt8(value & 0x1F)
        return Data([control])
    }

    private func specialSequence(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76:
            return "\r"
        case 48:
            return "\t"
        case 51:
            return String(UnicodeScalar(0x7F))
        case 117:
            return "\u{1B}[3~"
        case 123:
            return "\u{1B}[D"
        case 124:
            return "\u{1B}[C"
        case 125:
            return "\u{1B}[B"
        case 126:
            return "\u{1B}[A"
        case 115:
            return "\u{1B}[H"
        case 119:
            return "\u{1B}[F"
        case 116:
            return "\u{1B}[5~"
        case 121:
            return "\u{1B}[6~"
        default:
            return nil
        }
    }
}
