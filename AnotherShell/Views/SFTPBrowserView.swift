import SwiftUI
import UniformTypeIdentifiers

struct SFTPBrowserView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @ObservedObject var model: SFTPBrowserModel
    var embeddedInSession: Bool = false

    @State private var selectedRemoteIDs: Set<String> = []
    @State private var selectedLocalIDs: Set<URL> = []
    @State private var isRemoteDropTargeted = false
    @State private var isLocalDropTargeted = false
    @State private var localPathInput = ""
    @State private var remotePathInput = ""

    private let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.wifi")
                Text(appSettings.t("sftp.title"))
                    .font(.headline)
                Spacer()
                if model.isTransferring || model.isLoadingRemote {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(appSettings.palette.panelBackground)

            if model.isTransferring || model.canRetryTransfer {
                HStack(spacing: 8) {
                    ProgressView(value: model.transferProgress)
                        .progressViewStyle(.linear)
                    Text("\(Int((model.transferProgress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                    if model.isTransferring && model.canCancelTransfer {
                        Button(appSettings.t("button.cancel")) {
                            model.cancelTransfer()
                        }
                        .buttonStyle(.bordered)
                    }
                    if model.canRetryTransfer {
                        Button(appSettings.t("sftp.retry")) {
                            model.retryLastTransfer()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .background(appSettings.palette.panelBackground)
            }

            if model.canRequestPermission {
                HStack {
                    Text(appSettings.t("sftp.permission_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(appSettings.t("sftp.request_permission")) {
                        model.requestPermissionAndRetry()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .background(appSettings.palette.panelBackground)
            }

            Divider()

            HSplitView {
                localPane
                remotePane
            }

            Divider()

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appSettings.palette.panelBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appSettings.palette.panelBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(appSettings.palette.border)
                .frame(height: embeddedInSession ? 0 : 1)
        }
        .onAppear {
            localPathInput = model.currentLocalURL.path
            remotePathInput = model.currentRemotePath
            model.refreshAll()
        }
        .onChange(of: model.currentLocalURL) { _, newValue in
            localPathInput = newValue.path
        }
        .onChange(of: model.currentRemotePath) { _, newValue in
            remotePathInput = newValue
        }
    }

    private var localPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appSettings.t("sftp.local"))
                        .font(.subheadline)
                        .bold()
                    Spacer()
                }

                HStack(spacing: 6) {
                    Button {
                        model.goLocalUp()
                    } label: {
                        Image(systemName: "arrow.up.circle")
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.refreshLocal()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)

                    TextField(appSettings.t("sftp.local_path"), text: $localPathInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            model.navigateLocal(to: localPathInput)
                        }

                    Button(appSettings.t("sftp.go")) {
                        model.navigateLocal(to: localPathInput)
                    }
                    .buttonStyle(.bordered)
                }

                Text(model.currentLocalURL.path)
                    .font(.caption)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(appSettings.palette.panelBackground)

            List(model.localEntries, selection: $selectedLocalIDs) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDirectory ? .blue : .secondary)

                    Text(entry.name)
                        .lineLimit(1)

                    Spacer()

                    if !entry.isDirectory {
                        Text(sizeFormatter.string(fromByteCount: entry.size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let modified = entry.modified {
                        Text(dateFormatter.string(from: modified))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(entry.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.isDirectory {
                        model.openLocal(entry)
                        selectedLocalIDs.removeAll()
                    }
                }
                .onDrag {
                    NSItemProvider(object: entry.url as NSURL)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appSettings.palette.appBackground)
            .onDrop(of: [UTType.plainText], isTargeted: $isLocalDropTargeted, perform: handleRemoteDropToLocal)
            .overlay {
                if isLocalDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.green, style: StrokeStyle(lineWidth: 2, dash: [4]))
                        .padding(6)
                }
            }
        }
        .background(appSettings.palette.appBackground)
    }

    private var remotePane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appSettings.t("sftp.remote"))
                        .font(.subheadline)
                        .bold()
                    Spacer()
                }

                HStack(spacing: 6) {
                    Button {
                        model.goRemoteUp()
                    } label: {
                        Image(systemName: "arrow.up.circle")
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.refreshRemote()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)

                    TextField(appSettings.t("sftp.remote_path"), text: $remotePathInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            model.navigateRemote(to: remotePathInput)
                        }

                    Button(appSettings.t("sftp.go")) {
                        model.navigateRemote(to: remotePathInput)
                    }
                    .buttonStyle(.bordered)
                }

                Text(model.currentRemotePath)
                    .font(.caption)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(appSettings.palette.panelBackground)

            List(model.remoteEntries, selection: $selectedRemoteIDs) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.isDirectory ? "folder.badge.gearshape" : "doc.text")
                        .foregroundStyle(entry.isDirectory ? .mint : .secondary)

                    Text(entry.name)
                        .lineLimit(1)

                    Spacer()

                    if !entry.isDirectory {
                        Text(sizeFormatter.string(fromByteCount: entry.size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(entry.modified)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .tag(entry.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    if entry.isDirectory {
                        model.openRemote(entry)
                        selectedRemoteIDs.removeAll()
                    } else {
                        let destination = chooseDownloadDirectory() ?? model.currentLocalURL
                        model.download(remotePaths: [entry.path], toLocalDirectory: destination)
                    }
                }
                .onDrag {
                    NSItemProvider(object: "anothershell-remote:\(entry.path)" as NSString)
                }
                .contextMenu {
                    if entry.name != ".." {
                        Button(appSettings.t("sftp.download_to")) {
                            let destination = chooseDownloadDirectory() ?? model.currentLocalURL
                            model.download(remotePaths: [entry.path], toLocalDirectory: destination)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(appSettings.palette.appBackground)
            .onDrop(of: [UTType.fileURL], isTargeted: $isRemoteDropTargeted, perform: handleLocalDropToRemote)
            .overlay {
                if isRemoteDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.green, style: StrokeStyle(lineWidth: 2, dash: [4]))
                        .padding(6)
                }
            }
        }
        .background(appSettings.palette.appBackground)
    }

    private func handleLocalDropToRemote(_ providers: [NSItemProvider]) -> Bool {
        let matched = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matched.isEmpty else { return false }

        for provider in matched {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    guard let url = object else { return }
                    DispatchQueue.main.async {
                        model.upload(localURLs: [url])
                    }
                }
                continue
            }

            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let item else { return }

                var url: URL?
                if let data = item as? Data {
                    url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let string = item as? String {
                    url = URL(string: string)
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    model.upload(localURLs: [url])
                }
            }
        }

        return true
    }

    private func handleRemoteDropToLocal(_ providers: [NSItemProvider]) -> Bool {
        let matched = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        guard !matched.isEmpty else { return false }

        for provider in matched {
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String else { return }
                    consumeRemoteDragPayload(text)
                }
                continue
            }

            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    consumeRemoteDragPayload(text)
                } else if let text = item as? String {
                    consumeRemoteDragPayload(text)
                }
            }
        }

        return true
    }

    private func consumeRemoteDragPayload(_ payload: String) {
        guard payload.hasPrefix("anothershell-remote:") else { return }
        let path = String(payload.dropFirst("anothershell-remote:".count))

        DispatchQueue.main.async {
            model.download(remotePaths: [path])
        }
    }

    private func chooseDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = appSettings.t("sftp.select_download_folder")
        panel.prompt = appSettings.t("sftp.download_here")
        panel.directoryURL = model.currentLocalURL
        return panel.runModal() == .OK ? panel.url : nil
    }
}
