import SwiftUI
import AppKit

struct SyntaxRulesEditorView: View {
    @EnvironmentObject private var syntaxStore: SyntaxHighlightStore
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(appSettings.t("syntax.title"))
                    .font(.title3)
                    .bold()
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)

            List {
                ForEach(syntaxStore.rules) { rule in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: rule.colorHex) ?? .systemOrange))
                            .frame(width: 10, height: 10)
                        Text(rule.name)
                            .font(.body.weight(.semibold))
                        Text(rule.pattern)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }

            HStack {
                Text(appSettings.t("syntax.note"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(appSettings.t("button.done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(appSettings.palette.appBackground)
        .withoutWritingTools()
    }
}
