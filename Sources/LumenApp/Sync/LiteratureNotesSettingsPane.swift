import SwiftUI
import AppKit

struct LiteratureNotesSettingsPane: View {
    @StateObject private var sync = LiteratureSyncService.shared

    var body: some View {
        Form {
            Section("Obsidian 文献页") {
                HStack {
                    Text(sync.notesDirectory.isEmpty ? "尚未选择文献笔记目录" : sync.notesDirectory)
                        .lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("选择…") { sync.chooseDirectory() }
                }
                Toggle("自动同步 Lumen 批注", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                Text("原文批注单向同步到 Obsidian；属性和阅读笔记支持双向编辑。无需打开 Zotero，也可首次创建笔记；可用题录自动填写，Zotero 启动后自动核对关联。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = sync.error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            Section("已关联文献") {
                if sync.records.isEmpty {
                    Text("开启后，在文献笔记侧栏为需要的文献打开同步开关。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sync.records) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.title).lineLimit(1)
                                Text(record.paused ? "已暂停" : (sync.statuses[record.documentPath] ?? "等待同步"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("打开") { sync.openNote(for: record.documentPath) }
                            Button(record.paused ? "继续" : "暂停") { sync.setPaused(!record.paused, recordID: record.id) }
                            Button("同步") { Task { await sync.syncNow(recordID: record.id) } }
                                .disabled(!sync.enabled || record.paused)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
