import Foundation
import AppKit

enum SSHUserDirectoryAccess {
    private static let bookmarkKey = "com.anothershell.ssh.userDirectoryBookmark"
    private static var scopedURL: URL?

    static func restoreAccess() -> URL? {
        if let scopedURL {
            return scopedURL
        }

        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }

        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }

        scopedURL = url
        refreshBookmarkIfNeeded(for: url, stale: isStale)
        ensureKnownHostsFileExists(in: url)
        return url
    }

    @MainActor
    static func requestAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Grant Access"
        panel.message = "Select your ~/.ssh folder so AnotherShell can read and update known_hosts."

        guard panel.runModal() == .OK, let url = panel.url else {
            return restoreAccess()
        }

        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return restoreAccess()
        }

        revokeAccess()
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)

        guard url.startAccessingSecurityScopedResource() else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }

        scopedURL = url
        ensureKnownHostsFileExists(in: url)
        return url
    }

    static func revokeAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    static func grantedDirectoryPath() -> String? {
        restoreAccess()?.path
    }

    static func knownHostsFilePath() -> String? {
        guard let directory = restoreAccess() else {
            return nil
        }
        let knownHostsURL = directory.appendingPathComponent("known_hosts", isDirectory: false)
        ensureKnownHostsFileExists(in: directory)
        return knownHostsURL.path
    }

    private static func refreshBookmarkIfNeeded(for url: URL, stale: Bool) {
        guard stale,
              let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
    }

    private static func ensureKnownHostsFileExists(in directory: URL) {
        let knownHostsURL = directory.appendingPathComponent("known_hosts", isDirectory: false)
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            FileManager.default.createFile(atPath: knownHostsURL.path, contents: nil)
        }
    }
}
