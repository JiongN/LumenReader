import SwiftUI
import LumenKit

struct TranslationModelMenu: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openSettings) private var openSettings
    @State private var isPresented = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            modelMenu.fixedSize()
            modelMenu
        }
    }

    private var modelMenu: some View {
        let selected = settings.translationProvider
        return Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Label(selected?.selectedModel ?? "选择翻译模型", systemImage: "cpu")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            Form {
                ModelPurposeSettings(purposes: [.translation])
                Button("更多 AI 设置…") {
                    isPresented = false
                    openSettings()
                }
            }
            .formStyle(.grouped)
            .frame(width: 480, height: 215)
        }
        .help("翻译模型：\(selected?.name ?? "未配置") · \(selected?.selectedModel ?? "")")
    }
}
