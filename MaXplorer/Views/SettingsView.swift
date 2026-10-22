import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tabs: BrowserTabsViewModel

    var body: some View {
        Form {
            Section("外观") {
                Picker("明暗模式", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("主题配色", selection: $settings.colorTheme) {
                    ForEach(AppColorTheme.allCases) { colorTheme in
                        Text(colorTheme.settingsDisplayName)
                            .tag(colorTheme)
                    }
                }

                Toggle("交替显示文件列表行底色", isOn: $settings.showsBandedFileRows)

                HStack {
                    Text("文件夹图标样式")
                    Spacer()
                    Picker("文件夹图标样式", selection: $settings.folderIconStyle) {
                        ForEach(FolderIconStyle.allCases) { style in
                            Text(style.displayName)
                                .tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
            }

            Section("排序") {
                Picker("默认排序依据", selection: $settings.defaultSortColumn) {
                    ForEach(FileSortDescriptor.defaultSortColumns) { column in
                        Text(column.title).tag(column)
                    }
                }

                Picker("默认排序顺序", selection: $settings.defaultSortAscending) {
                    Text("升序").tag(true)
                    Text("降序").tag(false)
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("MaXplorer 会记住每个文件夹的排序方式。尚未设置排序的文件夹将使用默认值。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除文件夹排序记录") {
                        settings.forgetFolderSortChoices()
                        tabs.reapplyRememberedSorts()
                    }
                }
            }

            Section("工作区") {
                settingSlider(
                    title: "最多同时打开的标签页数",
                    value: $settings.maximumConcurrentTabs,
                    range: AppSettings.maximumConcurrentTabsRange
                )

                settingSlider(
                    title: "导航历史保留的文件夹数",
                    value: $settings.manualFolderHistoryLimit,
                    range: AppSettings.manualFolderHistoryLimitRange
                )
            }

            Section("空间分析") {
                Picker("默认模式", selection: $settings.defaultSpaceAnalyzerMode) {
                    ForEach(SpaceAnalyzerMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("“全部文件”模式显示完整的扫描层级。“逐层浏览”模式只显示当前文件夹的内容，可逐级打开文件夹查找空间占用较大的项目。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("文件传输") {
                settingSlider(
                    title: "最多同时进行的文件传输数",
                    value: $settings.maximumConcurrentCopiedFiles,
                    range: AppSettings.maximumConcurrentCopiedFilesRange
                )

                settingSlider(
                    title: "传输历史保留的记录数",
                    value: $settings.transferHistoryLimit,
                    range: AppSettings.transferHistoryLimitRange
                )
            }
        }
        .formStyle(.grouped)
        .padding(28)
        .frame(width: 620)
    }

    private func settingSlider(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
        }
        .padding(.vertical, 4)
    }
}
