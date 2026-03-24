import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager

    @State private var selectedHostID: UUID?
    @State private var showingHostEditor = false
    @State private var hostDraft = SSHHost()
    @State private var pendingPasswordHost: SSHHost?
    @State private var pendingPasswordInput = ""
    @State private var pendingRememberPassword = true

    private var selectedHost: SSHHost? {
        hostStore.host(id: selectedHostID)
    }

    var body: some View {
        ZStack {
            if appSettings.isLiquidGlassTheme {
                LiquidGlassBackgroundLayer()
            }

            NavigationSplitView {
                sidebar
                    .background(sidebarBackgroundStyle)
            } detail: {
                detail
                    .background(detailBackgroundStyle)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingHostEditor) {
            HostEditorView(host: hostDraft) { editedHost in
                hostStore.upsert(editedHost)
                selectedHostID = editedHost.id
            }
            .id(hostDraft.id)
            .environmentObject(appSettings)
            .withoutWritingTools()
        }
        .sheet(item: $pendingPasswordHost) { host in
            PasswordConnectSheet(
                host: host,
                password: $pendingPasswordInput,
                rememberPassword: $pendingRememberPassword,
                onCancel: {
                    pendingPasswordHost = nil
                },
                onConnect: {
                    let runtimePassword = pendingPasswordInput
                    if pendingRememberPassword && !pendingPasswordInput.isEmpty {
                        KeychainPasswordStore.save(pendingPasswordInput, for: host)
                    }
                    sessionManager.connect(to: host, initialPassword: runtimePassword)
                    pendingPasswordHost = nil
                }
            )
            .environmentObject(appSettings)
            .withoutWritingTools()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    createHost()
                } label: {
                    Label(appSettings.t("toolbar.new_host"), systemImage: "plus")
                }

                Button {
                    editSelectedHost()
                } label: {
                    Label(appSettings.t("toolbar.edit_host"), systemImage: "square.and.pencil")
                }
                .disabled(selectedHost == nil)

                Button {
                    connectSelectedHost()
                } label: {
                    Label(appSettings.t("toolbar.connect"), systemImage: "bolt.horizontal.circle")
                }
                .disabled(selectedHost == nil)

                Button {
                    sessionManager.closeAll()
                } label: {
                    Label(appSettings.t("toolbar.close_all"), systemImage: "xmark.circle")
                }
                .disabled(sessionManager.sessions.isEmpty)

                SettingsLink {
                    Label(appSettings.t("toolbar.settings"), systemImage: "gearshape")
                }
            }
        }
        .withoutWritingTools()
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AnotherShellLogoImage(size: 24, cornerRatio: 0.24)
                Text(appSettings.t("app.name"))
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            sidebarStatusContainer
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(minHeight: 220, idealHeight: 240, maxHeight: 280, alignment: .top)

            Divider()

            List {
                Section(appSettings.t("section.active_sessions")) {
                    if sessionManager.sessions.isEmpty {
                        Text(appSettings.t("empty.no_sessions"))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(sessionManager.sessions) { session in
                        HStack(spacing: 8) {
                            Button {
                                sessionManager.select(sessionID: session.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(indicatorColor(for: session.state))
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayName(for: session.host))
                                        Text(appSettings.sessionStateName(session.state))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                sessionManager.close(sessionID: session.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section(appSettings.t("section.hosts")) {
                    if hostStore.hosts.isEmpty {
                        Text(appSettings.t("empty.no_hosts"))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(hostStore.hosts) { host in
                        HStack(spacing: 8) {
                            Button {
                                selectedHostID = host.id
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: host.isFavorite ? "star.fill" : "server.rack")
                                        .foregroundStyle(host.isFavorite ? .yellow : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayName(for: host))
                                        Text(host.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                connectWithPasswordIfNeeded(host)
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button(appSettings.t("menu.connect")) {
                                connectWithPasswordIfNeeded(host)
                            }
                            Button(host.isFavorite ? appSettings.t("menu.unfavorite") : appSettings.t("menu.favorite")) {
                                hostStore.toggleFavorite(for: host.id)
                            }
                            Button(appSettings.t("menu.edit")) {
                                hostDraft = host
                                showingHostEditor = true
                            }
                            Button(appSettings.t("menu.delete"), role: .destructive) {
                                hostStore.remove(ids: [host.id])
                                if selectedHostID == host.id {
                                    selectedHostID = nil
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        hostStore.remove(at: offsets)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(sidebarBackgroundStyle)
        }
        .background(sidebarBackgroundStyle)
    }

    private var sidebarStatusContainer: some View {
        Group {
            if let session = sessionManager.selectedSession {
                SessionStatusCardView(session: session)
                    .environmentObject(appSettings)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appSettings.t("section.session_status"))
                        .font(.caption.weight(.semibold))
                    Text(appSettings.t("empty.no_sessions"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(statusCardBackgroundStyle)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(appSettings.palette.border, lineWidth: 1)
                )
            }
        }
    }

    private var detail: some View {
        Group {
            if !sessionManager.sessions.isEmpty {
                let activeID = sessionManager.selectedSessionID ?? sessionManager.sessions.last?.id
                ZStack {
                    ForEach(sessionManager.sessions) { session in
                        let isActive = activeID == session.id
                        TerminalSessionView(session: session)
                            .environmentObject(appSettings)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .zIndex(isActive ? 1 : 0)
                    }
                }
            } else {
                ContentUnavailableView(
                    appSettings.t("app.name"),
                    systemImage: "terminal",
                    description: Text(appSettings.t("welcome.description"))
                )
            }
        }
    }

    private func hostOverview(_ host: SSHHost) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(displayName(for: host))
                .font(.largeTitle)
                .bold()

            Text(host.address)
                .foregroundStyle(.secondary)

            Text(appSettings.tf("host.port_format", host.port))
                .foregroundStyle(.secondary)

            if !host.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(host.note)
                    .padding(.top, 4)
            }

            if !host.tags.isEmpty {
                HStack(spacing: 8) {
                    ForEach(host.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(appSettings.palette.panelBackground))
                    }
                }
            }

            HStack(spacing: 10) {
                Button(appSettings.t("button.connect")) {
                    connectWithPasswordIfNeeded(host)
                }
                .buttonStyle(.borderedProminent)

                Button(appSettings.t("button.edit")) {
                    hostDraft = host
                    showingHostEditor = true
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appSettings.palette.appBackground)
    }

    private func indicatorColor(for state: SSHSessionState) -> Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .failed:
            return .red
        case .idle, .disconnected:
            return .gray
        }
    }

    private func createHost() {
        hostDraft = SSHHost()
        showingHostEditor = true
    }

    private func editSelectedHost() {
        guard let selectedHost else { return }
        hostDraft = selectedHost
        showingHostEditor = true
    }

    private func connectSelectedHost() {
        guard let selectedHost else { return }
        connectWithPasswordIfNeeded(selectedHost)
    }

    private func connectWithPasswordIfNeeded(_ host: SSHHost) {
        if host.prefersPasswordAuthentication, KeychainPasswordStore.load(for: host) == nil {
            pendingPasswordHost = host
            pendingPasswordInput = ""
            pendingRememberPassword = true
            return
        }

        sessionManager.connect(to: host)
    }

    private func displayName(for host: SSHHost) -> String {
        let trimmed = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 1 ? host.address : trimmed
    }

    private var sidebarBackgroundStyle: AnyShapeStyle {
        appSettings.isLiquidGlassTheme
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(appSettings.palette.panelBackground)
    }

    private var detailBackgroundStyle: AnyShapeStyle {
        appSettings.isLiquidGlassTheme
            ? AnyShapeStyle(.regularMaterial)
            : AnyShapeStyle(appSettings.palette.appBackground)
    }

    private var statusCardBackgroundStyle: AnyShapeStyle {
        appSettings.isLiquidGlassTheme
            ? AnyShapeStyle(.thinMaterial)
            : AnyShapeStyle(appSettings.palette.appBackground.opacity(0.6))
    }
}

private struct SidebarSparkline: View {
    let samples: [Double]
    let stroke: Color
    let fill: [Color]

    var body: some View {
        GeometryReader { proxy in
            let path = SidebarSparklineShape(samples: samples).path(in: CGRect(origin: .zero, size: proxy.size))
            let fillPath = SidebarSparklineAreaShape(samples: samples).path(in: CGRect(origin: .zero, size: proxy.size))

            ZStack {
                fillPath
                    .fill(
                        LinearGradient(
                            colors: fill,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                path
                    .stroke(stroke, lineWidth: 1.6)
                    .shadow(color: stroke.opacity(0.5), radius: 2, x: 0, y: 0)
            }
        }
        .background(.clear)
    }
}

private struct SessionStatusCardView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @ObservedObject var session: SSHSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.host.address)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            statusRow(appSettings.t("terminal.metric.os"), session.remoteSystemStatus.os)
            statusRow(appSettings.t("terminal.metric.model"), session.remoteSystemStatus.model)
            statusRow(appSettings.t("terminal.metric.mem"), session.remoteSystemStatus.memory)
            statusRow(appSettings.t("terminal.metric.disk"), session.remoteSystemStatus.disk)

            HStack(spacing: 6) {
                Text("\(appSettings.t("terminal.metric.down")) \(speedString(session.inboundBytesPerSecond))")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                Text("\(appSettings.t("terminal.metric.up")) \(speedString(session.outboundBytesPerSecond))")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }

            metricChart(
                title: appSettings.t("terminal.metric.memory"),
                valueText: session.memoryUsagePercent.map { String(format: "%.0f%%", $0) } ?? appSettings.t("terminal.metric.na"),
                samples: session.memoryUsageHistory,
                stroke: .cyan,
                fill: [.cyan.opacity(0.45), .clear]
            )

            metricChart(
                title: appSettings.t("terminal.metric.down"),
                valueText: speedString(session.inboundBytesPerSecond),
                samples: session.inboundSpeedHistory,
                stroke: .green,
                fill: [.green.opacity(0.4), .clear]
            )

            metricChart(
                title: appSettings.t("terminal.metric.up"),
                valueText: speedString(session.outboundBytesPerSecond),
                samples: session.outboundSpeedHistory,
                stroke: .orange,
                fill: [.orange.opacity(0.4), .clear]
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appSettings.isLiquidGlassTheme ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(appSettings.palette.appBackground.opacity(0.8)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(appSettings.palette.border, lineWidth: 1)
        )
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func metricChart(
        title: String,
        valueText: String,
        samples: [Double],
        stroke: Color,
        fill: [Color]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }

            SidebarSparkline(samples: samples, stroke: stroke, fill: fill)
                .frame(height: 22)
                .animation(.easeInOut(duration: 0.22), value: samples)
        }
    }

    private func speedString(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return "\(formatter.string(fromByteCount: Int64(max(bytesPerSecond, 0))))/s"
    }
}

private struct SidebarSparklineShape: Shape {
    let samples: [Double]

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }
        let minValue = samples.min() ?? 0
        let maxValue = samples.max() ?? 1
        let range = max(maxValue - minValue, 1)
        let stepX = rect.width / CGFloat(max(samples.count - 1, 1))

        var path = Path()
        for (index, sample) in samples.enumerated() {
            let normalized = (sample - minValue) / range
            let x = CGFloat(index) * stepX
            let y = rect.height - (CGFloat(normalized) * rect.height)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

private struct SidebarSparklineAreaShape: Shape {
    let samples: [Double]

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }
        let minValue = samples.min() ?? 0
        let maxValue = samples.max() ?? 1
        let range = max(maxValue - minValue, 1)
        let stepX = rect.width / CGFloat(max(samples.count - 1, 1))

        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height))
        for (index, sample) in samples.enumerated() {
            let normalized = (sample - minValue) / range
            let x = CGFloat(index) * stepX
            let y = rect.height - (CGFloat(normalized) * rect.height)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct PasswordConnectSheet: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let host: SSHHost
    @Binding var password: String
    @Binding var rememberPassword: Bool

    let onCancel: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appSettings.t("password.prompt.title"))
                .font(.title3)
                .bold()

            Text(appSettings.tf("password.prompt.message", host.address))
                .foregroundStyle(.secondary)

            SecureField(appSettings.t("password.prompt.placeholder"), text: $password)
                .textFieldStyle(.roundedBorder)

            Toggle(appSettings.t("password.prompt.remember"), isOn: $rememberPassword)
                .toggleStyle(.switch)

            HStack {
                Spacer()
                Button(appSettings.t("button.cancel")) {
                    onCancel()
                }
                Button(appSettings.t("password.prompt.connect")) {
                    onConnect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(appSettings.isLiquidGlassTheme ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(appSettings.palette.appBackground))
        .withoutWritingTools()
    }
}
