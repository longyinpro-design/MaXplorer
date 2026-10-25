import SwiftUI

struct FilePropertyEditorView: View {
    let urls: [URL]
    let onChanged: () -> Void
    @StateObject private var model = FilePropertyEditorModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑权限与 Finder 标签").font(.headline)
            Text("仅修改下列明确启用的字段，共 \(urls.count) 项；目录仅修改自身，不递归。不会更改所有者或请求提权。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            if model.isLoading { ProgressView("读取原值…") }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.results.isEmpty {
                        ForEach(Array(model.results.enumerated()), id: \.offset) { _, result in
                            VStack(alignment: .leading) {
                                Text(result.url.path).textSelection(.enabled)
                                Text("已修改：" + (result.appliedFields.isEmpty ? "无" : result.appliedFields.map { field in
                                    switch field { case .permissions: return "权限"; case .tags: return "标签" }
                                }.joined(separator: "、")))
                                if let error = result.error { Text(error.localizedDescription).foregroundStyle(.red) }
                            }
                            Divider()
                        }
                    } else if !model.review.isEmpty {
                        Text("确认以下原值 → 新值后应用；目标或属性已变化会拒绝写入。").font(.headline)
                        ForEach(Array(model.review.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.snapshot.url.path).textSelection(.enabled)
                                if let value = change.permissions {
                                    Text("权限：\(FilePropertyEditorModel.octal(change.snapshot.permissions)) → \(FilePropertyEditorModel.octal(value))")
                                }
                                if let tags = change.tagNames {
                                    Text("原标签：\(labels(change.snapshot.tagNames))")
                                    Text("新标签：\(labels(tags))")
                                }
                            }
                            Divider()
                        }
                    } else {
                        ForEach($model.entries) { $entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.id.path).font(.headline).textSelection(.enabled)
                                if let error = entry.error { Text(error).foregroundStyle(.red) }
                                if let snapshot = entry.snapshot {
                                    Text("原权限：\(FilePropertyEditorModel.octal(snapshot.permissions))；原标签：\(labels(snapshot.tagNames))")
                                        .font(.callout).foregroundStyle(.secondary)
                                    HStack {
                                        Toggle("修改权限", isOn: $entry.editPermissions)
                                        TextField("新权限（八进制）", text: $entry.permissions).frame(width: 130)
                                            .disabled(!entry.editPermissions)
                                    }
                                    Toggle("替换标签列表", isOn: $entry.editTags)
                                    if entry.editTags {
                                        ForEach(entry.tags.indices, id: \.self) { index in
                                            HStack {
                                                TextField("标签名称（逗号属于名称）", text: $entry.tags[index])
                                                Button("移除") { entry.tags.remove(at: index) }
                                            }
                                        }
                                        Button("添加标签") { entry.tags.append("") }
                                        Text("每行一个标签；移除所有行会清空标签。保留的标签维持原颜色，新标签无颜色。")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textFieldStyle(.roundedBorder)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(model.results.isEmpty ? "取消" : "完成") { dismiss() }.disabled(model.isApplying)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isApplying { ProgressView().controlSize(.small); Text("正在应用…") }
                else if !model.review.isEmpty {
                    Button("返回编辑") { model.returnToEditing() }
                    Button("确认应用 \(model.review.count) 项") {
                        Task { await model.applyReviewed(); onChanged() }
                    }.buttonStyle(.borderedProminent)
                } else if model.results.isEmpty {
                    Button("检查变更…") { model.prepareReview() }.disabled(model.isLoading)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20).frame(width: 650, height: 600)
        .interactiveDismissDisabled(model.isApplying)
        .task { model.load(urls) }
        .onDisappear { model.cancelLoading() }
    }
    private func labels(_ tags: [String]) -> String {
        tags.isEmpty ? "无" : tags.map { "「\($0)」" }.joined(separator: "、")
    }
}
