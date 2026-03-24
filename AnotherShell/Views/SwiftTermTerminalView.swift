import SwiftUI
import AppKit
import SwiftTerm

struct SwiftTermTerminalView: NSViewRepresentable {
    @ObservedObject var session: SSHSession
    let baseTextColor: SwiftUI.Color
    let backgroundColor: SwiftUI.Color

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = baseTextColor.nsColor
        terminalView.nativeBackgroundColor = backgroundColor.nsColor
        terminalView.caretViewTracksFocus = true
        terminalView.optionAsMetaKey = false
        terminalView.allowMouseReporting = true
        context.coordinator.attach(to: terminalView)
        context.coordinator.seedIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            terminalView.window?.makeFirstResponder(terminalView)
        }

        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.session = session
        nsView.nativeForegroundColor = baseTextColor.nsColor
        nsView.nativeBackgroundColor = backgroundColor.nsColor
        context.coordinator.attach(to: nsView)
        context.coordinator.seedIfNeeded()
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: SSHSession
        weak var terminalView: TerminalView?
        private var listenerID: UUID?
        private var didSeedExistingOutput = false
        private var isSeedingReplay = false
        private var bufferedDuringSeed: [Data] = []
        private var pendingSeedPayload: Data?
        private var pendingSeedWorkItem: DispatchWorkItem?
        private var previousByteWasCR = false
        private var pendingResizeWorkItem: DispatchWorkItem?
        private var lastResize: (cols: Int, rows: Int)?

        init(session: SSHSession) {
            self.session = session
        }

        func attach(to terminalView: TerminalView) {
            self.terminalView = terminalView
            if listenerID == nil {
                listenerID = session.addTerminalOutputListener { [weak self] data in
                    self?.enqueueOrFeed(data: data)
                }
            }
            attemptSeedIfReady()
        }

        func detach() {
            pendingSeedWorkItem?.cancel()
            pendingSeedWorkItem = nil
            pendingResizeWorkItem?.cancel()
            pendingResizeWorkItem = nil
            bufferedDuringSeed.removeAll(keepingCapacity: true)
            isSeedingReplay = false
            didSeedExistingOutput = false
            if let listenerID {
                session.removeTerminalOutputListener(listenerID)
            }
            listenerID = nil
            terminalView = nil
        }

        func seedIfNeeded() {
            guard !didSeedExistingOutput else { return }
            pendingSeedPayload = session.terminalReplaySnapshot()
            attemptSeedIfReady()
        }

        private func feed(data: Data) {
            guard let terminalView else { return }
            let bytes = normalizedTerminalBytes(from: [UInt8](data))
            if bytes.isEmpty { return }
            terminalView.feed(byteArray: bytes[...])
        }

        private func enqueueOrFeed(data: Data) {
            if didSeedExistingOutput && !isSeedingReplay {
                feed(data: data)
                return
            }
            bufferedDuringSeed.append(data)
        }

        private func normalizedTerminalBytes(from rawBytes: [UInt8]) -> [UInt8] {
            guard !rawBytes.isEmpty else { return [] }
            var normalized: [UInt8] = []
            normalized.reserveCapacity(rawBytes.count + 16)

            for byte in rawBytes {
                if byte == 0x0A {
                    if !previousByteWasCR {
                        normalized.append(0x0D)
                    }
                    normalized.append(0x0A)
                } else {
                    normalized.append(byte)
                }
                previousByteWasCR = (byte == 0x0D)
            }

            return normalized
        }

        private func attemptSeedIfReady() {
            guard !didSeedExistingOutput else { return }
            guard let terminalView else { return }
            guard let pendingSeedPayload else {
                didSeedExistingOutput = true
                flushBufferedAfterSeed()
                return
            }

            // Avoid replaying before SwiftUI has laid out the terminal. Early replay at tiny width
            // causes hard wraps that stay corrupted after session switching.
            let size = terminalView.bounds.size
            let layoutReady = size.width >= 320 && size.height >= 140
            guard layoutReady else {
                pendingSeedWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.attemptSeedIfReady()
                }
                pendingSeedWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
                return
            }

            self.pendingSeedPayload = nil
            isSeedingReplay = true
            previousByteWasCR = false
            let bytes = normalizedTerminalBytes(from: [UInt8](pendingSeedPayload))
            if !bytes.isEmpty {
                terminalView.feed(byteArray: bytes[...])
            }
            didSeedExistingOutput = true
            isSeedingReplay = false
            flushBufferedAfterSeed()
        }

        private func flushBufferedAfterSeed() {
            guard didSeedExistingOutput, !bufferedDuringSeed.isEmpty else { return }
            let pending = bufferedDuringSeed
            bufferedDuringSeed.removeAll(keepingCapacity: true)
            for data in pending {
                feed(data: data)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            attemptSeedIfReady()
            if let lastResize, lastResize.cols == newCols, lastResize.rows == newRows {
                return
            }
            pendingResizeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lastResize = (newCols, newRows)
                self.session.resizeTerminal(columns: newCols, rows: newRows)
            }
            pendingResizeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            session.updateWorkingDirectory(directory)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.sendData(Data(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let string = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
