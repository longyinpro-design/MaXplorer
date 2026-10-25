import SwiftUI

struct SearchConditionsBar: View {
    @ObservedObject var model: FileBrowserViewModel
    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { isPresented = true } label: {
                    Label("筛选条件…", systemImage: "line.3.horizontal.decrease.circle")
                }
                Text(model.searchFilters.isActive || model.searchUsesIndex ? "已启用组合条件（同时满足）" : "可按类型、扩展名、大小、日期和内容筛选")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.searchFilters.isActive || model.searchUsesIndex {
                    Button("清除条件") { model.applySearchConditions(SearchFilters(), contentQuery: "") }
                }
            }
            if model.searchUsesIndex {
                Text("内容结果来自系统索引。未索引、不支持或尚未更新的文件可能遗漏；零结果不代表所有文件均无匹配。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .sheet(isPresented: $isPresented) {
            SearchConditionsSheet(filters: model.searchFilters, contentQuery: model.searchContentQuery) { filters, content in
                model.applySearchConditions(filters, contentQuery: content)
                isPresented = false
            } onCancel: { isPresented = false }
        }
    }
}

private struct SearchConditionsSheet: View {
    let onApply: (SearchFilters, String) -> Void
    let onCancel: () -> Void
    @State private var kind: SearchFilters.Kind
    @State private var extensions: String
    @State private var minimumSize: String
    @State private var maximumSize: String
    @State private var contentQuery: String
    @State private var createdAfterEnabled: Bool
    @State private var createdBeforeEnabled: Bool
    @State private var modifiedAfterEnabled: Bool
    @State private var modifiedBeforeEnabled: Bool
    @State private var createdAfter: Date
    @State private var createdBefore: Date
    @State private var modifiedAfter: Date
    @State private var modifiedBefore: Date
    @State private var error: String?

    init(filters: SearchFilters, contentQuery: String, onApply: @escaping (SearchFilters, String) -> Void, onCancel: @escaping () -> Void) {
        self.onApply = onApply
        self.onCancel = onCancel
        _kind = State(initialValue: filters.kind)
        _extensions = State(initialValue: filters.extensions.sorted().joined(separator: ", "))
        _minimumSize = State(initialValue: filters.minimumSize.map { String($0 / 1_048_576) } ?? "")
        _maximumSize = State(initialValue: filters.maximumSize.map { String($0 / 1_048_576) } ?? "")
        _contentQuery = State(initialValue: contentQuery)
        _createdAfterEnabled = State(initialValue: filters.createdAfterInclusive != nil)
        _createdBeforeEnabled = State(initialValue: filters.createdBeforeExclusive != nil)
        _modifiedAfterEnabled = State(initialValue: filters.modifiedAfterInclusive != nil)
        _modifiedBeforeEnabled = State(initialValue: filters.modifiedBeforeExclusive != nil)
        _createdAfter = State(initialValue: filters.createdAfterInclusive ?? Date())
        _createdBefore = State(initialValue: Self.inclusiveEnd(filters.createdBeforeExclusive))
        _modifiedAfter = State(initialValue: filters.modifiedAfterInclusive ?? Date())
        _modifiedBefore = State(initialValue: Self.inclusiveEnd(filters.modifiedBeforeExclusive))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("搜索条件").font(.title2.bold())
            Text("名称、内容及已启用的属性条件同时满足才返回。扩展名之间满足任意一项即可。")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Picker("类型", selection: $kind) {
                    Text("任意").tag(SearchFilters.Kind.any)
                    Text("文件").tag(SearchFilters.Kind.files)
                    Text("文件夹").tag(SearchFilters.Kind.folders)
                    Text("软件包").tag(SearchFilters.Kind.packages)
                }
                TextField("扩展名（逗号分隔）", text: $extensions, prompt: Text("例如 jpg, png, pdf"))
                HStack {
                    TextField("最小大小（MiB）", text: $minimumSize)
                    TextField("最大大小（MiB）", text: $maximumSize)
                }
                Text("大小接受非负整数，包含上下限；留空表示不限。文件夹和未知大小不满足大小条件。")
                    .font(.caption).foregroundStyle(.secondary)
                dateRow("创建开始", enabled: $createdAfterEnabled, date: $createdAfter)
                dateRow("创建结束", enabled: $createdBeforeEnabled, date: $createdBefore)
                dateRow("修改开始", enabled: $modifiedAfterEnabled, date: $modifiedAfter)
                dateRow("修改结束", enabled: $modifiedBeforeEnabled, date: $modifiedBefore)
                Text("日期按本地日历，包含结束当天；日期未知的项目不满足相应条件。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("文件内容（系统索引）", text: $contentQuery, prompt: Text("留空仅搜索名称和属性"))
                Text("内容依赖 Spotlight 已有索引，仅在所选范围内查询，不上传文件。未索引或不支持的格式可能遗漏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("应用条件", action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 660)
    }

    private func dateRow(_ title: String, enabled: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack {
            Toggle(title, isOn: enabled).toggleStyle(.checkbox).frame(width: 100, alignment: .leading)
            DatePicker(title, selection: date, displayedComponents: .date).labelsHidden().disabled(!enabled.wrappedValue)
        }
    }

    private static func inclusiveEnd(_ exclusive: Date?) -> Date {
        exclusive.flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) } ?? Date()
    }

    private func apply() {
        do {
            var filters = SearchFilters()
            filters.kind = kind
            filters.extensions = try SearchFilters.parseExtensions(extensions)
            filters.minimumSize = try SearchFilters.parseSizeMiB(minimumSize)
            filters.maximumSize = try SearchFilters.parseSizeMiB(maximumSize)
            let calendar = Calendar.current
            func start(_ date: Date) -> Date { calendar.startOfDay(for: date) }
            func end(_ date: Date) throws -> Date {
                guard let result = calendar.date(byAdding: .day, value: 1, to: start(date)) else {
                    throw SearchFilters.ValidationError.invalidDateRange
                }
                return result
            }
            filters.createdAfterInclusive = createdAfterEnabled ? start(createdAfter) : nil
            filters.createdBeforeExclusive = createdBeforeEnabled ? try end(createdBefore) : nil
            filters.modifiedAfterInclusive = modifiedAfterEnabled ? start(modifiedAfter) : nil
            filters.modifiedBeforeExclusive = modifiedBeforeEnabled ? try end(modifiedBefore) : nil
            try filters.validate()
            onApply(filters, contentQuery)
        } catch { self.error = error.localizedDescription }
    }
}
