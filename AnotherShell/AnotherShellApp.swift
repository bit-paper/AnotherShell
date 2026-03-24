import SwiftUI

@main
struct AnotherShellApp: App {
    @StateObject private var appSettings = AppSettingsStore()
    @StateObject private var hostStore = HostStore()
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var quickCommandStore = QuickCommandStore()
    @StateObject private var syntaxHighlightStore = SyntaxHighlightStore()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if appSettings.isLiquidGlassTheme {
                    LiquidGlassBackgroundLayer()
                } else {
                    appSettings.palette.appBackground
                        .ignoresSafeArea()
                }

                ContentView()
                    .environmentObject(appSettings)
                    .environmentObject(hostStore)
                    .environmentObject(sessionManager)
                    .environmentObject(quickCommandStore)
                    .environmentObject(syntaxHighlightStore)
                    .environment(\.locale, appSettings.language.writingToolsLocale)
                    .frame(minWidth: 1100, minHeight: 700)
                    .foregroundStyle(appSettings.palette.textPrimary)
                    .tint(appSettings.palette.accent)
                    .preferredColorScheme(appSettings.palette.preferredColorScheme)
                    .animation(.easeInOut(duration: 0.28), value: appSettings.theme)
                    .withoutWritingTools()
            }
        }
        .windowResizability(.contentSize)
        .commands {
            AnotherShellAppCommands()
        }

        Window("About AnotherShell", id: "about") {
            AboutAnotherShellView()
                .environmentObject(appSettings)
                .environment(\.locale, appSettings.language.writingToolsLocale)
                .background(
                    Group {
                        if appSettings.isLiquidGlassTheme {
                            LiquidGlassBackgroundLayer()
                        } else {
                            appSettings.palette.appBackground
                        }
                    }
                )
                .tint(appSettings.palette.accent)
                .preferredColorScheme(appSettings.palette.preferredColorScheme)
                .withoutWritingTools()
        }
        .windowResizability(.contentSize)

        Settings {
            AppSettingsView()
                .environmentObject(appSettings)
                .environmentObject(syntaxHighlightStore)
                .environment(\.locale, appSettings.language.writingToolsLocale)
                .background(
                    Group {
                        if appSettings.isLiquidGlassTheme {
                            LiquidGlassBackgroundLayer()
                        } else {
                            appSettings.palette.appBackground
                        }
                    }
                )
                .foregroundStyle(appSettings.palette.textPrimary)
                .tint(appSettings.palette.accent)
                .preferredColorScheme(appSettings.palette.preferredColorScheme)
                .animation(.easeInOut(duration: 0.28), value: appSettings.theme)
                .withoutWritingTools()
        }
    }
}

private struct AnotherShellAppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About AnotherShell") {
                openWindow(id: "about")
            }
        }
    }
}
