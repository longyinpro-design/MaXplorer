import AppKit
import SwiftUI

/// Bundle-derived app metadata shown on the About surface.
enum AppInfo {
    static let name: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "MaXplorer"
    }()

    static let shortVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }()

    static let buildNumber: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }()

    static var versionSummary: String {
        "版本 \(shortVersion)（\(buildNumber)）"
    }

    static let tagline = "原生 macOS 文件管理器，结合 Windows 资源管理器式导航与现代 Mac 操作体验。"
}

/// Modern, glass-forward About surface rendered directly on the main app
/// canvas (not a separate window). Includes a button that opens the bundled
/// changelog in a popup sheet.
struct AboutView: View {
    @EnvironmentObject private var model: FileBrowserViewModel
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isChangelogPresented = false
    @State private var isReadmePresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                actions

                Text("MaXplorer · 作者：Adi Sapir（github.com/adisapir）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop)
        .sheet(isPresented: $isChangelogPresented) {
            ChangelogSheet {
                isChangelogPresented = false
            }
        }
        .sheet(isPresented: $isReadmePresented) {
            ReadmeSheet {
                isReadmePresented = false
            }
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            ShiningAppIcon(size: 132)

            VStack(spacing: 8) {
                Text(AppInfo.name)
                    .font(.system(size: 40, weight: .bold, design: .rounded))

                Text(AppInfo.versionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())

                Text(AppInfo.tagline)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Button {
                isChangelogPresented = true
            } label: {
                Label("查看更新记录", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            Button {
                isReadmePresented = true
            } label: {
                Label("使用说明", systemImage: "doc.text")
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            Button {
                model.dismissAuxiliaryDetail()
            } label: {
                Text("确定")
                    .font(.headline)
                    .frame(minWidth: 64)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [colorTheme.backdropTint(for: colorScheme), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// The About header app icon with a periodic diagonal shine sweep, masked to
/// the icon artwork so the highlight only travels across the icon itself.
private struct ShiningAppIcon: View {
    let size: CGFloat
    @State private var sweep = false

    var body: some View {
        Image(nsImage: AppInfo.iconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay { shine }
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false).delay(0.6)) {
                    sweep = true
                }
            }
    }

    private var shine: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.75), location: 0.5),
                    .init(color: .white.opacity(0), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width * 0.45, height: proxy.size.height * 1.6)
            .rotationEffect(.degrees(22))
            .offset(x: sweep ? width * 1.25 : -width * 1.25)
            .blendMode(.screen)
        }
        .mask(
            Image(nsImage: AppInfo.iconImage)
                .resizable()
                .interpolation(.high)
        )
        .allowsHitTesting(false)
    }
}

extension AppInfo {
    /// The runtime-generated Dock/Finder icon, reused for the About header.
    static let iconImage: NSImage = AppIconFactory.makeIcon()
}

/// Loads the bundled `ChangeLog.md` copied in by a build phase.
enum ChangelogLoader {
    static func load() -> String {
        guard let url = Bundle.main.url(forResource: "ChangeLog-zh", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "# 更新记录\n\n此构建未附带更新记录。"
        }

        return contents
    }
}

/// Popup window (sheet) that renders the changelog markdown.
private struct ChangelogSheet: View {
    let onClose: () -> Void

    private let entries: [ChangelogLine] = ChangelogParser.parse(ChangelogLoader.load())

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)

                Text("更新记录")
                    .font(.headline)

                Spacer(minLength: 16)

                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(ThemedBarBackground())

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { line in
                        ChangelogLineView(line: line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(ThemedContentBackground())
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(
            ResizableSheetWindowBridge(minSize: NSSize(width: 560, height: 460))
        )
    }
}

private struct ChangelogLineView: View {
    let line: ChangelogLine

    var body: some View {
        switch line.kind {
        case .title:
            Text(line.text)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .padding(.bottom, 2)
        case .section:
            Text(line.text)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                Text(line.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
        case .body:
            Text(line.text)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

struct ChangelogLine: Identifiable {
    enum Kind {
        case title
        case section
        case bullet
        case body
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// Minimal, changelog-focused markdown parser: handles `#`/`##` headings and
/// `-`/`*` bullets, treating everything else as body text.
enum ChangelogParser {
    static func parse(_ markdown: String) -> [ChangelogLine] {
        markdown
            .components(separatedBy: .newlines)
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else {
                    return nil
                }

                if line.hasPrefix("## ") {
                    return ChangelogLine(kind: .section, text: String(line.dropFirst(3)))
                }
                if line.hasPrefix("# ") {
                    return ChangelogLine(kind: .title, text: String(line.dropFirst(2)))
                }
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return ChangelogLine(kind: .bullet, text: String(line.dropFirst(2)))
                }

                return ChangelogLine(kind: .body, text: line)
            }
    }
}

/// Loads the bundled `README.md` copied in by a build phase.
enum ReadmeLoader {
    static func load() -> String {
        guard let url = Bundle.main.url(forResource: "Help-zh", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "# 使用说明\n\n此构建未附带使用说明。"
        }
        return contents
    }
}

/// Popup sheet that renders the README with proper Markdown formatting.
struct ReadmeSheet: View {
    let onClose: () -> Void

    private let markdown: String = ReadmeLoader.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)

                Text("使用说明")
                    .font(.headline)

                Spacer(minLength: 16)

                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(ThemedBarBackground())

            ScrollView {
                MarkdownDocumentView(markdown: markdown)
                    .padding(20)
            }
            .background(ThemedContentBackground())
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(
            ResizableSheetWindowBridge(minSize: NSSize(width: 640, height: 520))
        )
    }
}

/// Applies normal macOS window resizing to a SwiftUI sheet while preserving
/// the viewer's minimum usable content size.
