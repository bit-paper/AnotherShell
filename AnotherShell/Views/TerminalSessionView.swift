import SwiftUI
import Foundation

struct SessionTabStripView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessionManager.sessions) { session in
                    let isSelected = sessionManager.selectedSessionID == session.id
                    let tabTitle = displayTitle(for: session)

                    HStack(spacing: 6) {
                        Button {
                            sessionManager.select(sessionID: session.id)
                        } label: {
                            Text(tabTitle)
                                .lineLimit(1)
                                .frame(maxWidth: 180)
                        }
                        .buttonStyle(.plain)

                        Circle()
                            .fill(color(for: session.state))
                            .frame(width: 8, height: 8)

                        Button {
                            sessionManager.close(sessionID: session.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .frame(width: 22, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.black.opacity(0.0001))
                                )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            TapGesture().onEnded {
                                sessionManager.close(sessionID: session.id)
                            }
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? appSettings.palette.accent.opacity(0.16) : appSettings.palette.panelBackground.opacity(0.75))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? appSettings.palette.accent.opacity(0.7) : appSettings.palette.border, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(appSettings.palette.panelBackground)
    }

    private func color(for state: SSHSessionState) -> Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .failed:
            return .red
        case .disconnected, .idle:
            return .gray
        }
    }

    private func displayTitle(for session: SSHSession) -> String {
        let trimmed = session.host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 1 {
            return session.host.address
        }
        return trimmed
    }
}

struct TerminalSessionView: View {
    @ObservedObject var session: SSHSession

    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var sessionManager: SessionManager

    @StateObject private var sftpModel: SFTPBrowserModel

    @State private var autoScroll = true
    @State private var showingReconnectPasswordSheet = false
    @State private var showingFileTransfer = false
    @State private var reconnectPasswordInput = ""
    @State private var reconnectRememberPassword = true

    init(session: SSHSession) {
        self.session = session
        _sftpModel = StateObject(wrappedValue: SFTPBrowserModel(host: session.host))
    }

    var body: some View {
        terminalArea
        .sheet(isPresented: $showingReconnectPasswordSheet) {
            ReconnectPasswordSheet(
                host: session.host,
                password: $reconnectPasswordInput,
                rememberPassword: $reconnectRememberPassword,
                onCancel: {
                    showingReconnectPasswordSheet = false
                },
                onConnect: {
                    let password = reconnectPasswordInput
                    if reconnectRememberPassword && !password.isEmpty {
                        KeychainPasswordStore.save(password, for: session.host)
                    } else if !reconnectRememberPassword {
                        KeychainPasswordStore.delete(for: session.host)
                    }
                    showingReconnectPasswordSheet = false
                    session.connect(overridePassword: password)
                }
            )
            .environmentObject(appSettings)
            .withoutWritingTools()
        }
        .withoutWritingTools()
        .onAppear {
            sftpModel.setPasswordOverride(session.reusablePassword)
            sftpModel.setPreferredStartupRemotePath(session.currentWorkingDirectory)
        }
        .onChange(of: session.state) { _, _ in
            sftpModel.setPasswordOverride(session.reusablePassword)
            sftpModel.setPreferredStartupRemotePath(session.currentWorkingDirectory)
        }
        .onChange(of: session.currentWorkingDirectory) { _, path in
            sftpModel.setPreferredStartupRemotePath(path)
        }
        .onChange(of: session.needsPasswordRetry) { _, needsRetry in
            guard needsRetry else { return }
            guard session.host.prefersPasswordAuthentication else { return }
            guard session.state == .failed else { return }

            reconnectPasswordInput = KeychainPasswordStore.load(for: session.host) ?? ""
            reconnectRememberPassword = !reconnectPasswordInput.isEmpty
            showingReconnectPasswordSheet = true
            session.clearPasswordRetryRequest()
        }
    }

    private var terminalArea: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VSplitView {
                terminal

                if showingFileTransfer {
                    VStack(spacing: 0) {
                        transferToolbar

                        Divider()

                        SFTPBrowserView(model: sftpModel, embeddedInSession: true)
                            .environmentObject(appSettings)
                    }
                    .frame(minHeight: 240, idealHeight: 320, maxHeight: 500)
                } else {
                    Color.clear
                        .frame(height: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(appSettings.isLiquidGlassTheme ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(appSettings.palette.appBackground))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.host.address)
                        .font(.headline)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(appSettings.sessionStateName(session.state))
                        .foregroundStyle(.secondary)

                    if !session.statusMessage.isEmpty {
                        Text("•")
                            .foregroundStyle(.secondary)

                        Text(session.statusMessage)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Toggle(appSettings.t("terminal.auto_scroll"), isOn: $autoScroll)
                .toggleStyle(.switch)
                .labelsHidden()

            Button(showingFileTransfer ? appSettings.t("terminal.hide_transfer") : appSettings.t("terminal.file_transfer")) {
                guard session.state == .connected else { return }
                sftpModel.setPasswordOverride(session.reusablePassword)
                sftpModel.setPreferredStartupRemotePath(session.currentWorkingDirectory)
                showingFileTransfer.toggle()
                if showingFileTransfer {
                    sftpModel.refreshAll()
                }
            }
            .disabled(session.state != .connected)

            if session.state == .connected || session.state == .connecting {
                Button(appSettings.t("terminal.disconnect")) {
                    session.disconnect()
                }
            } else {
                Button(appSettings.t("terminal.reconnect")) {
                    reconnect()
                }
            }

            Button(appSettings.t("terminal.ctrl_c")) {
                session.sendControlC()
            }
            .disabled(!(session.state == .connected || session.state == .connecting))

            Button(appSettings.t("terminal.clear")) {
                session.clearOutput()
            }

            Button(appSettings.t("terminal.close_tab")) {
                sessionManager.close(sessionID: session.id)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(appSettings.isLiquidGlassTheme ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(appSettings.palette.panelBackground))
    }

    private var terminal: some View {
        SwiftTermTerminalView(
            session: session,
            baseTextColor: appSettings.palette.terminalForeground,
            backgroundColor: appSettings.palette.terminalBackground
        )
        .id(session.terminalSurfaceID)
        .background(appSettings.palette.terminalBackground)
    }

    private var transferToolbar: some View {
        HStack(spacing: 8) {
            Text(appSettings.t("terminal.file_transfer"))
                .font(.subheadline.weight(.semibold))

            Text("\(appSettings.t("terminal.transfer.local")): \(sftpModel.currentLocalURL.path)")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Text("•")
                .foregroundStyle(.secondary)

            Text("\(appSettings.t("terminal.transfer.remote")): \(sftpModel.currentRemotePath)")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            Button(appSettings.t("terminal.transfer.refresh")) {
                sftpModel.refreshAll()
            }
            .buttonStyle(.bordered)

            Button(appSettings.t("terminal.transfer.hide")) {
                showingFileTransfer = false
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(appSettings.isLiquidGlassTheme ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(appSettings.palette.panelBackground))
    }

    private func reconnect() {
        if session.host.prefersPasswordAuthentication {
            let saved = KeychainPasswordStore.load(for: session.host) ?? ""
            if saved.isEmpty {
                reconnectPasswordInput = ""
                reconnectRememberPassword = true
                showingReconnectPasswordSheet = true
            } else {
                session.connect()
            }
            return
        }

        session.connect()
    }

}

private struct ReconnectPasswordSheet: View {
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
        .background(appSettings.palette.appBackground)
        .withoutWritingTools()
    }
}
