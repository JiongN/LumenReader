import SwiftUI
import LumenKit

struct ModelPurposeSettings: View {
    @EnvironmentObject private var settings: SettingsStore
    var purposes: [AIModelPurpose] = AIModelPurpose.allCases

    var body: some View {
        Section("用途与模型") {
            ForEach(purposes, id: \.self) { purpose in
                Picker("\(purpose.label)服务商", selection: providerBinding(purpose)) {
                    if purpose != .chat || settings.ai.providers.isEmpty {
                        Text("未配置").tag(UUID?.none)
                    }
                    if let id = settings.providerID(for: purpose),
                       !settings.ai.providers.contains(where: { $0.id == id }) {
                        Text("服务商已移除").tag(Optional(id))
                    }
                    ForEach(settings.ai.providers) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                LabeledField(label: "\(purpose.label)模型") {
                    ModelNameField(selection: modelBinding(purpose), models: models(purpose))
                        .disabled(!settings.ai.providers.contains { $0.id == settings.providerID(for: purpose) })
                }
            }
        }
    }

    private func models(_ purpose: AIModelPurpose) -> [String] {
        settings.ai.providers.first { $0.id == settings.providerID(for: purpose) }?.models ?? []
    }

    private func providerBinding(_ purpose: AIModelPurpose) -> Binding<UUID?> {
        Binding(get: { settings.providerID(for: purpose) },
                set: { settings.selectProvider(id: $0, for: purpose) })
    }

    private func modelBinding(_ purpose: AIModelPurpose) -> Binding<String> {
        Binding(get: { settings.model(for: purpose) },
                set: { settings.selectModel($0, for: purpose) })
    }
}

/// A bounded, searchable catalog; manually entered model IDs remain valid.
struct ModelNameField: View {
    @Binding var selection: String
    var models: [String]
    @State private var isPresented = false
    @State private var query = ""

    private var matches: [String] {
        models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("模型 ID", text: $selection)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(DS.Typo.mono)
            Button {
                query = ""
                isPresented = true
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("选择模型")
            .disabled(models.isEmpty)
            .popover(isPresented: $isPresented) {
                VStack(spacing: 8) {
                    TextField("搜索模型", text: $query)
                        .textFieldStyle(.roundedBorder)
                    if matches.isEmpty {
                        Text("无匹配模型").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(matches, id: \.self) { model in
                                    Button {
                                        selection = model
                                        isPresented = false
                                    } label: {
                                        HStack {
                                            Text(model).lineLimit(2).multilineTextAlignment(.leading)
                                            Spacer(minLength: 6)
                                            if selection == model { Image(systemName: "checkmark") }
                                        }
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                    }
                }
                .padding(12)
                .frame(width: 360)
            }
        }
    }
}
