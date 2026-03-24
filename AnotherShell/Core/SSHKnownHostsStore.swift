import Foundation

enum SSHKnownHostsStore {
    static func sshHomeDirectoryPath() -> String {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let sshHome = root.appendingPathComponent("AnotherShell/SSHHome", isDirectory: true)
        let sshDir = sshHome.appendingPathComponent(".ssh", isDirectory: true)

        if !fm.fileExists(atPath: sshDir.path) {
            try? fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
        }

        let knownHosts = sshDir.appendingPathComponent("known_hosts")
        if !fm.fileExists(atPath: knownHosts.path) {
            fm.createFile(atPath: knownHosts.path, contents: nil)
        }

        return sshHome.path
    }

    static func userKnownHostsFilePath() -> String {
        if let grantedPath = SSHUserDirectoryAccess.knownHostsFilePath() {
            return grantedPath
        }

        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = root.appendingPathComponent("AnotherShell/SSH", isDirectory: true)

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let fileURL = dir.appendingPathComponent("known_hosts")
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }

        return fileURL.path
    }
}
