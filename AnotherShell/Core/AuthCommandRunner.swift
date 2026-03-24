import Foundation
import Darwin

enum AuthCommandRunner {
    struct Result {
        let code: Int32
        let output: String
    }

    static func run(
        binaryPath: String,
        arguments: [String],
        password: String?,
        timeout: TimeInterval = 120
    ) -> Result {
        if let password, !password.isEmpty,
           let bridge = ExpectCommandBridge.makeLaunchSpec(
                command: binaryPath,
                arguments: arguments,
                password: password,
                mode: .batch(timeout: timeout)
           ) {
            defer {
                ExpectCommandBridge.removeScript(at: bridge.scriptURL)
            }
            return runProcess(
                binaryPath: bridge.executablePath,
                arguments: bridge.arguments,
                environment: bridge.environment,
                timeout: timeout + 5
            )
        }

        var master: Int32 = 0
        var slave: Int32 = 0

        if openpty(&master, &slave, nil, nil, nil) != 0 {
            return runFallback(binaryPath: binaryPath, arguments: arguments)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["TERM"] = "xterm-256color"
        process.environment = environment

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do {
            try process.run()
        } catch {
            Darwin.close(master)
            return Result(code: 1, output: error.localizedDescription)
        }

        var collected = Data()
        var detectorTail = ""
        var autoSentCount = 0
        var lastAutoSentAt = Date.distantPast
        let start = Date()

        setNonblocking(master)

        while process.isRunning {
            let chunk = readAvailable(from: master)
            if !chunk.isEmpty {
                collected.append(contentsOf: chunk)

                if let text = String(bytes: chunk, encoding: .utf8) {
                    detectorTail += text.lowercased()
                    if detectorTail.count > 512 {
                        detectorTail = String(detectorTail.suffix(512))
                    }
                }

                if shouldAutoRespondToPasswordPrompt(detectorTail: detectorTail),
                   let password,
                   !password.isEmpty,
                   autoSentCount < 8,
                   Date().timeIntervalSince(lastAutoSentAt) > 0.75 {
                    _ = writeString(password + "\n", to: master)
                    lastAutoSentAt = Date()
                    autoSentCount += 1
                }
            }

            if Date().timeIntervalSince(start) > timeout {
                process.terminate()
                break
            }

            usleep(20_000)
        }

        let tail = readUntilExhausted(from: master)
        if !tail.isEmpty {
            collected.append(contentsOf: tail)
        }

        Darwin.close(master)

        let text = String(data: collected, encoding: .utf8) ?? String(decoding: collected, as: UTF8.self)
        return Result(code: process.terminationStatus, output: text)
    }

    private static func runFallback(binaryPath: String, arguments: [String]) -> Result {
        runProcess(binaryPath: binaryPath, arguments: arguments, environment: [:], timeout: nil)
    }

    private static func runProcess(
        binaryPath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments

        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return Result(code: 1, output: error.localizedDescription)
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning {
                process.terminate()
            }
        } else {
            process.waitUntilExit()
        }

        if process.isRunning {
            process.waitUntilExit()
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return Result(code: process.terminationStatus, output: output)
    }

    private static func shouldAutoRespondToPasswordPrompt(detectorTail: String) -> Bool {
        detectorTail.contains("password:") || detectorTail.contains("passphrase for key")
    }

    private static func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private static func readAvailable(from fd: Int32) -> [UInt8] {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                continue
            }

            if count == 0 {
                break
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }

            break
        }

        return data
    }

    private static func readUntilExhausted(from fd: Int32) -> [UInt8] {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                continue
            }

            break
        }

        return data
    }

    @discardableResult
    private static func writeString(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        var sent = 0

        while sent < bytes.count {
            let result = bytes.withUnsafeBytes { ptr in
                let pointer = ptr.baseAddress!.advanced(by: sent)
                return Darwin.write(fd, pointer, bytes.count - sent)
            }

            if result <= 0 {
                return false
            }

            sent += result
        }

        return true
    }
}
