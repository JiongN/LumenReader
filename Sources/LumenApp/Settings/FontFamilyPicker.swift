import SwiftUI
import LumenKit

/// 「指定字体」选择器。
///
/// 做成「弹层 + 搜索」而不是一个普通下拉：系统里可用的字体族有三百多个，
/// `Picker` 铺出来是一份无法检索的长名单，用户找 `Songti SC` 得滚很久。
///
/// 预览区里放的是**中英混排**的样例，不是单行占位文字——选字体最常踩的坑是
/// "这款字体没有中文字形"或"没有数字"，只给中文样例或只给英文样例都测不出来。
struct FontFamilyPicker: View {

    /// nil = 不指定，走回落
    @Binding var selection: String?
    /// 未指定时的回落说明。写作「跟随『宋体』」或「系统默认」。
    let fallbackLabel: String
    /// 打开弹层时落在哪个分组
    let initialGroup: FontCatalog.Group

    @State private var isPresenting = false

    var body: some View {
        HStack {
            Text("指定字体")

            Spacer(minLength: DS.Space.m)

            Button {
                isPresenting = true
            } label: {
                HStack(spacing: DS.Space.s) {
                    Text(currentLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(DS.Typo.ui(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .frame(maxWidth: 280, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.accent)
        }
        .popover(isPresented: $isPresenting, arrowEdge: .bottom) {
            FontFamilyPopover(
                selection: $selection,
                fallbackLabel: fallbackLabel,
                initialGroup: initialGroup,
                isPresented: $isPresenting
            )
        }
    }

    private var currentLabel: String {
        guard let selection, !selection.isEmpty else {
            return "自动（\(fallbackLabel)）"
        }
        return selection
    }
}

private struct FontFamilyPopover: View {

    @Binding var selection: String?
    let fallbackLabel: String
    let initialGroup: FontCatalog.Group
    @Binding var isPresented: Bool

    @State private var catalogGroup: FontCatalog.Group = .sansSerif
    @State private var query = ""
    /// 字体目录要枚举三百多个族，放进 body 里算会每次渲染都跑一遍，所以缓存在状态里。
    @State private var families: [FontCatalog.Family] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            familyList
            Divider()
            preview
        }
        .frame(width: 460, height: 460)
        .task {
            // 目录在后台枚举，弹层先出来再填内容——不能反过来让弹层等目录
            await FontCatalog.load()
            families = FontCatalog.all()
            // 打开时落在当前选中字体所在的分组，省得用户还要自己切页
            if let selection, let match = families.first(where: { $0.name == selection }) {
                catalogGroup = match.group
            } else {
                catalogGroup = initialGroup
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Picker("", selection: $catalogGroup) {
                ForEach(FontCatalog.Group.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("自动") {
                selection = nil
                isPresented = false
            }
            .help("不指定具体字体，回落为\(fallbackLabel)")
        }
        .padding(DS.Space.m)
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Palette.textTertiary)
            TextField("搜索字体名，如 Songti 或 宋体", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Typo.ui(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }

    private var familyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if families.isEmpty {
                    HStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("正在读取系统字体…")
                            .font(DS.Typo.ui(size: 12))
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    .padding(DS.Space.m)
                } else if visibleFamilies.isEmpty {
                    Text("没有匹配「\(query)」的字体。")
                        .font(DS.Typo.ui(size: 12))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .padding(DS.Space.m)
                } else {
                    ForEach(visibleFamilies) { family in
                        row(for: family)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(for family: FontCatalog.Family) -> some View {
        let isSelected = selection == family.name
        return Button {
            selection = family.name
            isPresented = false
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: isSelected ? "checkmark" : "")
                    .font(DS.Typo.ui(size: 11, weight: .semibold))
                    .frame(width: 14)
                    .foregroundStyle(DS.Palette.accent)

                Text(family.name)
                    .font(DS.Typo.ui(size: 12))
                    .lineLimit(1)

                if family.supportsChinese {
                    Text("中文")
                        .font(DS.Typo.ui(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(DS.Palette.success.opacity(0.14))
                        )
                        .foregroundStyle(DS.Palette.success)
                }

                Spacer(minLength: DS.Space.s)

                // 用字体自己的样子写自己的名字，一眼看出是不是想要的调性
                Text("Aa 文")
                    .font(.custom(family.name, size: 13))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(FontRowButtonStyle(isSelected: isSelected))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(previewCaption)
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)

            Text(FontCatalog.previewText)
                .font(previewFont)
                .lineSpacing(3)
                .foregroundStyle(DS.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(DS.Palette.surfaceSunken)
        )
        .padding(DS.Space.m)
    }

    private var previewCaption: String {
        selection.map { "预览：\($0)" } ?? "预览：\(fallbackLabel)"
    }

    private var previewFont: Font {
        if let selection, !selection.isEmpty {
            return .custom(selection, size: 13)
        }
        return DS.Typo.ui(size: 13)
    }

    private var visibleFamilies: [FontCatalog.Family] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return FontCatalog.orderedFamilies(in: catalogGroup)
        }
        // 搜索时跨分组搜——用户想找的是"那款字体"，不关心它被归到哪一类。
        // 结果里支持中文的排前面：中英混排是这个应用的主要场景，排在后面等于让用户白翻。
        let needle = query.lowercased()
        return families
            .filter { $0.name.lowercased().contains(needle) }
            .sorted { lhs, rhs in
                if lhs.supportsChinese != rhs.supportsChinese { return lhs.supportsChinese }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

private struct FontRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Rectangle()
                    .fill(
                        configuration.isPressed
                            ? DS.Palette.accentSoft
                            : (isSelected ? DS.Palette.accentSoft.opacity(0.6) : .clear)
                    )
            )
    }
}

// MARK: - 分组映射

extension ReadingFontFamily {
    /// 与字体目录分组的对应关系。用来在打开选择器时定位到合理的初始分组。
    var catalogGroup: FontCatalog.Group {
        switch self {
        case .system:  return .sansSerif
        case .serif:   return .serif
        case .rounded: return .rounded
        case .mono:    return .monospaced
        }
    }
}
