import SwiftUI
import AppKit

struct AboutAnotherShellView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var betaVersionLabel: String {
        "Beta \(shortVersion) (\(appSettings.t("about.build")) \(buildVersion))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AnotherShellLogoImage(size: 64, cornerRatio: 0.22)

                VStack(alignment: .leading, spacing: 4) {
                    Text("AnotherShell")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(appSettings.palette.textPrimary)
                    Text(betaVersionLabel)
                        .font(.subheadline)
                        .foregroundStyle(appSettings.palette.textSecondary)
                }
            }

            Divider()

            Text(appSettings.t("about.ai_built"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appSettings.palette.textPrimary)

            Text(appSettings.t("about.intro"))
                .font(.callout)
                .foregroundStyle(appSettings.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(appSettings.t("about.features"))
                .font(.footnote)
                .foregroundStyle(appSettings.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 520)
        .background(
            appSettings.isLiquidGlassTheme
                ? AnyShapeStyle(.regularMaterial)
                : AnyShapeStyle(appSettings.palette.appBackground)
        )
        .withoutWritingTools()
    }
}
