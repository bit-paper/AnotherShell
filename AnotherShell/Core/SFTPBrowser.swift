import Foundation
import Combine
#if canImport(SSHClient)
import SSHClient
#endif

private func sftpShortTimestamp(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
    let month = components.month ?? 0
    let day = components.day ?? 0
    let hour = components.hour ?? 0
    let minute = components.minute ?? 0
    return String(format: "%02d-%02d %02d:%02d", month, day, hour, minute)
}

struct RemoteFileEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: String
    let permission: String
}

struct LocalFileEntry: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var name: String {
        url.lastPathComponent
    }
}

private final class TransferCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

private struct RemoteCleanupItem: Hashable {
    let path: String
    let recursive: Bool
}

private enum SFTPTransferError: LocalizedError, Equatable {
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Transfer cancelled"
        case .message(let message):
            return message
        }
    }
}

@MainActor
final class SFTPBrowserModel: ObservableObject {
    let host: SSHHost
    private var passwordOverride: String?

    @Published var currentRemotePath: String = "~"
    @Published private(set) var remoteEntries: [RemoteFileEntry] = []
    @Published var currentLocalURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var localEntries: [LocalFileEntry] = []

    @Published private(set) var isLoadingRemote: Bool = false
    @Published private(set) var isTransferring: Bool = false
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var canRetryTransfer: Bool = false
    @Published private(set) var canCancelTransfer: Bool = false
    @Published private(set) var canRequestPermission: Bool = false
    @Published private(set) var statusMessage: String = ""

    private let ioQueue = DispatchQueue(label: "com.anothershell.sftp.io", qos: .utility)
    private let pwdMarker = "__ANOTHERSHELL_REMOTE_PWD__"
    private let lsMarker = "__ANOTHERSHELL_REMOTE_LS__"
#if canImport(SSHClient)
    private var embeddedConnection: SSHConnection?
    private var embeddedSFTPClient: SFTPClient?
#endif
    private var retryTransferAction: (() -> Void)?
    private let transferCancellation = TransferCancellationState()
    private var preferredStartupRemotePath: String?
    private var lastPermissionDeniedPath: String?

    init(host: SSHHost) {
        self.host = host
        if host.prefersPasswordAuthentication {
            currentRemotePath = "."
        }
        refreshLocal()
    }

    func setPasswordOverride(_ password: String?) {
        let trimmed = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        passwordOverride = trimmed.isEmpty ? nil : trimmed
    }

    func setPreferredStartupRemotePath(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = normalizePathForSFTP(trimmed)
        preferredStartupRemotePath = normalized.isEmpty ? nil : normalized
    }

    func refreshAll() {
        alignRemotePathWithPreferredStartupIfNeeded()
        refreshLocal()
        refreshRemote()
    }

    func refreshLocal() {
        let targetURL = currentLocalURL
        ioQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            do {
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
                let urls = try fm.contentsOfDirectory(at: targetURL, includingPropertiesForKeys: keys)

                let entries = urls.compactMap { url -> LocalFileEntry? in
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    if values?.isHidden == true {
                        return nil
                    }

                    return LocalFileEntry(
                        url: url,
                        isDirectory: values?.isDirectory ?? false,
                        size: Int64(values?.fileSize ?? 0),
                        modified: values?.contentModificationDate
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory && !rhs.isDirectory
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }

                DispatchQueue.main.async {
                    self.localEntries = entries
                    self.statusMessage = "Local: \(targetURL.path)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to list local path: \(error.localizedDescription)"
                }
            }
        }
    }

    func openLocal(_ entry: LocalFileEntry) {
        guard entry.isDirectory else { return }
        currentLocalURL = entry.url
        refreshLocal()
    }

    func goLocalUp() {
        let parent = currentLocalURL.deletingLastPathComponent()
        guard parent.path != currentLocalURL.path else { return }
        currentLocalURL = parent
        refreshLocal()
    }

    func navigateLocal(to path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let fm = FileManager.default
        var resolvedPath = trimmed
        if trimmed.hasPrefix("~") {
            let home = fm.homeDirectoryForCurrentUser.path
            if trimmed == "~" {
                resolvedPath = home
            } else if trimmed.hasPrefix("~/") {
                resolvedPath = home + "/" + String(trimmed.dropFirst(2))
            }
        }

        let candidate = URL(fileURLWithPath: resolvedPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            statusMessage = "Local path not found: \(candidate.path)"
            return
        }

        currentLocalURL = candidate
        refreshLocal()
    }

    func refreshRemote() {
        alignRemotePathWithPreferredStartupIfNeeded()
        if host.prefersPasswordAuthentication {
            let targetPath = normalizeRemotePathForEmbeddedLibrary(currentRemotePath)
            isLoadingRemote = true
            statusMessage = "Refreshing remote: \(targetPath)"
            refreshRemoteWithNMSSH(targetPath: targetPath, priorError: "")
            return
        }

#if canImport(SSHClient)
        if host.prefersPasswordAuthentication {
            refreshRemoteEmbedded()
            return
        }
#endif

        let targetPath = currentRemotePath
        isLoadingRemote = true
        statusMessage = "Refreshing remote: \(targetPath)"

        let command = buildRemoteListCommand(path: targetPath)
        let arguments = host.buildSSHCommandArguments(command: command)
        let password = storedPassword

        ioQueue.async { [weak self] in
            guard let self else { return }
            let result = AuthCommandRunner.run(
                binaryPath: "/usr/bin/ssh",
                arguments: arguments,
                password: password
            )

            DispatchQueue.main.async {
                self.isLoadingRemote = false

                if result.code == 0 {
                    let parsed = self.parseRemoteListing(result.output)
                    self.currentRemotePath = parsed.resolvedPath
                    self.remoteEntries = parsed.entries
                    self.statusMessage = "Remote: \(self.currentRemotePath)"
                } else {
                    let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = reason.isEmpty ? "Remote refresh failed" : "Remote refresh failed: \(reason)"
                }
            }
        }
    }

    func openRemote(_ entry: RemoteFileEntry) {
        guard entry.isDirectory else { return }
        currentRemotePath = entry.path
        refreshRemote()
    }

    func navigateRemote(to path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentRemotePath = trimmed
        refreshRemote()
    }

    func goRemoteUp() {
        let parent = remoteParentPath(currentRemotePath)
        guard parent != currentRemotePath else { return }
        currentRemotePath = parent
        refreshRemote()
    }

    func requestPermissionAndRetry() {
        guard canRequestPermission else { return }
        guard let deniedPath = lastPermissionDeniedPath, !deniedPath.isEmpty else {
            refreshRemote()
            return
        }

        statusMessage = "Requesting access for \(deniedPath)..."
        canRequestPermission = false

        let escapedPath = shellSingleQuote(deniedPath)
        let command = "echo \(shellSingleQuote(storedPassword ?? "")) | sudo -S -p '' chmod u+rX \(escapedPath) >/dev/null 2>&1 || true"
        let arguments = host.buildSSHCommandArguments(command: command)
        let password = storedPassword

        ioQueue.async { [weak self] in
            guard let self else { return }
            _ = AuthCommandRunner.run(
                binaryPath: "/usr/bin/ssh",
                arguments: arguments,
                password: password
            )
            DispatchQueue.main.async {
                self.refreshRemote()
            }
        }
    }

    func upload(localURLs: [URL]) {
        if host.prefersPasswordAuthentication {
            let files = localURLs.filter { $0.isFileURL }
            guard !files.isEmpty else { return }
            guard !isTransferring else {
                statusMessage = "Transfer already running"
                return
            }
            isTransferring = true
            canRetryTransfer = false
            canCancelTransfer = true
            transferProgress = 0
            transferCancellation.reset()
            retryTransferAction = { [weak self] in
                self?.upload(localURLs: files)
            }
            let target = normalizeRemotePathForEmbeddedLibrary(currentRemotePath)
            statusMessage = "Uploading \(files.count) item(s)..."
            uploadWithNMSSH(localURLs: files, remoteDirectory: target, priorError: "")
            return
        }

#if canImport(SSHClient)
        if host.prefersPasswordAuthentication {
            uploadEmbedded(localURLs: localURLs)
            return
        }
#endif

        let files = localURLs.filter { $0.isFileURL }
        guard !files.isEmpty else { return }

        if isTransferring {
            statusMessage = "Transfer already running"
            return
        }

        isTransferring = true
        canRetryTransfer = false
        canCancelTransfer = true
        transferProgress = 0
        transferCancellation.reset()
        retryTransferAction = { [weak self] in
            self?.upload(localURLs: files)
        }
        statusMessage = "Uploading \(files.count) item(s)..."

        let target = currentRemotePath
        let host = self.host
        let password = storedPassword
        let cancellation = transferCancellation

        ioQueue.async { [weak self] in
            guard let self else { return }
            var failureMessages: [String] = []
            var wasCancelled = false

            for (index, file) in files.enumerated() {
                if cancellation.isCancelled {
                    wasCancelled = true
                    break
                }
                let result = AuthCommandRunner.run(
                    binaryPath: "/usr/bin/scp",
                    arguments: host.buildSCPUploadArguments(localURL: file, remotePath: target, recursive: true),
                    password: password
                )

                if result.code != 0 {
                    let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = reason.isEmpty ? "upload failed with code \(result.code)" : reason
                    failureMessages.append("\(file.lastPathComponent): \(message)")
                }
                DispatchQueue.main.async {
                    self.transferProgress = Double(index + 1) / Double(max(files.count, 1))
                }
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                self.canCancelTransfer = false
                self.transferProgress = wasCancelled ? 0 : 1
                if wasCancelled {
                    self.canRetryTransfer = false
                    self.statusMessage = "Upload cancelled"
                } else if failureMessages.isEmpty {
                    self.canRetryTransfer = false
                    self.statusMessage = "Upload complete"
                } else {
                    self.canRetryTransfer = true
                    self.statusMessage = "Upload completed with errors: \(failureMessages.joined(separator: " | "))"
                }
                self.refreshRemote()
            }
        }
    }

    func download(remotePaths: [String], toLocalDirectory targetDirectory: URL? = nil) {
        if host.prefersPasswordAuthentication {
            let validPaths = remotePaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !validPaths.isEmpty else { return }
            guard !isTransferring else {
                statusMessage = "Transfer already running"
                return
            }
            isTransferring = true
            canRetryTransfer = false
            canCancelTransfer = true
            transferProgress = 0
            transferCancellation.reset()
            let destination = targetDirectory ?? currentLocalURL
            retryTransferAction = { [weak self] in
                self?.download(remotePaths: validPaths, toLocalDirectory: destination)
            }
            statusMessage = "Downloading \(validPaths.count) item(s)..."
            downloadWithNMSSH(remotePaths: validPaths, localDirectory: destination, priorError: "")
            return
        }

#if canImport(SSHClient)
        if host.prefersPasswordAuthentication {
            downloadEmbedded(remotePaths: remotePaths)
            return
        }
#endif

        let validPaths = remotePaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validPaths.isEmpty else { return }

        if isTransferring {
            statusMessage = "Transfer already running"
            return
        }

        isTransferring = true
        canRetryTransfer = false
        canCancelTransfer = true
        transferProgress = 0
        transferCancellation.reset()
        let destination = targetDirectory ?? currentLocalURL
        retryTransferAction = { [weak self] in
            self?.download(remotePaths: validPaths, toLocalDirectory: destination)
        }
        statusMessage = "Downloading \(validPaths.count) item(s)..."

        let host = self.host
        let password = storedPassword
        let cancellation = transferCancellation

        ioQueue.async { [weak self] in
            guard let self else { return }
            var failureMessages: [String] = []
            var wasCancelled = false

            for (index, remotePath) in validPaths.enumerated() {
                if cancellation.isCancelled {
                    wasCancelled = true
                    break
                }
                let result = AuthCommandRunner.run(
                    binaryPath: "/usr/bin/scp",
                    arguments: host.buildSCPDownloadArguments(remotePath: remotePath, localDirectory: destination, recursive: true),
                    password: password
                )

                if result.code != 0 {
                    let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = reason.isEmpty ? "download failed with code \(result.code)" : reason
                    failureMessages.append("\(remotePath): \(message)")
                }
                DispatchQueue.main.async {
                    self.transferProgress = Double(index + 1) / Double(max(validPaths.count, 1))
                }
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                self.canCancelTransfer = false
                self.transferProgress = wasCancelled ? 0 : 1
                if wasCancelled {
                    self.canRetryTransfer = false
                    self.statusMessage = "Download cancelled"
                } else if failureMessages.isEmpty {
                    self.canRetryTransfer = false
                    self.statusMessage = "Download complete"
                } else {
                    self.canRetryTransfer = true
                    self.statusMessage = "Download completed with errors: \(failureMessages.joined(separator: " | "))"
                }
                self.refreshLocal()
            }
        }
    }

    func retryLastTransfer() {
        guard !isTransferring else { return }
        retryTransferAction?()
    }

    func cancelTransfer() {
        guard isTransferring else { return }
        transferCancellation.cancel()
        canCancelTransfer = false
        statusMessage = "Cancelling transfer..."
    }

    private var storedPassword: String? {
        guard host.prefersPasswordAuthentication else { return nil }
        if let passwordOverride, !passwordOverride.isEmpty {
            return passwordOverride
        }
        return KeychainPasswordStore.load(for: host)
    }

    private func buildRemoteListCommand(path: String) -> String {
        let cdPart = buildCDCommand(path: path)

        return [
            cdPart,
            "printf '\(pwdMarker)\\n'",
            "/bin/pwd",
            "printf '\(lsMarker)\\n'",
            "/bin/ls -la"
        ].joined(separator: " && ")
    }

    private func alignRemotePathWithPreferredStartupIfNeeded() {
        guard let preferredStartupRemotePath, !preferredStartupRemotePath.isEmpty else { return }
        let current = currentRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current == "~" || current == "." {
            currentRemotePath = preferredStartupRemotePath
        }
    }

    private func buildCDCommand(path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" {
            return "cd -- \"$HOME\""
        }

        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            let escaped = shellEscapeForDoubleQuotes(suffix)
            return "cd -- \"$HOME/\(escaped)\""
        }

        return "cd -- \(shellSingleQuote(trimmed))"
    }

    private func parseRemoteListing(_ output: String) -> (resolvedPath: String, entries: [RemoteFileEntry]) {
        let lines = output.components(separatedBy: .newlines)
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let pwdMarkerIndex = trimmedLines.firstIndex(of: pwdMarker),
              let lsMarkerIndex = trimmedLines.firstIndex(of: lsMarker),
              pwdMarkerIndex + 1 < trimmedLines.count else {
            return fallbackParseRemoteListing(output)
        }

        let resolvedPath = trimmedLines[pwdMarkerIndex + 1]
        let listingStart = lsMarkerIndex + 1
        let listingLines = listingStart < lines.count ? Array(lines[listingStart...]) : []

        var entries: [RemoteFileEntry] = []
        for line in listingLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("total") { continue }

            if let entry = parseLSLine(trimmed, basePath: resolvedPath) {
                entries.append(entry)
            }
        }

        entries.sort {
            if $0.name == ".." { return true }
            if $1.name == ".." { return false }
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return (resolvedPath, entries)
    }

    private func fallbackParseRemoteListing(_ output: String) -> (resolvedPath: String, entries: [RemoteFileEntry]) {
        let lines = output.components(separatedBy: .newlines)
        var resolvedPath = currentRemotePath
        var entries: [RemoteFileEntry] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("/") {
                resolvedPath = trimmed
                continue
            }

            if trimmed.hasPrefix("total") || trimmed.hasPrefix("Warning:") {
                continue
            }

            if let entry = parseLSLine(trimmed, basePath: resolvedPath) {
                entries.append(entry)
            }
        }

        entries.sort {
            if $0.name == ".." { return true }
            if $1.name == ".." { return false }
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return (resolvedPath, entries)
    }

    nonisolated private func parseLSLine(_ line: String, basePath: String) -> RemoteFileEntry? {
        let columns = line.split(whereSeparator: { $0.isWhitespace })
        guard columns.count >= 9 else { return nil }

        let permission = String(columns[0])
        guard let typeChar = permission.first, ["d", "-", "l"].contains(typeChar) else {
            return nil
        }

        let size = Int64(columns[4]) ?? 0
        let modified = columns[5...7].joined(separator: " ")
        var name = columns[8...].joined(separator: " ")

        if let arrowRange = name.range(of: " -> ") {
            name = String(name[..<arrowRange.lowerBound])
        }

        if name == "." {
            return nil
        }

        let absolutePath: String
        if name == ".." {
            let parent = remoteParentPath(basePath)
            guard parent != basePath else { return nil }
            absolutePath = parent
        } else {
            absolutePath = remoteJoin(basePath: basePath, name: name)
        }

        return RemoteFileEntry(
            name: name,
            path: absolutePath,
            isDirectory: typeChar == "d",
            size: size,
            modified: modified,
            permission: permission
        )
    }

    nonisolated private func remoteJoin(basePath: String, name: String) -> String {
        if name.hasPrefix("/") { return name }
        if basePath == "/" { return "/\(name)" }

        if basePath.hasSuffix("/") {
            return "\(basePath)\(name)"
        }

        return "\(basePath)/\(name)"
    }

    nonisolated private func remoteParentPath(_ path: String) -> String {
        if path == "/" || path == "~" {
            return path
        }

        if path.hasPrefix("~/") {
            let trimmed = String(path.dropFirst(2))
            if !trimmed.contains("/") {
                return "~"
            }

            var pieces = trimmed.split(separator: "/").map(String.init)
            _ = pieces.popLast()
            return "~/\(pieces.joined(separator: "/"))"
        }

        if path.hasPrefix("/") {
            var pieces = path.split(separator: "/").map(String.init)
            _ = pieces.popLast()
            return pieces.isEmpty ? "/" : "/\(pieces.joined(separator: "/"))"
        }

        var pieces = path.split(separator: "/").map(String.init)
        _ = pieces.popLast()
        return pieces.isEmpty ? "." : pieces.joined(separator: "/")
    }

    private func shellSingleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func shellEscapeForDoubleQuotes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private func normalizeRemotePathForEmbeddedLibrary(_ path: String) -> String {
        let trimmed = normalizePathForSFTP(path.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.isEmpty || trimmed == "~" {
            return "."
        }
        return trimmed
    }

    private func normalizePathForSFTP(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        if path.hasPrefix("/") || path.hasPrefix("~") || path == "." {
            return path
        }

        let fullPattern = #"^([A-Za-z]):[\\/](.*)$"#
        if let regex = try? NSRegularExpression(pattern: fullPattern),
           let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           match.numberOfRanges >= 3,
           let driveRange = Range(match.range(at: 1), in: path),
           let tailRange = Range(match.range(at: 2), in: path) {
            let drive = String(path[driveRange]).uppercased()
            let tail = String(path[tailRange]).replacingOccurrences(of: "\\", with: "/")
            return "/\(drive):/\(tail)"
        }

        let driveOnlyPattern = #"^([A-Za-z]):$"#
        if let regex = try? NSRegularExpression(pattern: driveOnlyPattern),
           let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           match.numberOfRanges >= 2,
           let driveRange = Range(match.range(at: 1), in: path) {
            let drive = String(path[driveRange]).uppercased()
            return "/\(drive):/"
        }

        return path
    }

#if canImport(SSHClient)
    private func refreshRemoteEmbedded() {
        let targetPath = normalizeEmbeddedRemotePath(currentRemotePath)
        isLoadingRemote = true
        statusMessage = "Refreshing remote: \(targetPath)"

        Task {
            do {
                let client = try await ensureEmbeddedSFTPClient()
                let items = try await listDirectory(client: client, path: targetPath)
                let entries = items.compactMap { component in
                    remoteEntry(from: component, basePath: targetPath)
                }
                let sorted = entries.sorted {
                    if $0.name == ".." { return true }
                    if $1.name == ".." { return false }
                    if $0.isDirectory != $1.isDirectory {
                        return $0.isDirectory && !$1.isDirectory
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

                isLoadingRemote = false
                currentRemotePath = targetPath
                remoteEntries = sorted
                statusMessage = "Remote: \(targetPath)"
            } catch {
                refreshRemoteWithNMSSH(targetPath: targetPath, priorError: error.localizedDescription)
            }
        }
    }

    private func uploadEmbedded(localURLs: [URL]) {
        let files = localURLs.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        guard !isTransferring else {
            statusMessage = "Transfer already running"
            return
        }

        isTransferring = true
        canCancelTransfer = true
        statusMessage = "Uploading \(files.count) item(s)..."
        let target = normalizeEmbeddedRemotePath(currentRemotePath)

        Task {
            do {
                let client = try await ensureEmbeddedSFTPClient()
                for url in files {
                    try await uploadItem(client: client, localURL: url, remoteDirectory: target)
                }
                isTransferring = false
                canCancelTransfer = false
                statusMessage = "Upload complete"
                refreshRemoteEmbedded()
            } catch {
                uploadWithNMSSH(localURLs: files, remoteDirectory: target, priorError: error.localizedDescription)
            }
        }
    }

    private func downloadEmbedded(remotePaths: [String]) {
        let validPaths = remotePaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validPaths.isEmpty else { return }
        guard !isTransferring else {
            statusMessage = "Transfer already running"
            return
        }

        isTransferring = true
        canCancelTransfer = true
        statusMessage = "Downloading \(validPaths.count) item(s)..."
        let destination = currentLocalURL

        Task {
            do {
                let client = try await ensureEmbeddedSFTPClient()
                for path in validPaths {
                    try await downloadItem(client: client, remotePath: path, localDirectory: destination)
                }
                isTransferring = false
                canCancelTransfer = false
                statusMessage = "Download complete"
                refreshLocal()
            } catch {
                downloadWithNMSSH(remotePaths: validPaths, localDirectory: destination, priorError: error.localizedDescription)
            }
        }
    }

    private func ensureEmbeddedSFTPClient() async throws -> SFTPClient {
        if let embeddedSFTPClient {
            return embeddedSFTPClient
        }
        if let embeddedConnection {
            let client = try await requestSFTPClient(from: embeddedConnection)
            embeddedSFTPClient = client
            return client
        }

        guard let password = storedPassword, !password.isEmpty else {
            throw NSError(domain: "AnotherShell.SFTP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Password required"])
        }

        let connection = SSHConnection(
            host: host.hostname,
            port: UInt16(clamping: host.port),
            authentication: SSHAuthentication(
                username: host.username,
                method: .password(.init(password)),
                hostKeyValidation: .acceptAll()
            ),
            queue: ioQueue,
            defaultTimeout: 15
        )
        try await start(connection: connection)
        let client = try await requestSFTPClient(from: connection)
        embeddedConnection = connection
        embeddedSFTPClient = client
        return client
    }

    private func start(connection: SSHConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.start { result in
                continuation.resume(with: result)
            }
        }
    }

    private func requestSFTPClient(from connection: SSHConnection) async throws -> SFTPClient {
        try await withCheckedThrowingContinuation { continuation in
            connection.requestSFTPClient { result in
                continuation.resume(with: result)
            }
        }
    }

    private func listDirectory(client: SFTPClient, path: String) async throws -> [SFTPPathComponent] {
        try await withCheckedThrowingContinuation { continuation in
            client.listDirectory(at: SFTPFilePath(path)) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func createDirectory(client: SFTPClient, path: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            client.createDirectory(at: SFTPFilePath(path)) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func openFileForRead(client: SFTPClient, path: String) async throws -> SFTPFile {
        try await withCheckedThrowingContinuation { continuation in
            client.openFile(at: SFTPFilePath(path), flags: [.read]) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func openFileForWrite(client: SFTPClient, path: String) async throws -> SFTPFile {
        try await withCheckedThrowingContinuation { continuation in
            client.openFile(at: SFTPFilePath(path), flags: [.write, .create, .truncate]) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func readAll(file: SFTPFile) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            file.read { result in
                continuation.resume(with: result)
            }
        }
    }

    private func writeAll(file: SFTPFile, data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            file.write(data) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func close(file: SFTPFile) async throws {
        try await withCheckedThrowingContinuation { continuation in
            file.close { result in
                continuation.resume(with: result)
            }
        }
    }

    private func remoteEntry(from component: SFTPPathComponent, basePath: String) -> RemoteFileEntry? {
        let name = component.filename.string
        guard name != "." else { return nil }

        let longname = component.longname
        let typeChar = longname.first ?? "-"
        let isDirectory = typeChar == "d"
        let permissions = component.attributes.permissions ?? 0
        let modified: String
        if let time = component.attributes.accessModificationTime?.modificationTime {
            modified = sftpShortTimestamp(time)
        } else {
            modified = ""
        }

        let path: String
        if name == ".." {
            let parent = remoteParentPath(basePath)
            guard parent != basePath else { return nil }
            path = parent
        } else {
            path = remoteJoin(basePath: basePath, name: name)
        }

        return RemoteFileEntry(
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: Int64(component.attributes.size ?? 0),
            modified: modified,
            permission: String(permissions, radix: 8)
        )
    }

    private func uploadItem(client: SFTPClient, localURL: URL, remoteDirectory: String) async throws {
        let remotePath = remoteJoin(basePath: remoteDirectory, name: localURL.lastPathComponent)
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            try? await createDirectory(client: client, path: remotePath)
            let children = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: [.isDirectoryKey])
            for child in children {
                try await uploadItem(client: client, localURL: child, remoteDirectory: remotePath)
            }
            return
        }

        let data = try Data(contentsOf: localURL)
        let file = try await openFileForWrite(client: client, path: remotePath)
        try await writeAll(file: file, data: data)
        try await close(file: file)
    }

    private func downloadItem(client: SFTPClient, remotePath: String, localDirectory: URL) async throws {
        let entry = remoteEntries.first(where: { $0.path == remotePath })
        let targetURL = localDirectory.appendingPathComponent((entry?.name ?? URL(fileURLWithPath: remotePath).lastPathComponent))

        if entry?.isDirectory == true {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            let children = try await listDirectory(client: client, path: remotePath)
            for child in children {
                let name = child.filename.string
                if name == "." || name == ".." { continue }
                try await downloadItem(client: client, remotePath: remoteJoin(basePath: remotePath, name: name), localDirectory: targetURL)
            }
            return
        }

        let file = try await openFileForRead(client: client, path: remotePath)
        let data = try await readAll(file: file)
        try await close(file: file)
        try data.write(to: targetURL, options: .atomic)
    }

    private func normalizeEmbeddedRemotePath(_ path: String) -> String {
        let trimmed = normalizePathForSFTP(path.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.isEmpty || trimmed == "~" {
            return "."
        }
        return trimmed
    }
#endif

    private func refreshRemoteWithNMSSH(targetPath: String, priorError: String) {
        let host = self.host
        let password = storedPassword
        ioQueue.async { [weak self] in
            guard let self else { return }

            do {
                let bridge = try self.createAndConnectNMSSHBridge(host: host, password: password)
                var failureReason: NSString?
                guard let rawItems = bridge.contentsOfDirectory(atPath: targetPath, failureReason: &failureReason) as? [[String: Any]] else {
                    let reason = (failureReason as String?) ?? priorError
                    DispatchQueue.main.async {
                        self.isLoadingRemote = false
                        self.canRequestPermission = self.looksPermissionDenied(reason)
                        self.lastPermissionDeniedPath = self.canRequestPermission ? targetPath : nil
                        self.statusMessage = "Remote refresh failed: \(reason)"
                    }
                    return
                }
                bridge.disconnect()

                let entries = rawItems.compactMap { self.remoteEntryFromNMSSH($0, basePath: targetPath) }
                    .sorted {
                        if $0.name == ".." { return true }
                        if $1.name == ".." { return false }
                        if $0.isDirectory != $1.isDirectory {
                            return $0.isDirectory && !$1.isDirectory
                        }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }

                DispatchQueue.main.async {
                    self.isLoadingRemote = false
                    self.currentRemotePath = targetPath
                    self.remoteEntries = entries
                    self.canRequestPermission = false
                    self.lastPermissionDeniedPath = nil
                    self.statusMessage = "Remote: \(targetPath)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoadingRemote = false
                    let reason = error.localizedDescription
                    self.canRequestPermission = self.looksPermissionDenied(reason)
                    self.lastPermissionDeniedPath = self.canRequestPermission ? targetPath : nil
                    self.statusMessage = "Remote refresh failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func uploadWithNMSSH(localURLs: [URL], remoteDirectory: String, priorError: String) {
        let host = self.host
        let password = storedPassword
        let cancellation = transferCancellation
        ioQueue.async { [weak self] in
            guard let self else { return }
            var createdRemoteItems: [RemoteCleanupItem] = []

            do {
                let bridge = try self.createAndConnectNMSSHBridge(host: host, password: password)
                defer { bridge.disconnect() }

                for (index, url) in localURLs.enumerated() {
                    try self.throwIfTransferCancelled(cancellation)
                    let baseProgress = Double(index) / Double(max(localURLs.count, 1))
                    let progressWeight = 1 / Double(max(localURLs.count, 1))
                    try self.uploadItemWithNMSSH(
                        bridge: bridge,
                        localURL: url,
                        remoteDirectory: remoteDirectory,
                        cancellation: cancellation,
                        createdRemoteItems: &createdRemoteItems
                    ) { fraction in
                        DispatchQueue.main.async {
                            self.transferProgress = min(0.999, baseProgress + (progressWeight * fraction))
                        }
                    }

                    DispatchQueue.main.async {
                        self.transferProgress = Double(index + 1) / Double(max(localURLs.count, 1))
                    }
                }

                DispatchQueue.main.async {
                    self.isTransferring = false
                    self.canCancelTransfer = false
                    self.transferProgress = 1
                    self.canRetryTransfer = false
                    self.statusMessage = "Upload complete"
                    self.refreshRemote()
                }
            } catch {
                if !createdRemoteItems.isEmpty, let cleanupBridge = try? self.createAndConnectNMSSHBridge(host: host, password: password) {
                    self.cleanupRemoteItems(createdRemoteItems, bridge: cleanupBridge)
                    cleanupBridge.disconnect()
                }
                let isCancelled = self.isTransferCancelled(error, cancellation: cancellation)
                DispatchQueue.main.async {
                    self.isTransferring = false
                    self.canCancelTransfer = false
                    self.canRetryTransfer = !isCancelled
                    self.statusMessage = isCancelled
                        ? "Upload cancelled. Partial files cleaned up."
                        : "Upload failed: \(error.localizedDescription.isEmpty ? priorError : error.localizedDescription)"
                    self.refreshRemote()
                }
            }
        }
    }

    private func downloadWithNMSSH(remotePaths: [String], localDirectory: URL, priorError: String) {
        let host = self.host
        let password = storedPassword
        let cancellation = transferCancellation
        ioQueue.async { [weak self] in
            guard let self else { return }
            var createdLocalItems: [URL] = []

            do {
                let bridge = try self.createAndConnectNMSSHBridge(host: host, password: password)
                defer { bridge.disconnect() }

                for (index, remotePath) in remotePaths.enumerated() {
                    try self.throwIfTransferCancelled(cancellation)
                    let baseProgress = Double(index) / Double(max(remotePaths.count, 1))
                    let progressWeight = 1 / Double(max(remotePaths.count, 1))
                    try self.downloadItemWithNMSSH(
                        bridge: bridge,
                        remotePath: remotePath,
                        localDirectory: localDirectory,
                        cancellation: cancellation,
                        createdLocalItems: &createdLocalItems
                    ) { fraction in
                        DispatchQueue.main.async {
                            self.transferProgress = min(0.999, baseProgress + (progressWeight * fraction))
                        }
                    }

                    DispatchQueue.main.async {
                        self.transferProgress = Double(index + 1) / Double(max(remotePaths.count, 1))
                    }
                }

                DispatchQueue.main.async {
                    self.isTransferring = false
                    self.canCancelTransfer = false
                    self.transferProgress = 1
                    self.canRetryTransfer = false
                    self.statusMessage = "Download complete"
                    self.refreshLocal()
                }
            } catch {
                if !createdLocalItems.isEmpty {
                    self.cleanupLocalItems(createdLocalItems)
                }
                let isCancelled = self.isTransferCancelled(error, cancellation: cancellation)
                DispatchQueue.main.async {
                    self.isTransferring = false
                    self.canCancelTransfer = false
                    self.canRetryTransfer = !isCancelled
                    self.statusMessage = isCancelled
                        ? "Download cancelled. Partial files cleaned up."
                        : "Download failed: \(error.localizedDescription.isEmpty ? priorError : error.localizedDescription)"
                    self.refreshLocal()
                }
            }
        }
    }

    nonisolated private func createAndConnectNMSSHBridge(host: SSHHost, password: String?) throws -> ASNMSSHSFTPBridge {
        guard let password, !password.isEmpty else {
            throw NSError(domain: "AnotherShell.SFTP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Password required"])
        }

        let bridge = ASNMSSHSFTPBridge(
            host: host.hostname,
            port: host.port,
            username: host.username,
            password: password
        )
        var failureReason: NSString?
        guard bridge.connect(&failureReason) else {
            throw NSError(
                domain: "AnotherShell.SFTP",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: (failureReason as String?) ?? "SFTP authentication failed"]
            )
        }
        return bridge
    }

    nonisolated private func remoteEntryFromNMSSH(_ item: [String: Any], basePath: String) -> RemoteFileEntry? {
        guard let name = item["filename"] as? String, name != "." else {
            return nil
        }

        let isDirectory = item["isDirectory"] as? Bool ?? false
        let size = (item["fileSize"] as? NSNumber)?.int64Value ?? 0
        let permission = item["permissions"] as? String ?? ""
        let modified: String
        if let date = item["modificationDate"] as? Date {
            modified = sftpShortTimestamp(date)
        } else {
            modified = ""
        }

        let path: String
        if name == ".." {
            let parent = remoteParentPath(basePath)
            guard parent != basePath else { return nil }
            path = parent
        } else {
            path = remoteJoin(basePath: basePath, name: name)
        }

        return RemoteFileEntry(
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: size,
            modified: modified,
            permission: permission
        )
    }

    nonisolated private func looksPermissionDenied(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("permission denied") ||
            lowered.contains("operation not permitted") ||
            lowered.contains("access denied")
    }

    nonisolated private func uploadItemWithNMSSH(
        bridge: ASNMSSHSFTPBridge,
        localURL: URL,
        remoteDirectory: String,
        cancellation: TransferCancellationState,
        createdRemoteItems: inout [RemoteCleanupItem],
        progress: @escaping (Double) -> Void
    ) throws {
        let remotePath = remoteJoin(basePath: remoteDirectory, name: localURL.lastPathComponent)
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            try throwIfTransferCancelled(cancellation)
            var infoFailure: NSString?
            let existingInfo = bridge.fileInfo(atPath: remotePath, failureReason: &infoFailure) as? [String: Any]
            let existedAlready = existingInfo != nil
            if let existingInfo, (existingInfo["isDirectory"] as? Bool) == false {
                throw SFTPTransferError.message("Remote path already exists as a file: \(remotePath)")
            }
            var failureReason: NSString?
            guard existedAlready || bridge.createDirectory(atPath: remotePath, failureReason: &failureReason) else {
                throw NSError(domain: "AnotherShell.SFTP", code: 4, userInfo: [NSLocalizedDescriptionKey: (failureReason as String?) ?? "Failed to create directory"])
            }
            if !existedAlready {
                createdRemoteItems.append(RemoteCleanupItem(path: remotePath, recursive: true))
            }

            let children = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: [.isDirectoryKey])
            for child in children {
                try uploadItemWithNMSSH(
                    bridge: bridge,
                    localURL: child,
                    remoteDirectory: remotePath,
                    cancellation: cancellation,
                    createdRemoteItems: &createdRemoteItems,
                    progress: progress
                )
            }
            progress(1)
            return
        }

        try throwIfTransferCancelled(cancellation)
        var infoFailure: NSString?
        let existingInfo = bridge.fileInfo(atPath: remotePath, failureReason: &infoFailure) as? [String: Any]
        if let existingInfo, (existingInfo["isDirectory"] as? Bool) == true {
            throw SFTPTransferError.message("Remote path already exists as a directory: \(remotePath)")
        }

        let tempRemotePath = remoteTemporaryPath(for: remotePath)
        var failureReason: NSString?
        _ = bridge.removeItem(atPath: tempRemotePath, recursive: false, failureReason: nil)

        guard bridge.uploadFile(atLocalPath: localURL.path, toPath: tempRemotePath, progress: { completedBytes, totalBytes in
            let total = max(totalBytes, 1)
            progress(min(1, Double(completedBytes) / Double(total)))
            return !cancellation.isCancelled
        }, failureReason: &failureReason) else {
            _ = bridge.removeItem(atPath: tempRemotePath, recursive: false, failureReason: nil)
            if cancellation.isCancelled || (failureReason as String?) == "Transfer cancelled" {
                throw SFTPTransferError.cancelled
            }
            throw NSError(domain: "AnotherShell.SFTP", code: 5, userInfo: [NSLocalizedDescriptionKey: (failureReason as String?) ?? "Failed to upload file"])
        }

        try throwIfTransferCancelled(cancellation)

        if existingInfo != nil {
            var removeFailure: NSString?
            guard bridge.removeItem(atPath: remotePath, recursive: false, failureReason: &removeFailure) else {
                _ = bridge.removeItem(atPath: tempRemotePath, recursive: false, failureReason: nil)
                throw NSError(domain: "AnotherShell.SFTP", code: 5, userInfo: [NSLocalizedDescriptionKey: (removeFailure as String?) ?? "Failed to replace remote file"])
            }
        }

        var moveFailure: NSString?
        guard bridge.moveItem(atPath: tempRemotePath, toPath: remotePath, failureReason: &moveFailure) else {
            _ = bridge.removeItem(atPath: tempRemotePath, recursive: false, failureReason: nil)
            throw NSError(domain: "AnotherShell.SFTP", code: 5, userInfo: [NSLocalizedDescriptionKey: (moveFailure as String?) ?? "Failed to finalize remote upload"])
        }
        if existingInfo == nil {
            createdRemoteItems.append(RemoteCleanupItem(path: remotePath, recursive: false))
        }
        progress(1)
    }

    nonisolated private func downloadItemWithNMSSH(
        bridge: ASNMSSHSFTPBridge,
        remotePath: String,
        localDirectory: URL,
        cancellation: TransferCancellationState,
        createdLocalItems: inout [URL],
        progress: @escaping (Double) -> Void
    ) throws {
        var failureReason: NSString?
        guard let info = bridge.fileInfo(atPath: remotePath, failureReason: &failureReason) as? [String: Any] else {
            throw NSError(domain: "AnotherShell.SFTP", code: 6, userInfo: [NSLocalizedDescriptionKey: (failureReason as String?) ?? "Failed to read file info"])
        }

        let name = (info["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: remotePath).lastPathComponent
        let targetURL = localDirectory.appendingPathComponent(name)
        let isDirectory = info["isDirectory"] as? Bool ?? false

        if isDirectory {
            try throwIfTransferCancelled(cancellation)
            let fm = FileManager.default
            let existedAlready = fm.fileExists(atPath: targetURL.path)
            if existedAlready {
                var isDirectoryFlag: ObjCBool = false
                guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDirectoryFlag), isDirectoryFlag.boolValue else {
                    throw SFTPTransferError.message("Local path already exists as a file: \(targetURL.lastPathComponent)")
                }
            } else {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                createdLocalItems.append(targetURL)
            }
            var listFailure: NSString?
            guard let children = bridge.contentsOfDirectory(atPath: remotePath, failureReason: &listFailure) as? [[String: Any]] else {
                throw NSError(domain: "AnotherShell.SFTP", code: 7, userInfo: [NSLocalizedDescriptionKey: (listFailure as String?) ?? "Failed to list directory"])
            }

            for child in children {
                guard let childName = child["filename"] as? String, childName != ".", childName != ".." else { continue }
                try downloadItemWithNMSSH(
                    bridge: bridge,
                    remotePath: remoteJoin(basePath: remotePath, name: childName),
                    localDirectory: targetURL,
                    cancellation: cancellation,
                    createdLocalItems: &createdLocalItems,
                    progress: progress
                )
            }
            progress(1)
            return
        }

        try throwIfTransferCancelled(cancellation)
        let fm = FileManager.default
        var isDirectoryFlag: ObjCBool = false
        let existedAlready = fm.fileExists(atPath: targetURL.path, isDirectory: &isDirectoryFlag)
        if existedAlready && isDirectoryFlag.boolValue {
            throw SFTPTransferError.message("Local path already exists as a directory: \(targetURL.lastPathComponent)")
        }

        let temporaryURL = localTemporaryURL(for: targetURL)
        try? fm.removeItem(at: temporaryURL)
        var readFailure: NSString?
        guard bridge.downloadFile(atPath: remotePath, toLocalPath: temporaryURL.path, progress: { completedBytes, totalBytes in
            let total = max(totalBytes, 1)
            progress(min(1, Double(completedBytes) / Double(total)))
            return !cancellation.isCancelled
        }, failureReason: &readFailure) else {
            try? fm.removeItem(at: temporaryURL)
            if cancellation.isCancelled || (readFailure as String?) == "Transfer cancelled" {
                throw SFTPTransferError.cancelled
            }
            throw NSError(domain: "AnotherShell.SFTP", code: 8, userInfo: [NSLocalizedDescriptionKey: (readFailure as String?) ?? "Failed to download file"])
        }

        try throwIfTransferCancelled(cancellation)

        if existedAlready {
            try fm.removeItem(at: targetURL)
        }
        try fm.moveItem(at: temporaryURL, to: targetURL)
        if !existedAlready {
            createdLocalItems.append(targetURL)
        }
        progress(1)
    }

    nonisolated private func throwIfTransferCancelled(_ cancellation: TransferCancellationState) throws {
        if cancellation.isCancelled {
            throw SFTPTransferError.cancelled
        }
    }

    nonisolated private func isTransferCancelled(_ error: Error, cancellation: TransferCancellationState) -> Bool {
        if cancellation.isCancelled {
            return true
        }
        if let transferError = error as? SFTPTransferError, transferError == .cancelled {
            return true
        }
        return error.localizedDescription == "Transfer cancelled"
    }

    nonisolated private func remoteTemporaryPath(for remotePath: String) -> String {
        "\(remotePath).anothershell-part-\(UUID().uuidString)"
    }

    nonisolated private func localTemporaryURL(for targetURL: URL) -> URL {
        targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).anothershell-part-\(UUID().uuidString)")
    }

    nonisolated private func cleanupRemoteItems(_ items: [RemoteCleanupItem], bridge: ASNMSSHSFTPBridge) {
        var seen = Set<String>()
        for item in items.reversed() where seen.insert(item.path).inserted {
            _ = bridge.removeItem(atPath: item.path, recursive: item.recursive, failureReason: nil)
        }
    }

    nonisolated private func cleanupLocalItems(_ items: [URL]) {
        let fm = FileManager.default
        var seen = Set<String>()
        for url in items.reversed() where seen.insert(url.path).inserted {
            try? fm.removeItem(at: url)
        }
    }
}
