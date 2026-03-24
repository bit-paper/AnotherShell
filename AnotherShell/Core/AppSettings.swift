import Foundation
import SwiftUI
import Combine
import AppKit

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case english
    case chineseSimplified

    var id: String { rawValue }

    var isoLanguageCode: String {
        switch self {
        case .english:
            return "en"
        case .chineseSimplified:
            return "zh"
        }
    }

    var locale: Locale {
        switch self {
        case .english:
            return Locale(identifier: "en_US_POSIX")
        case .chineseSimplified:
            return Locale(identifier: "zh_Hans_CN")
        }
    }

    var writingToolsLocale: Locale {
        Locale(identifier: isoLanguageCode)
    }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case liquidGlass
    case oceanNight
    case graphiteLight
    case forestDark
    case solarizedLight

    var id: String { rawValue }

    var palette: AppThemePalette {
        switch self {
        case .system:
            return AppThemePalette(
                accent: .accentColor,
                appBackground: Color(nsColor: .windowBackgroundColor),
                panelBackground: Color(nsColor: .controlBackgroundColor),
                terminalBackground: Color(nsColor: .textBackgroundColor),
                terminalForeground: Color(nsColor: .textColor),
                terminalSubtle: .gray,
                border: .gray.opacity(0.28),
                textPrimary: Color(nsColor: .labelColor),
                textSecondary: Color(nsColor: .secondaryLabelColor),
                preferredColorScheme: nil
            )
        case .liquidGlass:
            return AppThemePalette(
                accent: Color(hex: "#7CCBFF"),
                appBackground: Color(hex: "#10182B"),
                panelBackground: Color.white.opacity(0.14),
                terminalBackground: Color(hex: "#0B1220").opacity(0.78),
                terminalForeground: Color(hex: "#E8F2FF"),
                terminalSubtle: Color(hex: "#9DB0C9"),
                border: Color.white.opacity(0.32),
                textPrimary: Color(hex: "#F4F8FF"),
                textSecondary: Color(hex: "#C4D2E6"),
                preferredColorScheme: .dark
            )
        case .oceanNight:
            return AppThemePalette(
                accent: Color(hex: "#4FC3F7"),
                appBackground: Color(hex: "#0B1725"),
                panelBackground: Color(hex: "#102034"),
                terminalBackground: Color(hex: "#07111D"),
                terminalForeground: Color(hex: "#7FE8FF"),
                terminalSubtle: Color(hex: "#3E8AA4"),
                border: Color(hex: "#1E3A52"),
                textPrimary: Color(hex: "#E6F4FF"),
                textSecondary: Color(hex: "#9FC4D8"),
                preferredColorScheme: .dark
            )
        case .graphiteLight:
            return AppThemePalette(
                accent: Color(hex: "#4B5563"),
                appBackground: Color(hex: "#F4F5F7"),
                panelBackground: .white,
                terminalBackground: Color(hex: "#F1F3F5"),
                terminalForeground: Color(hex: "#1F2937"),
                terminalSubtle: Color(hex: "#6B7280"),
                border: Color(hex: "#D1D5DB"),
                textPrimary: Color(hex: "#111827"),
                textSecondary: Color(hex: "#6B7280"),
                preferredColorScheme: .light
            )
        case .forestDark:
            return AppThemePalette(
                accent: Color(hex: "#7DDB7A"),
                appBackground: Color(hex: "#0E1A12"),
                panelBackground: Color(hex: "#14271A"),
                terminalBackground: Color(hex: "#09120C"),
                terminalForeground: Color(hex: "#A8F8A2"),
                terminalSubtle: Color(hex: "#5DA66A"),
                border: Color(hex: "#274230"),
                textPrimary: Color(hex: "#E7FCE8"),
                textSecondary: Color(hex: "#9CC7A3"),
                preferredColorScheme: .dark
            )
        case .solarizedLight:
            return AppThemePalette(
                accent: Color(hex: "#268BD2"),
                appBackground: Color(hex: "#FDF6E3"),
                panelBackground: Color(hex: "#EEE8D5"),
                terminalBackground: Color(hex: "#F8F0D9"),
                terminalForeground: Color(hex: "#586E75"),
                terminalSubtle: Color(hex: "#93A1A1"),
                border: Color(hex: "#D6C9A5"),
                textPrimary: Color(hex: "#3D4A4F"),
                textSecondary: Color(hex: "#7A878C"),
                preferredColorScheme: .light
            )
        }
    }
}

struct AppThemePalette {
    let accent: Color
    let appBackground: Color
    let panelBackground: Color
    let terminalBackground: Color
    let terminalForeground: Color
    let terminalSubtle: Color
    let border: Color
    let textPrimary: Color
    let textSecondary: Color
    let preferredColorScheme: ColorScheme?
}

private struct AppPreferencesDTO: Codable {
    var language: AppLanguage
    var theme: AppTheme
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var language: AppLanguage = .english {
        didSet { save() }
    }

    @Published var theme: AppTheme = .system {
        didSet { save() }
    }

    var palette: AppThemePalette {
        theme.palette
    }

    init() {
        load()
        PasswordStoragePreference.useSystemKeychain = false
    }

    func t(_ key: String) -> String {
        let fallback = Self.dictionary[.english] ?? [:]
        let languageMap = Self.dictionary[language] ?? fallback
        return languageMap[key] ?? fallback[key] ?? key
    }

    func tf(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: language.locale, arguments: arguments)
    }

    func languageName(_ item: AppLanguage) -> String {
        switch item {
        case .english:
            return t("settings.language.english")
        case .chineseSimplified:
            return t("settings.language.chinese")
        }
    }

    func themeName(_ item: AppTheme) -> String {
        switch item {
        case .system:
            return t("settings.theme.system")
        case .liquidGlass:
            return t("settings.theme.liquid")
        case .oceanNight:
            return t("settings.theme.ocean")
        case .graphiteLight:
            return t("settings.theme.graphite")
        case .forestDark:
            return t("settings.theme.forest")
        case .solarizedLight:
            return t("settings.theme.solarized")
        }
    }

    func authMethodName(_ method: SSHAuthMethod) -> String {
        switch method {
        case .sshAgent:
            return t("auth.ssh_agent")
        case .privateKey:
            return t("auth.private_key")
        case .passwordPrompt:
            return t("auth.password")
        }
    }

    func portForwardDirectionName(_ direction: PortForwardDirection) -> String {
        switch direction {
        case .local:
            return t("forward.local")
        case .remote:
            return t("forward.remote")
        case .dynamic:
            return t("forward.dynamic")
        }
    }

    func sessionStateName(_ state: SSHSessionState) -> String {
        switch state {
        case .idle:
            return t("state.idle")
        case .connecting:
            return t("state.connecting")
        case .connected:
            return t("state.connected")
        case .disconnected:
            return t("state.disconnected")
        case .failed:
            return t("state.failed")
        }
    }

    private var fileURL: URL {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("AnotherShell", isDirectory: true)

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir.appendingPathComponent("app_preferences.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppPreferencesDTO.self, from: data) else {
            return
        }

        language = config.language
        theme = config.theme
    }

    private func save() {
        let dto = AppPreferencesDTO(
            language: language,
            theme: theme
        )
        guard let data = try? JSONEncoder().encode(dto) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let dictionary: [AppLanguage: [String: String]] = [
        .english: [
            "toolbar.new_host": "New Host",
            "toolbar.edit_host": "Edit Host",
            "toolbar.connect": "Connect",
            "toolbar.close_all": "Close All",
            "toolbar.settings": "Settings",
            "section.hosts": "Hosts",
            "section.active_sessions": "Active Sessions",
            "section.session_status": "Session Status",
            "empty.no_hosts": "No hosts yet",
            "empty.no_sessions": "No active sessions",
            "menu.connect": "Connect",
            "menu.favorite": "Favorite",
            "menu.unfavorite": "Unfavorite",
            "menu.edit": "Edit",
            "menu.delete": "Delete",
            "app.name": "AnotherShell",
            "welcome.description": "Create a host and open your first SSH session",
            "host.port_format": "Port: %d",
            "button.connect": "Connect",
            "button.edit": "Edit",
            "button.cancel": "Cancel",
            "button.save": "Save",
            "button.done": "Done",
            "button.browse": "Browse",
            "state.idle": "Idle",
            "state.connecting": "Connecting",
            "state.connected": "Connected",
            "state.disconnected": "Disconnected",
            "state.failed": "Failed",
            "editor.basic": "Basic",
            "editor.connection_profile": "Connection Profile",
            "editor.simple_hint": "Keep it simple: fill address, auth, and connect.",
            "editor.name": "Name",
            "editor.hostname": "Hostname / IP",
            "editor.username": "Username",
            "editor.port": "Port",
            "editor.favorite": "Favorite",
            "editor.auth": "Authentication",
            "editor.authentication": "Authentication",
            "editor.method": "Method",
            "editor.private_key_path": "Private key path",
            "editor.password": "Password",
            "editor.remember_password": "Remember password",
            "editor.password_saved": "Password is currently saved.",
            "editor.connection": "Connection",
            "editor.advanced": "Advanced Options",
            "editor.strict_host_key": "Strict host key checking",
            "editor.compression": "Enable compression",
            "editor.keepalive": "KeepAlive (seconds)",
            "editor.startup": "Startup command",
            "editor.forwards": "Port Forward Rules",
            "editor.no_forwards": "No forwarding rules yet",
            "editor.forward.local": "Local",
            "editor.forward.remote_host": "Remote Host",
            "editor.forward.remote": "Remote",
            "editor.add_rule": "Add Rule",
            "editor.tags_note": "Tags & Note",
            "editor.tags_placeholder": "Tags (comma separated)",
            "editor.note": "Note",
            "auth.ssh_agent": "SSH Agent",
            "auth.private_key": "Private Key",
            "auth.password": "Password (interactive)",
            "forward.local": "Local (-L)",
            "forward.remote": "Remote (-R)",
            "forward.dynamic": "Dynamic SOCKS (-D)",
            "terminal.auto_scroll": "Auto-scroll",
            "terminal.highlight_rules": "Highlight Rules",
            "terminal.disconnect": "Disconnect",
            "terminal.reconnect": "Reconnect",
            "terminal.ctrl_c": "Ctrl+C",
            "terminal.clear": "Clear",
            "terminal.upload": "Upload",
            "terminal.uploading": "Uploading...",
            "terminal.input_placeholder": "Type command and press Enter",
            "terminal.send": "Send",
            "terminal.save_quick": "Save Quick",
            "terminal.fallback_prompt": "Connected. Start typing commands below...",
            "terminal.truncated_format": "[Output truncated to latest %d chars]",
            "sftp.title": "SFTP Browser",
            "sftp.local": "Local",
            "sftp.local_path": "Local path",
            "sftp.remote": "Remote",
            "sftp.upload_selected": "Upload Selected",
            "sftp.download_selected": "Download Selected",
            "sftp.retry": "Retry",
            "sftp.remote_path": "Remote path",
            "sftp.go": "Go",
            "sftp.download_to": "Download To...",
            "sftp.select_download_folder": "Select Download Folder",
            "sftp.download_here": "Download Here",
            "sftp.permission_hint": "Permission denied on this path.",
            "sftp.request_permission": "Authorize Access",
            "syntax.title": "Terminal Syntax Rules",
            "syntax.add_rule": "Add Rule",
            "syntax.note": "Rules are regex-based and applied client-side, even if remote output has no color.",
            "syntax.name": "Name",
            "syntax.pattern": "Regex Pattern",
            "syntax.enable": "Enable",
            "syntax.case_insensitive": "Case-Insensitive",
            "syntax.bold": "Bold",
            "syntax.invalid": "Invalid regex pattern",
            "settings.title": "Settings",
            "settings.language": "Language",
            "settings.theme": "Theme",
            "settings.language.english": "英语",
            "settings.language.chinese": "Chinese (Simplified)",
            "settings.theme.system": "System",
            "settings.theme.liquid": "Liquid Glass",
            "settings.theme.ocean": "Ocean Night",
            "settings.theme.graphite": "Graphite Light",
            "settings.theme.forest": "Forest Dark",
            "settings.theme.solarized": "Solarized Light",
            "settings.password_storage": "Password Storage",
            "settings.use_system_keychain": "Use macOS Keychain",
            "settings.password_storage_hint": "Turn this off to keep passwords only in AnotherShell local storage.",
            "settings.ssh_access": "SSH Config Access",
            "settings.ssh_access_hint": "Grant access to ~/.ssh so AnotherShell can use your real known_hosts file.",
            "settings.ssh_access_grant": "Grant ~/.ssh Access",
            "settings.ssh_access_revoke": "Remove Access",
            "settings.ssh_access_not_granted": "Not granted",
            "settings.ssh_access_granted_format": "Granted: %s",
            "settings.preview": "Theme Preview",
            "settings.preview.body": "Your preference is saved automatically and applies immediately.",
            "settings.subtitle": "Language and theme are applied globally across the app.",
            "settings.section.appearance": "Appearance",
            "settings.section.about": "Simple Mode",
            "settings.simple_mode_hint": "AnotherShell now uses built-in local password storage and simplified SSH settings for a cleaner experience.",
            "settings.open_terminal_theme_hint": "Terminal, sidebar and detail pages now follow the same theme family.",
            "terminal.file_transfer": "File Transfer",
            "terminal.hide_transfer": "Hide Transfer",
            "terminal.close_tab": "Close Tab",
            "terminal.transfer.local": "Local",
            "terminal.transfer.remote": "Remote",
            "terminal.transfer.refresh": "Refresh",
            "terminal.transfer.hide": "Hide",
            "terminal.metric.os": "OS",
            "terminal.metric.model": "Model",
            "terminal.metric.mem": "Mem",
            "terminal.metric.disk": "Disk",
            "terminal.metric.down": "Down",
            "terminal.metric.up": "Up",
            "terminal.metric.memory": "Memory",
            "terminal.metric.network": "Network",
            "terminal.metric.na": "N/A",
            "password.prompt.title": "Enter SSH Password",
            "password.prompt.message": "Host: %s",
            "password.prompt.placeholder": "Password",
            "password.prompt.remember": "Remember password",
            "password.prompt.connect": "Connect",
            "about.build": "Build",
            "about.ai_built": "This product is built end-to-end by AI collaboration.",
            "about.intro": "AnotherShell is a native macOS SSH/SFTP workspace focused on tab sessions, integrated file transfer, and cross-system terminal consistency.",
            "about.features": "Highlights: embedded SSH client, tabbed terminal sessions, split SFTP transfer panel, client-side syntax highlighting, bilingual UI, and theme system."
        ],
        .chineseSimplified: [
            "toolbar.new_host": "新建主机",
            "toolbar.edit_host": "编辑主机",
            "toolbar.connect": "连接",
            "toolbar.close_all": "关闭全部",
            "toolbar.settings": "设置",
            "section.hosts": "主机",
            "section.active_sessions": "活动会话",
            "section.session_status": "会话状态",
            "empty.no_hosts": "暂无主机",
            "empty.no_sessions": "暂无活动会话",
            "menu.connect": "连接",
            "menu.favorite": "收藏",
            "menu.unfavorite": "取消收藏",
            "menu.edit": "编辑",
            "menu.delete": "删除",
            "app.name": "AnotherShell",
            "welcome.description": "先创建一个主机，然后打开第一个 SSH 会话",
            "host.port_format": "端口：%d",
            "button.connect": "连接",
            "button.edit": "编辑",
            "button.cancel": "取消",
            "button.save": "保存",
            "button.done": "完成",
            "button.browse": "浏览",
            "state.idle": "空闲",
            "state.connecting": "连接中",
            "state.connected": "已连接",
            "state.disconnected": "已断开",
            "state.failed": "失败",
            "editor.basic": "基础",
            "editor.connection_profile": "连接配置",
            "editor.simple_hint": "尽量简化：填写地址、认证方式后即可连接。",
            "editor.name": "名称",
            "editor.hostname": "主机名 / IP",
            "editor.username": "用户名",
            "editor.port": "端口",
            "editor.favorite": "收藏",
            "editor.auth": "认证",
            "editor.authentication": "认证方式",
            "editor.method": "方式",
            "editor.private_key_path": "私钥路径",
            "editor.password": "密码",
            "editor.remember_password": "记住密码",
            "editor.password_saved": "密码已保存。",
            "editor.connection": "连接",
            "editor.advanced": "高级选项",
            "editor.strict_host_key": "严格主机密钥校验",
            "editor.compression": "启用压缩",
            "editor.keepalive": "KeepAlive（秒）",
            "editor.startup": "启动命令",
            "editor.forwards": "端口转发规则",
            "editor.no_forwards": "暂无转发规则",
            "editor.forward.local": "本地",
            "editor.forward.remote_host": "远程主机",
            "editor.forward.remote": "远程端口",
            "editor.add_rule": "添加规则",
            "editor.tags_note": "标签与备注",
            "editor.tags_placeholder": "标签（逗号分隔）",
            "editor.note": "备注",
            "auth.ssh_agent": "SSH Agent",
            "auth.private_key": "私钥",
            "auth.password": "密码（交互输入）",
            "forward.local": "本地转发 (-L)",
            "forward.remote": "远程转发 (-R)",
            "forward.dynamic": "动态 SOCKS (-D)",
            "terminal.auto_scroll": "自动滚动",
            "terminal.highlight_rules": "高亮规则",
            "terminal.disconnect": "断开",
            "terminal.reconnect": "重连",
            "terminal.ctrl_c": "Ctrl+C",
            "terminal.clear": "清空",
            "terminal.upload": "上传",
            "terminal.uploading": "上传中...",
            "terminal.input_placeholder": "输入命令后回车",
            "terminal.send": "发送",
            "terminal.save_quick": "保存快捷",
            "terminal.fallback_prompt": "已连接。请在下方输入命令...",
            "terminal.truncated_format": "[输出已截断，仅保留最近 %d 个字符]",
            "sftp.title": "SFTP 浏览器",
            "sftp.local": "本地",
            "sftp.local_path": "本地路径",
            "sftp.remote": "远程",
            "sftp.upload_selected": "上传所选",
            "sftp.download_selected": "下载所选",
            "sftp.retry": "重试",
            "sftp.remote_path": "远程路径",
            "sftp.go": "前往",
            "sftp.download_to": "下载到...",
            "sftp.select_download_folder": "选择下载目录",
            "sftp.download_here": "下载到此处",
            "sftp.permission_hint": "当前目录权限不足。",
            "sftp.request_permission": "请求授权",
            "syntax.title": "终端语法高亮规则",
            "syntax.add_rule": "添加规则",
            "syntax.note": "规则使用正则表达式并在客户端着色，即使远端不支持颜色也可高亮。",
            "syntax.name": "名称",
            "syntax.pattern": "正则表达式",
            "syntax.enable": "启用",
            "syntax.case_insensitive": "忽略大小写",
            "syntax.bold": "加粗",
            "syntax.invalid": "正则表达式无效",
            "settings.title": "设置",
            "settings.language": "语言",
            "settings.theme": "主题",
            "settings.language.english": "English",
            "settings.language.chinese": "简体中文",
            "settings.theme.system": "跟随系统",
            "settings.theme.liquid": "液态玻璃",
            "settings.theme.ocean": "海夜",
            "settings.theme.graphite": "石墨浅色",
            "settings.theme.forest": "森林深色",
            "settings.theme.solarized": "Solarized 浅色",
            "settings.password_storage": "密码存储",
            "settings.use_system_keychain": "使用 macOS 钥匙串",
            "settings.password_storage_hint": "关闭后，密码只保存在 AnotherShell 本地存储中。",
            "settings.ssh_access": "SSH 配置访问权限",
            "settings.ssh_access_hint": "授权访问 ~/.ssh 后，AnotherShell 就能使用你真实的 known_hosts 文件。",
            "settings.ssh_access_grant": "授权 ~/.ssh",
            "settings.ssh_access_revoke": "移除授权",
            "settings.ssh_access_not_granted": "未授权",
            "settings.ssh_access_granted_format": "已授权：%s",
            "settings.preview": "主题预览",
            "settings.preview.body": "设置会自动保存，并立即生效。",
            "settings.subtitle": "语言和主题会全局应用到整个应用。",
            "settings.section.appearance": "外观",
            "settings.section.about": "简洁模式",
            "settings.simple_mode_hint": "AnotherShell 现已默认使用本地密码存储，并简化 SSH 设置项，界面更清爽。",
            "settings.open_terminal_theme_hint": "终端、侧栏和详情区会使用同一套主题风格。",
            "terminal.file_transfer": "文件传输",
            "terminal.hide_transfer": "收起传输",
            "terminal.close_tab": "关闭标签",
            "terminal.transfer.local": "本地",
            "terminal.transfer.remote": "远程",
            "terminal.transfer.refresh": "刷新",
            "terminal.transfer.hide": "收起",
            "terminal.metric.os": "系统",
            "terminal.metric.model": "型号",
            "terminal.metric.mem": "内存",
            "terminal.metric.disk": "磁盘",
            "terminal.metric.down": "下行",
            "terminal.metric.up": "上行",
            "terminal.metric.memory": "内存",
            "terminal.metric.network": "网络",
            "terminal.metric.na": "暂无",
            "password.prompt.title": "输入 SSH 密码",
            "password.prompt.message": "主机：%s",
            "password.prompt.placeholder": "密码",
            "password.prompt.remember": "记住密码",
            "password.prompt.connect": "连接",
            "about.build": "构建号",
            "about.ai_built": "本软件由 AI 协作方式端到端构建。",
            "about.intro": "AnotherShell 是一款原生 macOS SSH/SFTP 工作台，强调标签会话、集成文件传输和跨系统一致终端体验。",
            "about.features": "核心能力：内置 SSH 客户端、标签终端、多系统文件传输面板、客户端高亮、中英文双语和主题系统。"
        ]
    ]
}

extension Color {
    init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        let value = Int(cleaned, radix: 16) ?? 0
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    var nsColor: NSColor {
        NSColor(self)
    }
}

extension AppSettingsStore {
    var isLiquidGlassTheme: Bool {
        theme == .liquidGlass
    }
}

struct LiquidGlassBackgroundLayer: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "#0A1730"),
                    Color(hex: "#111E39"),
                    Color(hex: "#121A2E")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(hex: "#7FD2FF").opacity(0.32),
                    .clear
                ],
                center: .topLeading,
                startRadius: 30,
                endRadius: 460
            )

            RadialGradient(
                colors: [
                    Color(hex: "#BFD6FF").opacity(0.22),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}
