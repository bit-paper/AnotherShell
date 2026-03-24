import Foundation
import Darwin
import Combine
#if canImport(SSHClient)
import SSHClient
#endif

enum SSHSessionState: String {
    case idle
    case connecting
    case connected
    case disconnected
    case failed

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Failed"
        }
    }
}

struct RemoteSystemStatus: Equatable {
    var os: String
    var model: String
    var memory: String
    var disk: String
    var updatedAt: Date?
    var error: String?

    static let empty = RemoteSystemStatus(
        os: "--",
        model: "--",
        memory: "--",
        disk: "--",
        updatedAt: nil,
        error: nil
    )
}

final class SSHSession: ObservableObject, Identifiable {
    private struct LaunchCommand {
        let executablePath: String
        let arguments: [String]
        let extraEnvironment: [String: String]
        let usesExpectBridge: Bool
        let temporaryScriptURL: URL?
    }

    private enum PasswordSubmitReason {
        case challengePrompt

        var logMessage: String {
            switch self {
            case .challengePrompt:
                return "Detected authentication challenge. Submitting saved password..."
            }
        }
    }

    let id = UUID()
    let host: SSHHost
    let createdAt = Date()
    private let initialPassword: String?
    var reusablePassword: String? { storedPassword }

    @Published private(set) var state: SSHSessionState = .idle
    @Published private(set) var output: String = ""
    @Published private(set) var outputRevision: Int = 0
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isUploading: Bool = false
    @Published private(set) var needsPasswordRetry: Bool = false
    @Published private(set) var remoteSystemStatus: RemoteSystemStatus = .empty
    @Published private(set) var terminalSurfaceID = UUID()
    @Published private(set) var currentWorkingDirectory: String?
    @Published private(set) var inboundBytesPerSecond: Double = 0
    @Published private(set) var outboundBytesPerSecond: Double = 0
    @Published private(set) var inboundSpeedHistory: [Double] = []
    @Published private(set) var outboundSpeedHistory: [Double] = []
    @Published private(set) var memoryUsagePercent: Double?
    @Published private(set) var memoryUsageHistory: [Double] = []

    private var childPID: pid_t = -1
    private var logFileHandle: FileHandle?
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var masterFD: Int32 = -1
    private var isDisconnectRequested = false

    private var authScanTail = ""
    private var passwordAutoFillCount = 0
    private var lastPasswordAutoFillAt = Date.distantPast
    private var storedPassword: String?
    private var didAutoSubmitStoredPassword = false
    private var sawPermissionDenied = false
    private var sawAuthenticationPrompt = false
    private var didAnnounceConnected = false
    private var acceptedHostKeyPrompt = false
    private var usesExpectBridge = false
    private var temporaryBridgeScriptURL: URL?
    private var controlSocketURL: URL?
    private let ioQueue = DispatchQueue(label: "com.anothershell.session.io")
    private let metricsQueue = DispatchQueue(label: "com.anothershell.session.metrics")
    private let maxOutputCount = 600_000
    private let maxHistorySamples = 90
    private var terminalOutputListeners: [UUID: (Data) -> Void] = [:]
    private var nmsshBridge: ASNMSSHSessionBridge?
    private var systemStatusTimer: DispatchSourceTimer?
    private var throughputTimer: DispatchSourceTimer?
    private var inboundBytesTotal: UInt64 = 0
    private var outboundBytesTotal: UInt64 = 0
    private var lastInboundSample: UInt64 = 0
    private var lastOutboundSample: UInt64 = 0
    private var throughputSampleInterval: TimeInterval = 1.0
    private let replayQueue = DispatchQueue(label: "com.anothershell.session.replay")
    private let replayQueueKey = DispatchSpecificKey<Void>()
    private var terminalReplayBuffer = Data()
    private let maxReplayBufferBytes = 1_500_000
    private let terminalKeywordHighlighter = TerminalKeywordHighlighter()
#if canImport(SSHClient)
    private var embeddedConnection: SSHConnection?
    private var embeddedShell: SSHShell?
#endif

    init(host: SSHHost, initialPassword: String? = nil) {
        self.host = host
        self.initialPassword = initialPassword
        replayQueue.setSpecific(key: replayQueueKey, value: ())
        prepareLogFile()
    }

    deinit {
        stopSystemStatusPolling()
        stopThroughputSampling()
        if childPID > 0 {
            Darwin.kill(childPID, SIGTERM)
        }

        readSource?.cancel()
        readSource = nil
        processSource?.cancel()
        processSource = nil

        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }

        ExpectCommandBridge.removeScript(at: temporaryBridgeScriptURL)
        temporaryBridgeScriptURL = nil
        closeControlMasterIfNeeded()

        logFileHandle?.closeFile()
        logFileHandle = nil
    }

    func connect(overridePassword: String? = nil) {
        if state == .connected || state == .connecting {
            return
        }

        resetRuntimeStateForConnection()
        resolveStoredPassword(overridePassword: overridePassword)

        if host.prefersPasswordAuthentication {
            connectUsingNMSSHBridge(reason: "Using embedded libssh2 SSH client.")
            return
        }

        let isolatedSSHHome = SSHKnownHostsStore.sshHomeDirectoryPath()

        if host.prefersPasswordAuthentication,
           storedPassword != nil,
           !prepareControlMasterIfNeeded() {
            setState(.failed, message: "Authentication failed")
            appendSystem("Failed to establish authenticated SSH master connection.")
            appendSystem("Session terminated with code 255")
            return
        }

        setState(.connecting, message: "Connecting to \(host.address)...")

        var master: Int32 = 0
        let launch = buildLaunchCommand(baseSSHArguments: host.buildSSHArguments())
        usesExpectBridge = launch.usesExpectBridge
        temporaryBridgeScriptURL = launch.temporaryScriptURL
        let execArguments = [launch.executablePath] + launch.arguments
        let sshArguments = execArguments
        var cArguments: [UnsafeMutablePointer<CChar>?] = sshArguments.map { strdup($0) }
        cArguments.append(nil)

        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cArguments.count)
        for index in cArguments.indices {
            argv[index] = cArguments[index]
        }

        let pid = forkpty(&master, nil, nil, nil)
        if pid < 0 {
            let errnoValue = errno
            for item in cArguments where item != nil {
                free(item)
            }
            argv.deallocate()
            if master >= 0 {
                Darwin.close(master)
            }
            setState(.failed, message: "Failed to allocate PTY: errno=\(errnoValue)")
            appendSystem("PTY allocation failed. errno=\(errnoValue)")
            return
        }

        if pid == 0 {
            setenv("HOME", isolatedSSHHome, 1)
            if !launch.extraEnvironment.isEmpty {
                for (key, value) in launch.extraEnvironment {
                    setenv(key, value, 1)
                }
            }
            execv(launch.executablePath, argv)
            _exit(127)
        }

        for item in cArguments where item != nil {
            free(item)
        }
        argv.deallocate()

        childPID = pid
        self.masterFD = master
        startProcessExitWatcher(for: pid)

        appendSystem("Session started for \(host.address)")
        setState(.connecting, message: "Authenticating \(host.address)...")

        startReading()
    }

    func disconnect() {
        isDisconnectRequested = true

#if canImport(SSHClient)
        if disconnectEmbeddedIfNeeded() {
            return
        }
#endif

        if disconnectNMSSHIfNeeded() {
            return
        }

        if childPID > 0 {
            Darwin.kill(childPID, SIGTERM)
            return
        }

        cleanupIO()
        setState(.disconnected, message: "Disconnected")
    }

    func clearOutput() {
        DispatchQueue.main.async {
            self.output = ""
            self.outputRevision += 1
            self.terminalSurfaceID = UUID()
        }
    }

    func sendCommand(_ command: String) {
        let line = command.hasSuffix("\n") ? command : command + "\n"
        sendRaw(line)
    }

    func sendRaw(_ text: String) {
        guard !text.isEmpty else { return }
        sendData(Data(text.utf8))
    }

    func sendData(_ data: Data) {
        guard !data.isEmpty else { return }
        guard state == .connected || state == .connecting else { return }
        accumulateOutboundBytes(data.count)
        if let nmsshBridge {
            nmsshBridge.write(data)
            return
        }
#if canImport(SSHClient)
        if let embeddedShell {
            embeddedShell.write(data) { _ in }
            return
        }
#endif
        write(data)
    }

    func sendControlC() {
        guard state == .connected || state == .connecting else { return }
        sendData(Data([0x03]))
    }

    func resizeTerminal(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        if let nmsshBridge {
            nmsshBridge.resize(withColumns: UInt(columns), rows: UInt(rows))
            return
        }
    }

    @discardableResult
    func addTerminalOutputListener(_ listener: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        DispatchQueue.main.async {
            self.terminalOutputListeners[id] = listener
        }
        return id
    }

    func removeTerminalOutputListener(_ id: UUID) {
        DispatchQueue.main.async {
            self.terminalOutputListeners.removeValue(forKey: id)
        }
    }

    func clearPasswordRetryRequest() {
        DispatchQueue.main.async {
            self.needsPasswordRetry = false
        }
    }

    func terminalReplaySnapshot() -> Data {
        replayQueue.sync { terminalReplayBuffer }
    }

    func updateWorkingDirectory(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            self.currentWorkingDirectory = (trimmed?.isEmpty == false) ? trimmed : nil
        }
    }

    func upload(localFileURL: URL, remotePath: String) {
        let trimmedRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRemotePath.isEmpty else {
            appendSystem("Upload aborted: remote path is empty")
            return
        }

        if isUploading {
            appendSystem("Upload skipped: a transfer is already in progress")
            return
        }

        DispatchQueue.main.async {
            self.isUploading = true
        }

        appendSystem("Uploading \(localFileURL.lastPathComponent) to \(trimmedRemotePath)...")
        let arguments = host.buildSCPUploadArguments(localURL: localFileURL, remotePath: trimmedRemotePath)
        let password = host.prefersPasswordAuthentication ? KeychainPasswordStore.load(for: host) : nil

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = AuthCommandRunner.run(
                binaryPath: "/usr/bin/scp",
                arguments: arguments,
                password: password
            )

            DispatchQueue.main.async {
                guard let self else { return }
                self.isUploading = false

                if result.code == 0 {
                    self.appendSystem("Upload completed: \(localFileURL.lastPathComponent) -> \(trimmedRemotePath)")
                } else {
                    let trimmedLog = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let reason = trimmedLog.isEmpty ? "exit code \(result.code)" : trimmedLog
                    self.appendSystem("Upload failed: \(reason)")
                }
            }
        }
    }

    private func resetRuntimeStateForConnection() {
        isDisconnectRequested = false
        needsPasswordRetry = false
        authScanTail = ""
        passwordAutoFillCount = 0
        lastPasswordAutoFillAt = .distantPast
        didAutoSubmitStoredPassword = false
        sawPermissionDenied = false
        sawAuthenticationPrompt = false
        didAnnounceConnected = false
        acceptedHostKeyPrompt = false
        usesExpectBridge = false
        ExpectCommandBridge.removeScript(at: temporaryBridgeScriptURL)
        temporaryBridgeScriptURL = nil
        closeControlMasterIfNeeded()
        stopSystemStatusPolling()
        stopThroughputSampling()
        resetMetrics()
        DispatchQueue.main.async {
            self.remoteSystemStatus = .empty
            self.terminalSurfaceID = UUID()
            self.currentWorkingDirectory = nil
            self.inboundBytesPerSecond = 0
            self.outboundBytesPerSecond = 0
            self.inboundSpeedHistory = []
            self.outboundSpeedHistory = []
            self.memoryUsagePercent = nil
            self.memoryUsageHistory = []
        }
        replayQueue.sync {
            terminalReplayBuffer.removeAll(keepingCapacity: true)
        }
        nmsshBridge?.disconnect()
        nmsshBridge = nil
#if canImport(SSHClient)
        embeddedShell = nil
        embeddedConnection = nil
#endif
    }

    private func resolveStoredPassword(overridePassword: String?) {
        if host.prefersPasswordAuthentication {
            if let supplied = overridePassword, !supplied.isEmpty {
                let cleaned = sanitizePassword(supplied)
                storedPassword = cleaned
                appendSystem("Password source: prompt input (\(cleaned.count) chars).")
            } else {
                let candidate = initialPassword ?? KeychainPasswordStore.load(for: host)
                storedPassword = candidate.map(sanitizePassword)
                if let storedPassword {
                    appendSystem("Password source: saved store (\(storedPassword.count) chars).")
                } else {
                    appendSystem("Password source: manual terminal entry.")
                }
            }
        } else {
            storedPassword = nil
        }
    }

    private func startReading() {
        guard masterFD >= 0 else { return }

        let flags = fcntl(masterFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.drainMasterOutput()
        }
        source.setCancelHandler { }

        readSource = source
        source.resume()
    }

    private func drainMasterOutput() {
        guard masterFD >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let readBytes = Darwin.read(masterFD, &buffer, buffer.count)

            if readBytes > 0 {
                let data = Data(buffer.prefix(Int(readBytes)))
                let rawChunk = String(decoding: data, as: UTF8.self)
                handleIncomingTerminalData(data)
                processAuthenticationSignals(from: rawChunk)
                maybeMarkConnected(from: ANSITextNormalizer.normalize(rawChunk))
                continue
            }

            if readBytes == 0 {
                break
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }

            break
        }
    }

    private func processAuthenticationSignals(from rawChunk: String) {
        let lowered = normalizedChallengeText(from: rawChunk)
        let scan = authScanTail + lowered
        authScanTail = String(scan.suffix(240))

        if scan.contains("permission denied") {
            sawPermissionDenied = true
        }

        if usesExpectBridge {
            return
        }

        if containsHostKeyConfirmationPrompt(in: scan), !acceptedHostKeyPrompt {
            acceptedHostKeyPrompt = true
            appendSystem("Host key confirmation detected. Accepting once.")
            sendRaw("yes\r")
        }

        if containsAuthenticationPrompt(in: scan) {
            appendSystem("Password prompt detected. Submitting saved password once.")
            sawAuthenticationPrompt = true
            submitStoredPasswordIfPossible(reason: .challengePrompt)
        }

    }

    private func maybeMarkConnected(from normalizedChunk: String) {
        guard !didAnnounceConnected else { return }
        guard state == .connecting else { return }

        let lowered = normalizedChallengeText(from: normalizedChunk)
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let preAuthHints = [
            "password:",
            "passphrase for key",
            "permission denied",
            "authenticity of host",
            "are you sure you want to continue connecting",
            "warning:"
        ]

        if preAuthHints.contains(where: { trimmed.contains($0) }) {
            return
        }

        didAnnounceConnected = true
        setState(.connected, message: "Connected")
        appendSystem("Session connected to \(host.address)")
        startThroughputSamplingIfNeeded()
    }

    private func submitStoredPasswordIfPossible(reason: PasswordSubmitReason) {
        guard host.prefersPasswordAuthentication,
              let password = storedPassword,
              !password.isEmpty else {
            return
        }

        guard passwordAutoFillCount < 8 else { return }

        let minInterval: TimeInterval = 0.2
        guard Date().timeIntervalSince(lastPasswordAutoFillAt) > minInterval else { return }

        sendRaw(password + "\r")
        lastPasswordAutoFillAt = Date()
        passwordAutoFillCount += 1
        didAutoSubmitStoredPassword = true

        if passwordAutoFillCount <= 2 {
            appendSystem(reason.logMessage)
        }
    }

    private func write(_ data: Data) {
        guard masterFD >= 0 else { return }

        data.withUnsafeBytes { rawBuffer in
            guard let basePointer = rawBuffer.baseAddress else { return }
            var sent = 0

            while sent < rawBuffer.count {
                let pointer = basePointer.advanced(by: sent)
                let remaining = rawBuffer.count - sent
                let writeCount = Darwin.write(masterFD, pointer, remaining)

                if writeCount <= 0 {
                    break
                }

                sent += writeCount
            }
        }
    }

    private func handleProcessTermination(exitCode: Int32) {
        let manualDisconnect = isDisconnectRequested
        isDisconnectRequested = false

        cleanupIO()

        if manualDisconnect {
            stopSystemStatusPolling()
            stopThroughputSampling()
            setState(.disconnected, message: "Disconnected")
            appendSystem("Session closed")
            return
        }

        if exitCode == 0 {
            stopSystemStatusPolling()
            stopThroughputSampling()
            setState(.disconnected, message: "Session ended")
            appendSystem("Session closed")
            return
        }

        if host.prefersPasswordAuthentication, sawPermissionDenied {
            if didAutoSubmitStoredPassword {
                appendSystem("Authentication failed with saved password. Please verify and retry.")
                requestPasswordRetry()
            } else {
                appendSystem("Authentication failed. Server requested password auth but credentials were not accepted.")
            }
        }

        setState(.failed, message: "Exited with code \(exitCode)")
        appendSystem("Session terminated with code \(exitCode)")
    }

    private func requestPasswordRetry() {
        DispatchQueue.main.async {
            self.needsPasswordRetry = true
        }
    }

    private func cleanupIO() {
        stopSystemStatusPolling()
        stopThroughputSampling()
        if let source = readSource {
            source.cancel()
            readSource = nil
        }

        if let source = processSource {
            source.cancel()
            processSource = nil
        }

        ExpectCommandBridge.removeScript(at: temporaryBridgeScriptURL)
        temporaryBridgeScriptURL = nil
        closeControlMasterIfNeeded()

        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }

        if childPID > 0 {
            var status: Int32 = 0
            _ = waitpid(childPID, &status, WNOHANG)
            childPID = -1
        }

        logFileHandle?.closeFile()
        logFileHandle = nil
    }

    private func appendOutput(_ text: String) {
        appendOutput(text, alsoFeedTerminal: true)
    }

    private func appendOutput(_ text: String, alsoFeedTerminal: Bool) {
        guard !text.isEmpty else { return }
        let normalizedText = ANSITextNormalizer.normalize(text)
        guard !normalizedText.isEmpty else { return }
        appendToLogFile(normalizedText)
        if alsoFeedTerminal, let data = normalizedText.data(using: .utf8) {
            emitTerminalData(data)
        }

        DispatchQueue.main.async {
            self.output.append(normalizedText)

            if self.output.count > self.maxOutputCount {
                let overflow = self.output.count - self.maxOutputCount
                self.output.removeFirst(overflow)
            }

            self.outputRevision += 1
        }
    }

    private func handleIncomingTerminalData(_ data: Data) {
        guard !data.isEmpty else { return }
        let displayData = terminalKeywordHighlighter.highlight(data: data)
        appendReplayData(data)
        accumulateInboundBytes(data.count)
        emitTerminalData(displayData)
        let decoded = decodeTerminalData(data)
        appendOutput(decoded, alsoFeedTerminal: false)
    }

    private func appendReplayData(_ data: Data) {
        let appendBlock = {
            self.terminalReplayBuffer.append(data)
            if self.terminalReplayBuffer.count > self.maxReplayBufferBytes {
                let overflow = self.terminalReplayBuffer.count - self.maxReplayBufferBytes
                var trimCount = overflow
                if let newlineIndex = self.terminalReplayBuffer.dropFirst(overflow).firstIndex(of: 0x0A) {
                    trimCount = newlineIndex + 1
                }
                if trimCount >= self.terminalReplayBuffer.count {
                    self.terminalReplayBuffer.removeAll(keepingCapacity: true)
                } else {
                    self.terminalReplayBuffer.removeFirst(trimCount)
                }
            }
        }
        if DispatchQueue.getSpecific(key: replayQueueKey) != nil {
            appendBlock()
        } else {
            replayQueue.sync(execute: appendBlock)
        }
    }

    private func emitTerminalData(_ data: Data) {
        guard !data.isEmpty else { return }
        DispatchQueue.main.async {
            for listener in self.terminalOutputListeners.values {
                listener(data)
            }
        }
    }

    private func appendSystem(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let displayMessage = "[\(timestamp)] \(message)\n"
        appendToLogFile(displayMessage)
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }

    private func setState(_ state: SSHSessionState, message: String) {
        DispatchQueue.main.async {
            self.state = state
            self.statusMessage = message
        }
    }

    private func prepareLogFile() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let logsDirectory = appSupport.appendingPathComponent("AnotherShell/Logs", isDirectory: true)

        do {
            try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        } catch {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let safeHost = host.hostname.replacingOccurrences(of: "/", with: "_")
        let fileURL = logsDirectory.appendingPathComponent("\(safeHost)-\(timestamp)-\(id.uuidString.prefix(8)).log")

        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }

        do {
            logFileHandle = try FileHandle(forWritingTo: fileURL)
            logFileHandle?.seekToEndOfFile()
        } catch {
            logFileHandle = nil
        }
    }

    private func appendToLogFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let logFileHandle else { return }
        do {
            try logFileHandle.write(contentsOf: data)
        } catch {
            // Non-fatal: logging should never break an interactive session.
        }
    }

    private func normalizedChallengeText(from chunk: String) -> String {
        let withoutANSI = chunk.replacingOccurrences(
            of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )

        return withoutANSI
            .replacingOccurrences(of: "\r", with: "")
            .lowercased()
    }

    private func containsAuthenticationPrompt(in text: String) -> Bool {
        let promptHints = [
            "password:",
            "'s password:",
            "passphrase for key",
            "verification code",
            "one-time code",
            "otp",
            "密码"
        ]

        return promptHints.contains { text.contains($0) }
    }

    private func containsHostKeyConfirmationPrompt(in text: String) -> Bool {
        let hints = [
            "are you sure you want to continue connecting",
            "continue connecting (yes/no",
            "host key verification failed"
        ]
        return hints.contains { text.contains($0) }
    }

    private func sanitizePassword(_ password: String) -> String {
        password.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private func decodeTerminalData(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let value = String(data: data, encoding: gb18030) {
            return value
        }

        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GBK_95.rawValue)
            )
        )
        if let value = String(data: data, encoding: gbk) {
            return value
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func buildLaunchCommand(baseSSHArguments: [String]) -> LaunchCommand {
        if let controlSocketURL {
            appendSystem("Using authenticated SSH control socket.")
            return LaunchCommand(
                executablePath: "/usr/bin/ssh",
                arguments: host.buildSSHArguments(usingControlSocket: controlSocketURL.path),
                extraEnvironment: [:],
                usesExpectBridge: false,
                temporaryScriptURL: nil
            )
        }

        appendSystem("Using direct /usr/bin/ssh PTY mode.")
        return LaunchCommand(
            executablePath: "/usr/bin/ssh",
            arguments: baseSSHArguments,
            extraEnvironment: [:],
            usesExpectBridge: false,
            temporaryScriptURL: nil
        )
    }

    private func prepareControlMasterIfNeeded() -> Bool {
        guard host.prefersPasswordAuthentication,
              let storedPassword,
              !storedPassword.isEmpty else {
            return true
        }

        if let controlSocketURL,
           FileManager.default.fileExists(atPath: controlSocketURL.path) {
            return true
        }

        let socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anothershell-ssh-\(id.uuidString).sock")

        let result = AuthCommandRunner.run(
            binaryPath: "/usr/bin/ssh",
            arguments: host.buildControlMasterBootstrapArguments(socketPath: socketURL.path),
            password: storedPassword,
            timeout: 20
        )

        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.code == 0, FileManager.default.fileExists(atPath: socketURL.path) {
            controlSocketURL = socketURL
            appendSystem("Authenticated SSH control master established.")
            return true
        }

        if !output.isEmpty {
            appendOutput(output + "\n")
        }
        try? FileManager.default.removeItem(at: socketURL)
        controlSocketURL = nil
        return false
    }

    private func closeControlMasterIfNeeded() {
        guard let controlSocketURL else { return }

        _ = AuthCommandRunner.run(
            binaryPath: "/usr/bin/ssh",
            arguments: host.buildControlMasterExitArguments(socketPath: controlSocketURL.path),
            password: nil,
            timeout: 5
        )

        try? FileManager.default.removeItem(at: controlSocketURL)
        self.controlSocketURL = nil
    }

#if canImport(SSHClient)
    private func connectUsingEmbeddedSSHClient() {
        guard let storedPassword, !storedPassword.isEmpty else {
            setState(.failed, message: "Password required")
            appendSystem("Embedded SSH client requires a saved or entered password.")
            return
        }

        appendSystem("Using embedded SSH client.")
        setState(.connecting, message: "Connecting to \(host.address)...")

        let authentication = SSHAuthentication(
            username: host.username,
            method: .password(.init(storedPassword)),
            hostKeyValidation: host.strictHostKeyChecking ? .acceptAll() : .acceptAll()
        )

        let connection = SSHConnection(
            host: host.hostname,
            port: UInt16(clamping: host.port),
            authentication: authentication,
            queue: ioQueue,
            defaultTimeout: 15
        )
        embeddedConnection = connection

        connection.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.appendSystem("Primary embedded auth not accepted by server. Switching to compatibility auth.")
                self.connectUsingNMSSHBridge(reason: "Using libssh2 compatibility auth.")
            case .success:
                connection.requestShell { shellResult in
                    switch shellResult {
                    case .failure:
                        self.appendSystem("Embedded SSH shell request failed.")
                        self.setState(.failed, message: "Shell open failed")
                    case .success(let shell):
                        self.embeddedShell = shell
                        shell.readHandler = { [weak self] data in
                            guard let self else { return }
                            self.handleIncomingTerminalData(data)
                        }
                        shell.closeHandler = { [weak self] _ in
                            guard let self else { return }
                            if self.state == .connected || self.state == .connecting {
                                self.setState(.disconnected, message: "Disconnected")
                                self.appendSystem("Session closed")
                            }
                            self.embeddedShell = nil
                            self.embeddedConnection = nil
                        }
                        self.setState(.connected, message: "Connected")
                        self.appendSystem("Session connected to \(self.host.address)")
                        self.appendSystem("Tip: click terminal area and type directly.")
                        self.startSystemStatusPollingIfNeeded()
                        self.startThroughputSamplingIfNeeded()
                    }
                }
            }
        }
    }

    private func disconnectEmbeddedIfNeeded() -> Bool {
        guard embeddedConnection != nil || embeddedShell != nil else {
            return false
        }

        stopThroughputSampling()
        embeddedShell?.close { _ in }
        embeddedConnection?.cancel { }
        embeddedShell = nil
        embeddedConnection = nil
        setState(.disconnected, message: "Disconnected")
        appendSystem("Session closed")
        return true
    }
#endif

    private func connectUsingNMSSHBridge(reason: String) {
        guard let storedPassword, !storedPassword.isEmpty else {
            setState(.failed, message: "Password required")
            appendSystem("Embedded libssh2 client requires a saved or entered password.")
            return
        }

        appendSystem(reason)
        setState(.connecting, message: "Connecting to \(host.address)...")

        let bridge = ASNMSSHSessionBridge(
            host: host.hostname,
            port: host.port,
            username: host.username,
            password: storedPassword
        )
        nmsshBridge = bridge

        bridge.onData = { [weak self] data in
            guard let self else { return }
            self.handleIncomingTerminalData(data)
        }
        bridge.onErrorData = { [weak self] data in
            guard let self else { return }
            self.handleIncomingTerminalData(data)
        }
        bridge.onDisconnect = { [weak self] reason in
            guard let self else { return }
            let wasConnecting = self.state == .connecting
            self.nmsshBridge = nil

            if self.isDisconnectRequested {
                self.setState(.disconnected, message: "Disconnected")
                self.appendSystem("Session closed")
                return
            }

            if wasConnecting {
                self.setState(.failed, message: "Authentication failed")
                if let reason, !reason.isEmpty {
                    self.appendSystem(reason)
                }
                self.appendSystem("Embedded libssh2 authentication failed.")
            } else {
                self.setState(.disconnected, message: "Disconnected")
                if let reason, !reason.isEmpty {
                    self.appendSystem("Session closed: \(reason)")
                } else {
                    self.appendSystem("Session closed")
                }
            }
        }

        ioQueue.async { [weak self] in
            guard let self else { return }
            bridge.connect { success, usedKeyboardInteractive, failureReason in
                guard self.nmsshBridge === bridge else { return }
                if success {
                    self.setState(.connected, message: "Connected")
                    if usedKeyboardInteractive {
                        self.appendSystem("Using embedded libssh2 SSH client (keyboard-interactive).")
                    }
                    self.appendSystem("Session connected to \(self.host.address)")
                    self.appendSystem("Tip: click terminal area and type directly.")
                    self.startSystemStatusPollingIfNeeded()
                    self.startThroughputSamplingIfNeeded()
                } else {
                    self.nmsshBridge = nil
                    if let failureReason, !failureReason.isEmpty {
                        self.appendSystem(failureReason)
                    }
                    self.appendSystem("Embedded libssh2 authentication failed.")
                    self.setState(.failed, message: "Authentication failed")
                }
            }
        }
    }

    private func disconnectNMSSHIfNeeded() -> Bool {
        guard let nmsshBridge else {
            return false
        }

        stopSystemStatusPolling()
        stopThroughputSampling()
        nmsshBridge.disconnect()
        self.nmsshBridge = nil
        setState(.disconnected, message: "Disconnected")
        appendSystem("Session closed")
        return true
    }

    private func startSystemStatusPollingIfNeeded() {
        stopSystemStatusPolling()
        guard host.prefersPasswordAuthentication,
              let password = storedPassword,
              !password.isEmpty else {
            DispatchQueue.main.async {
                self.remoteSystemStatus = .empty
            }
            return
        }

        pollSystemStatus(password: password)

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pollSystemStatus(password: password)
        }
        systemStatusTimer = timer
        timer.resume()
    }

    private func stopSystemStatusPolling() {
        if let timer = systemStatusTimer {
            timer.cancel()
            systemStatusTimer = nil
        }
    }

    private func pollSystemStatus(password: String) {
        ASNMSSHSessionBridge.probeSystemStatus(
            withHost: host.hostname,
            port: host.port,
            username: host.username,
            password: password
        ) { [weak self] status, failureReason in
            guard let self else { return }
            if let status {
                let snapshot = RemoteSystemStatus(
                    os: status["os"] ?? "--",
                    model: status["model"] ?? "--",
                    memory: self.sanitizeMemoryDisplay(status["memory"] ?? "--"),
                    disk: status["disk"] ?? "--",
                    updatedAt: Date(),
                    error: nil
                )
                DispatchQueue.main.async {
                    self.remoteSystemStatus = snapshot
                    self.updateMemoryUsage(from: snapshot.memory)
                }
            } else if let failureReason, !failureReason.isEmpty {
                DispatchQueue.main.async {
                    self.remoteSystemStatus = RemoteSystemStatus(
                        os: "--",
                        model: "--",
                        memory: "--",
                        disk: "--",
                        updatedAt: Date(),
                        error: failureReason
                    )
                    self.memoryUsagePercent = nil
                }
            }
        }
    }

    private func startThroughputSamplingIfNeeded() {
        stopThroughputSampling()
        resetMetrics()
        throughputSampleInterval = 1.0
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + throughputSampleInterval, repeating: throughputSampleInterval)
        timer.setEventHandler { [weak self] in
            self?.sampleThroughput()
        }
        throughputTimer = timer
        timer.resume()
    }

    private func stopThroughputSampling() {
        if let timer = throughputTimer {
            timer.cancel()
            throughputTimer = nil
        }
        DispatchQueue.main.async {
            self.inboundBytesPerSecond = 0
            self.outboundBytesPerSecond = 0
        }
    }

    private func resetMetrics() {
        metricsQueue.sync {
            inboundBytesTotal = 0
            outboundBytesTotal = 0
            lastInboundSample = 0
            lastOutboundSample = 0
        }
    }

    private func accumulateInboundBytes(_ count: Int) {
        guard count > 0 else { return }
        metricsQueue.async {
            self.inboundBytesTotal += UInt64(count)
        }
    }

    private func accumulateOutboundBytes(_ count: Int) {
        guard count > 0 else { return }
        metricsQueue.async {
            self.outboundBytesTotal += UInt64(count)
        }
    }

    private func sampleThroughput() {
        let interval = max(throughputSampleInterval, 0.001)
        let sample = metricsQueue.sync { () -> (Double, Double) in
            let inboundDelta = inboundBytesTotal - lastInboundSample
            let outboundDelta = outboundBytesTotal - lastOutboundSample
            lastInboundSample = inboundBytesTotal
            lastOutboundSample = outboundBytesTotal
            return (Double(inboundDelta) / interval, Double(outboundDelta) / interval)
        }

        DispatchQueue.main.async {
            self.inboundBytesPerSecond = sample.0
            self.outboundBytesPerSecond = sample.1
            self.inboundSpeedHistory = self.appendSample(sample.0, to: self.inboundSpeedHistory)
            self.outboundSpeedHistory = self.appendSample(sample.1, to: self.outboundSpeedHistory)
        }
    }

    private func updateMemoryUsage(from text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            memoryUsagePercent = nil
            return
        }

        let ratioPattern = #"([0-9]+(?:\.[0-9]+)?)\s*/\s*([0-9]+(?:\.[0-9]+)?)"#
        if let ratioRegex = try? NSRegularExpression(pattern: ratioPattern),
           let match = ratioRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges >= 3,
           let usedRange = Range(match.range(at: 1), in: trimmed),
           let totalRange = Range(match.range(at: 2), in: trimmed),
           let used = Double(trimmed[usedRange]),
           let total = Double(trimmed[totalRange]),
           total > 0 {
            let percent = min(max((used / total) * 100, 0), 100)
            memoryUsagePercent = percent
            memoryUsageHistory = appendSample(percent, to: memoryUsageHistory)
            return
        }

        let percentPattern = #"([0-9]+(?:\.[0-9]+)?)\s*%"#
        if let percentRegex = try? NSRegularExpression(pattern: percentPattern),
           let match = percentRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges >= 2,
           let valueRange = Range(match.range(at: 1), in: trimmed),
           let value = Double(trimmed[valueRange]) {
            let percent = min(max(value, 0), 100)
            memoryUsagePercent = percent
            memoryUsageHistory = appendSample(percent, to: memoryUsageHistory)
            return
        }

        memoryUsagePercent = nil
    }

    private func appendSample(_ value: Double, to current: [Double]) -> [Double] {
        var updated = current
        updated.append(value)
        if updated.count > maxHistorySamples {
            updated.removeFirst(updated.count - maxHistorySamples)
        }
        return updated
    }

    private func sanitizeMemoryDisplay(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "--" }

        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*/\s*([0-9]+(?:\.[0-9]+)?)(?:\s*([A-Za-z]+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let usedRange = Range(match.range(at: 1), in: trimmed),
              let totalRange = Range(match.range(at: 2), in: trimmed),
              let usedValue = Double(trimmed[usedRange]),
              let totalValue = Double(trimmed[totalRange]),
              totalValue > 0 else {
            return trimmed
        }

        let unitRange = match.range(at: 3)
        let unit = unitRange.location != NSNotFound
            ? String(trimmed[Range(unitRange, in: trimmed)!]).uppercased()
            : "MB"

        var usedMB = usedValue
        var totalMB = totalValue

        if unit.contains("KB") || unit.contains("KIB") {
            usedMB = usedValue / 1024.0
            totalMB = totalValue / 1024.0
        } else if unit.contains("GB") || unit.contains("GIB") {
            usedMB = usedValue * 1024.0
            totalMB = totalValue * 1024.0
        } else if (unit.contains("MB") || unit.contains("MIB")) && totalValue >= 262_144 {
            // Some hosts report values in KB while suffixing "MB" (common on BusyBox variants).
            usedMB = usedValue / 1024.0
            totalMB = totalValue / 1024.0
        }

        if totalMB >= 1024 {
            return String(format: "%.1f/%.1f GB", usedMB / 1024.0, totalMB / 1024.0)
        }
        return String(format: "%.0f/%.0f MB", usedMB, totalMB)
    }

    private func startProcessExitWatcher(for pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.handleChildExit()
        }
        source.setCancelHandler { }
        processSource = source
        source.resume()
    }

    private func handleChildExit() {
        guard childPID > 0 else { return }

        var status: Int32 = 0
        let result = waitpid(childPID, &status, WNOHANG)
        guard result == childPID else { return }

        childPID = -1
        let exitCode = decodeExitCode(waitStatus: status)
        handleProcessTermination(exitCode: exitCode)
    }

    private func decodeExitCode(waitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }

        if signal == 0x7f {
            return 1
        }

        return 128 + signal
    }
}

@MainActor
final class SessionManager: ObservableObject {
    private final class DetachedSessionRef: @unchecked Sendable {
        let session: SSHSession
        init(_ session: SSHSession) {
            self.session = session
        }
    }

    @Published private(set) var sessions: [SSHSession] = []
    @Published var selectedSessionID: UUID?

    var selectedSession: SSHSession? {
        guard let selectedSessionID else {
            return sessions.last
        }

        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.last
    }

    func connect(to host: SSHHost, initialPassword: String? = nil) {
        sessions.removeAll { session in
            session.host.id == host.id &&
                (session.state == .failed || session.state == .disconnected || session.state == .idle)
        }

        if let existing = sessions.first(where: { $0.host.id == host.id && ($0.state == .connected || $0.state == .connecting) }) {
            selectedSessionID = existing.id
            return
        }

        let session = SSHSession(host: host, initialPassword: initialPassword)
        sessions.append(session)
        selectedSessionID = session.id
        session.connect()
    }

    func select(sessionID: UUID) {
        selectedSessionID = sessionID
    }

    func close(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let session = sessions[index]
        sessions.remove(at: index)

        if selectedSessionID == sessionID {
            selectedSessionID = sessions.last?.id
        }
        disconnectAsync(session)
    }

    func closeAll() {
        let currentSessions = sessions
        sessions = []
        selectedSessionID = nil
        for session in currentSessions {
            disconnectAsync(session)
        }
    }

    private func disconnectAsync(_ session: SSHSession) {
        let ref = DetachedSessionRef(session)
        DispatchQueue.global(qos: .utility).async {
            ref.session.disconnect()
        }
    }
}
