import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    private let themeColumns = [
        GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appSettings.t("settings.title"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(appSettings.palette.textPrimary)
                    Text(appSettings.t("settings.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(appSettings.palette.textSecondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(appSettings.t("settings.section.appearance"))
                            .font(.headline)
                            .foregroundStyle(appSettings.palette.textPrimary)

                        Picker(appSettings.t("settings.language"), selection: $appSettings.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(appSettings.languageName(language)).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(appSettings.t("settings.theme"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(appSettings.palette.textPrimary)

                        LazyVGrid(columns: themeColumns, spacing: 10) {
                            ForEach(AppTheme.allCases) { theme in
                                let palette = theme.palette
                                Button {
                                    withAnimation(.easeInOut(duration: 0.28)) {
                                        appSettings.theme = theme
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(palette.accent)
                                                .frame(width: 10, height: 10)
                                            Text(appSettings.themeName(theme))
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                                .foregroundStyle(palette.textPrimary)
                                        }

                                        HStack(spacing: 6) {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(palette.appBackground)
                                                .frame(height: 12)
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(palette.panelBackground)
                                                .frame(height: 12)
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(palette.terminalBackground)
                                                .frame(height: 12)
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        theme == .liquidGlass
                                            ? AnyShapeStyle(.ultraThinMaterial)
                                            : AnyShapeStyle(palette.panelBackground.opacity(0.9))
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                appSettings.theme == theme ? appSettings.palette.accent : palette.border,
                                                lineWidth: appSettings.theme == theme ? 2 : 1
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(appSettings.t("settings.preview"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(appSettings.palette.textPrimary)

                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(appSettings.palette.appBackground)
                                    .frame(width: 56, height: 32)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(appSettings.palette.border))

                                RoundedRectangle(cornerRadius: 8)
                                    .fill(appSettings.palette.panelBackground)
                                    .frame(width: 56, height: 32)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(appSettings.palette.border))

                                RoundedRectangle(cornerRadius: 8)
                                    .fill(appSettings.palette.terminalBackground)
                                    .frame(width: 56, height: 32)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(appSettings.palette.border))

                                Circle()
                                    .fill(appSettings.palette.accent)
                                    .frame(width: 22, height: 22)
                            }

                            Text(appSettings.t("settings.preview.body"))
                                .font(.footnote)
                                .foregroundStyle(appSettings.palette.textSecondary)
                            Text(appSettings.t("settings.open_terminal_theme_hint"))
                                .font(.footnote)
                                .foregroundStyle(appSettings.palette.textSecondary)
                        }
                    }
                    .padding(.top, 8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appSettings.t("settings.section.about"))
                            .font(.headline)
                            .foregroundStyle(appSettings.palette.textPrimary)
                        Text(appSettings.t("settings.simple_mode_hint"))
                            .font(.footnote)
                            .foregroundStyle(appSettings.palette.textSecondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 340)
        .background(
            appSettings.isLiquidGlassTheme
                ? AnyShapeStyle(.regularMaterial)
                : AnyShapeStyle(appSettings.palette.appBackground)
        )
        .foregroundStyle(appSettings.palette.textPrimary)
        .animation(.easeInOut(duration: 0.28), value: appSettings.theme)
        .withoutWritingTools()
    }
}
