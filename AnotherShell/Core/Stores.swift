import Foundation
import Combine

private enum StoreFile {
    static func baseDirectory() -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("AnotherShell", isDirectory: true)

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir
    }

    static var hostsURL: URL {
        baseDirectory().appendingPathComponent("hosts.json")
    }

    static var quickCommandsURL: URL {
        baseDirectory().appendingPathComponent("quick_commands.json")
    }
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []

    init() {
        load()
    }

    func host(id: UUID?) -> SSHHost? {
        guard let id else { return nil }
        return hosts.first { $0.id == id }
    }

    func upsert(_ host: SSHHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }

        sortHosts()
        save()
    }

    func remove(ids: [UUID]) {
        let removedHosts = hosts.filter { ids.contains($0.id) }
        hosts.removeAll { ids.contains($0.id) }
        removedHosts.forEach { KeychainPasswordStore.delete(for: $0) }
        save()
    }

    func remove(at offsets: IndexSet) {
        let targets = offsets.compactMap { index in
            hosts.indices.contains(index) ? hosts[index] : nil
        }

        for index in offsets.sorted(by: >) {
            guard hosts.indices.contains(index) else { continue }
            hosts.remove(at: index)
        }

        targets.forEach { KeychainPasswordStore.delete(for: $0) }
        save()
    }

    func toggleFavorite(for id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].isFavorite.toggle()
        sortHosts()
        save()
    }

    private func sortHosts() {
        hosts.sort {
            if $0.isFavorite != $1.isFavorite {
                return $0.isFavorite && !$1.isFavorite
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func load() {
        let url = StoreFile.hostsURL
        guard let data = try? Data(contentsOf: url) else {
            hosts = []
            return
        }

        do {
            hosts = try JSONDecoder().decode([SSHHost].self, from: data)
            sortHosts()
        } catch {
            hosts = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(hosts)
            try data.write(to: StoreFile.hostsURL, options: .atomic)
        } catch {
            // Keep app resilient; persistence errors should not crash runtime sessions.
        }
    }
}

@MainActor
final class QuickCommandStore: ObservableObject {
    @Published private(set) var commands: [QuickCommand] = []

    init() {
        load()
    }

    func add(_ command: QuickCommand) {
        commands.append(command)
        save()
    }

    func remove(ids: [UUID]) {
        commands.removeAll { ids.contains($0.id) }
        save()
    }

    private func load() {
        let url = StoreFile.quickCommandsURL

        guard let data = try? Data(contentsOf: url) else {
            commands = QuickCommand.default
            save()
            return
        }

        do {
            commands = try JSONDecoder().decode([QuickCommand].self, from: data)
            if commands.isEmpty {
                commands = QuickCommand.default
                save()
            }
        } catch {
            commands = QuickCommand.default
            save()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(commands)
            try data.write(to: StoreFile.quickCommandsURL, options: .atomic)
        } catch {
            // Best effort persistence.
        }
    }
}
