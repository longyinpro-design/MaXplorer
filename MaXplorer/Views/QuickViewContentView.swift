import AppKit
import SwiftUI

struct QuickViewContentView: View {
    let content: QuickViewContent
    let onClose: () -> Void
    @State private var textEncoding: PreviewTextEncoding = .automatic
    @State private var decodedText: String?
    @State private var decodingError: String?
    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(content.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(content.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button("用默认应用打开") {
                    RecentFilesStore.shared.record(content.url)
                    if !NSWorkspace.shared.open(content.url) {
                        openError = "无法打开此文件，请确认已安装兼容的应用。"
                    }
                }

                Button("完成", action: onClose)
                    // Return belongs to the system preview's password field.
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .background(ThemedBarBackground())

            if content.isLegacyOfficeDocument {
                Text("部分旧版 Office 文件或加密方式可能无法正常预览。如果内容未显示，或已确认正确的密码仍被拒绝，请选择“用默认应用打开”。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            if content.allowsTextEncoding {
                Picker("文本编码", selection: $textEncoding) {
                    ForEach(PreviewTextEncoding.allCases) { encoding in
                        Text(encoding.displayName).tag(encoding)
                    }
                }
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Group {
                if textEncoding == .automatic {
                    FilePreviewView(url: content.url)
                } else {
                    ScrollView {
                        Text(decodedText ?? decodingError ?? "正在载入…")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemedContentBackground())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("无法打开文件", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("确定") { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .task(id: textEncoding) {
            decodedText = nil
            decodingError = nil
            guard let encoding = textEncoding.stringEncoding else { return }
            let url = content.url
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try PreviewTextDecoder.read(url, encoding: encoding)
                }.value
                try Task.checkCancellation()
                decodedText = text
            } catch {
                if !Task.isCancelled { decodingError = error.localizedDescription }
            }
        }
    }
}
