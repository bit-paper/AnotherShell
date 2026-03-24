import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SSHHost
    @State private var passwordInput = ""
    @State private var rememberPassword = true
    @State private var loadedKeychainPassword = false
    @State private var showAdvanced = false

    private let onSave: (SSHHost) -> Void

    init(host: SSHHost, onSave: @escaping (SSHHost) -> Void) {
        _draft = State(initialValue: host)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    basicCard

                    authCard

                    advancedCard
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(appSettings.t("button.cancel")) {
                    dismiss()
                }

                Button(appSettings.t("button.save")) {
                    persistPasswordIfNeeded()
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!draft.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(appSettings.palette.panelBackground)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(appSettings.palette.appBackground)
        .withoutWritingTools()
        .onAppear {
            draft.authMethod = .passwordPrompt
            loadPasswordOnce()
        }
        .onChange(of: draft.id) { _, _ in
            loadedKeychainPassword = false
            passwordInput = ""
            rememberPassword = true
            draft.authMethod = .passwordPrompt
            loadPasswordOnce()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(appSettings.palette.accent.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(appSettings.palette.accent)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(appSettings.t("editor.connection_profile"))
                    .font(.headline)
                Text(appSettings.t("editor.simple_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var basicCard: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField(appSettings.t("editor.name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                    TextField(appSettings.t("editor.hostname"), text: $draft.hostname)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    TextField(appSettings.t("editor.username"), text: $draft.username)
                        .textFieldStyle(.roundedBorder)
                    TextField(appSettings.t("editor.port"), value: $draft.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Toggle(appSettings.t("editor.favorite"), isOn: $draft.isFavorite)
                        .toggleStyle(.switch)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(appSettings.t("editor.basic"), systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
        }
    }

    private var authCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker(appSettings.t("editor.method"), selection: $draft.authMethod) {
                    ForEach([SSHAuthMethod.passwordPrompt]) { method in
                        Text(appSettings.authMethodName(method)).tag(method)
                    }
                }
                .pickerStyle(.segmented)

                if draft.authMethod == .passwordPrompt {
                    SecureField(appSettings.t("editor.password"), text: $passwordInput)
                        .textFieldStyle(.roundedBorder)

                    Toggle(appSettings.t("editor.remember_password"), isOn: $rememberPassword)
                        .toggleStyle(.switch)

                    if rememberPassword && KeychainPasswordStore.hasPassword(for: draft) {
                        Text(appSettings.t("editor.password_saved"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(appSettings.t("editor.authentication"), systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
        }
    }

    private var advancedCard: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(spacing: 10) {
                    Toggle(appSettings.t("editor.compression"), isOn: $draft.useCompression)

                    TextField(appSettings.t("editor.keepalive"), value: $draft.keepAliveSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)

                    TextField(appSettings.t("editor.startup"), text: $draft.startupCommand)
                        .textFieldStyle(.roundedBorder)

                    TextField(
                        appSettings.t("editor.tags_placeholder"),
                        text: Binding(
                            get: { draft.tags.joined(separator: ",") },
                            set: { newValue in
                                draft.tags = newValue
                                    .split(separator: ",")
                                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(appSettings.t("editor.note"), text: $draft.note, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)

                    if !draft.forwards.isEmpty {
                        VStack(spacing: 8) {
                            ForEach($draft.forwards) { $rule in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: $rule.enabled)
                                        .labelsHidden()

                                    Picker("", selection: $rule.direction) {
                                        ForEach(PortForwardDirection.allCases) { direction in
                                            Text(appSettings.portForwardDirectionName(direction)).tag(direction)
                                        }
                                    }
                                    .frame(width: 150)

                                    TextField(appSettings.t("editor.forward.local"), value: $rule.localPort, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 90)

                                    TextField(appSettings.t("editor.forward.remote_host"), text: $rule.remoteHost)
                                        .textFieldStyle(.roundedBorder)

                                    TextField(appSettings.t("editor.forward.remote"), value: $rule.remotePort, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 90)

                                    Button(role: .destructive) {
                                        draft.forwards.removeAll { $0.id == rule.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }

                    HStack {
                        Button {
                            draft.forwards.append(PortForwardRule())
                        } label: {
                            Label(appSettings.t("editor.add_rule"), systemImage: "plus")
                        }
                        Spacer()
                    }
                }
                .padding(.top, 10)
            } label: {
                Text(appSettings.t("editor.advanced"))
            }
            .disclosureGroupStyle(.automatic)
            .padding(.top, 4)
        } label: {
            Label(appSettings.t("editor.connection"), systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func loadPasswordOnce() {
        guard !loadedKeychainPassword else { return }
        loadedKeychainPassword = true

        if let stored = KeychainPasswordStore.load(for: draft) {
            passwordInput = stored
            rememberPassword = true
        } else {
            rememberPassword = true
        }
    }

    private func persistPasswordIfNeeded() {
        if draft.authMethod == .passwordPrompt {
            if rememberPassword {
                if !passwordInput.isEmpty {
                    KeychainPasswordStore.save(passwordInput, for: draft)
                }
            } else {
                KeychainPasswordStore.delete(for: draft)
            }
        } else {
            KeychainPasswordStore.delete(for: draft)
        }
    }

}
