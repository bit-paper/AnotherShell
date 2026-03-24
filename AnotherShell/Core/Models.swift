import Foundation

enum SSHAuthMethod: String, Codable, CaseIterable, Identifiable {
    case sshAgent
    case privateKey
    case passwordPrompt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sshAgent:
            return "SSH Agent"
        case .privateKey:
            return "Private Key"
        case .passwordPrompt:
            return "Password (interactive)"
        }
    }
}

enum PortForwardDirection: String, Codable, CaseIterable, Identifiable {
    case local
    case remote
    case dynamic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            return "Local (-L)"
        case .remote:
            return "Remote (-R)"
        case .dynamic:
            return "Dynamic SOCKS (-D)"
        }
    }
}

struct PortForwardRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var direction: PortForwardDirection = .local
    var localPort: Int = 8080
    var remoteHost: String = "127.0.0.1"
    var remotePort: Int = 80
    var enabled: Bool = false

    func sshArgument() -> String? {
        guard enabled else { return nil }

        switch direction {
        case .local:
            return "\(localPort):\(remoteHost):\(remotePort)"
        case .remote:
            return "\(remotePort):\(remoteHost):\(localPort)"
        case .dynamic:
            return "\(localPort)"
        }
    }
}

struct SSHHost: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "New Host"
    var hostname: String = ""
    var port: Int = 22
    var username: String = NSUserName()
    var authMethod: SSHAuthMethod = .sshAgent
    var privateKeyPath: String = ""
    var startupCommand: String = ""
    var note: String = ""
    var tags: [String] = []
    var isFavorite: Bool = false
    var strictHostKeyChecking: Bool = false
    var useCompression: Bool = true
    var keepAliveSeconds: Int = 30
    var forwards: [PortForwardRule] = []

    var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var address: String {
        "\(username)@\(hostname)"
    }

    var prefersPasswordAuthentication: Bool {
        authMethod == .passwordPrompt
    }

    func buildSSHArguments() -> [String] {
        var arguments: [String] = []
        if port != 22 {
            arguments += ["-p", String(port)]
        }
        arguments += ["-o", "UserKnownHostsFile=\(SSHKnownHostsStore.userKnownHostsFilePath())"]
        arguments.append(address)
        return arguments
    }

    func buildControlMasterBootstrapArguments(socketPath: String) -> [String] {
        var arguments: [String] = []
        if port != 22 {
            arguments += ["-p", String(port)]
        }
        arguments += ["-o", "UserKnownHostsFile=\(SSHKnownHostsStore.userKnownHostsFilePath())"]
        arguments += ["-o", "ControlMaster=yes"]
        arguments += ["-o", "ControlPath=\(socketPath)"]
        arguments += ["-o", "ControlPersist=600"]
        arguments += ["-f", "-N"]
        arguments.append(address)
        return arguments
    }

    func buildSSHArguments(usingControlSocket socketPath: String) -> [String] {
        var arguments: [String] = []
        if port != 22 {
            arguments += ["-p", String(port)]
        }
        arguments += ["-o", "UserKnownHostsFile=\(SSHKnownHostsStore.userKnownHostsFilePath())"]
        arguments += ["-o", "ControlMaster=no"]
        arguments += ["-o", "ControlPath=\(socketPath)"]
        arguments.append(address)
        return arguments
    }

    func buildControlMasterExitArguments(socketPath: String) -> [String] {
        var arguments: [String] = []
        if port != 22 {
            arguments += ["-p", String(port)]
        }
        arguments += ["-o", "UserKnownHostsFile=\(SSHKnownHostsStore.userKnownHostsFilePath())"]
        arguments += ["-o", "ControlPath=\(socketPath)"]
        arguments += ["-O", "exit"]
        arguments.append(address)
        return arguments
    }

    func buildSCPUploadArguments(localURL: URL, remotePath: String, recursive: Bool = false) -> [String] {
        var arguments: [String] = ["-P", String(port)]

        if recursive {
            arguments.append("-r")
        }

        arguments += hostKeyOptionArguments()

        if authMethod == .privateKey {
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyPath.isEmpty {
                arguments += ["-i", keyPath]
            }
        }

        arguments.append(localURL.path)
        arguments.append("\(address):\(quotedRemotePathForSCP(remotePath))")

        return arguments
    }

    func buildSCPDownloadArguments(remotePath: String, localDirectory: URL, recursive: Bool = false) -> [String] {
        var arguments: [String] = ["-P", String(port)]

        if recursive {
            arguments.append("-r")
        }

        arguments += hostKeyOptionArguments()

        if authMethod == .privateKey {
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyPath.isEmpty {
                arguments += ["-i", keyPath]
            }
        }

        arguments.append("\(address):\(quotedRemotePathForSCP(remotePath))")
        arguments.append(localDirectory.path)

        return arguments
    }

    func buildSFTPArguments() -> [String] {
        var arguments: [String] = ["-P", String(port)]

        arguments += hostKeyOptionArguments()

        if authMethod == .privateKey {
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyPath.isEmpty {
                arguments += ["-i", keyPath]
            }
        }

        arguments.append(address)

        return arguments
    }

    func buildSSHCommandArguments(command: String) -> [String] {
        var arguments: [String] = ["-p", String(port)]

        arguments += hostKeyOptionArguments()
        arguments += ["-o", "ServerAliveInterval=\(keepAliveSeconds)"]
        arguments += ["-o", "ServerAliveCountMax=2"]

        if authMethod == .privateKey {
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyPath.isEmpty {
                arguments += ["-i", keyPath]
            }
        }

        arguments.append(address)
        arguments.append(command)
        return arguments
    }

    private func quotedRemotePathForSCP(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func hostKeyOptionArguments() -> [String] {
        let knownHosts = SSHKnownHostsStore.userKnownHostsFilePath()
        return [
            "-o", "UserKnownHostsFile=\(knownHosts)",
            "-o", strictHostKeyChecking ? "StrictHostKeyChecking=yes" : "StrictHostKeyChecking=accept-new"
        ]
    }
}

struct QuickCommand: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var command: String

    static let `default`: [QuickCommand] = [
        QuickCommand(title: "List files", command: "ls -al"),
        QuickCommand(title: "Disk usage", command: "df -h"),
        QuickCommand(title: "System load", command: "top -l 1 | head -20"),
        QuickCommand(title: "Docker ps", command: "docker ps"),
        QuickCommand(title: "Git status", command: "git status")
    ]
}
