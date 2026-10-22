import AppKit
import SwiftUI
import SwiftTerm

@main
struct MaXplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var tabs = BrowserTabsViewModel()
    @StateObject private var settings = AppSettings()

    private var model: FileBrowserViewModel {
        tabs.activeModel
    }

    var body: some Scene {
        WindowGroup("MaXplorer") {
            ContentView()
                .environmentObject(tabs)
                .environmentObject(settings)
                .environment(\.appColorTheme, settings.colorTheme)
                .preferredColorScheme(settings.preferredColorScheme)
                .tint(settings.colorTheme.tintColor)
                .background(WindowAppearanceBridge(
                    colorScheme: settings.preferredColorScheme,
                    colorTheme: settings.colorTheme
                ))
                .frame(minWidth: 1120, minHeight: 620)
                .onAppear {
                    tabs.updateMaximumConcurrentTabs(settings.maximumConcurrentTabs)
                    tabs.applyListingOptions(DirectoryListingOptions(columns: settings.visibleColumns))
                }
                .onChange(of: settings.maximumConcurrentTabs) { _, maximumConcurrentTabs in
                    tabs.updateMaximumConcurrentTabs(maximumConcurrentTabs)
                }
                .onChange(of: settings.visibleColumns) { _, visibleColumns in
                    tabs.applyListingOptions(DirectoryListingOptions(columns: visibleColumns))
                }
                .onChange(of: settings.defaultSort) { _, _ in
                    tabs.reapplyRememberedSorts()
                }
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MaXplorer") {
                    model.showAbout()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    tabs.addTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!tabs.canAddTab)

                Button("Duplicate Tab") {
                    tabs.duplicateTab(tabs.selectedTabID)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!tabs.canAddTab)

                Divider()

                Button("Open") {
                    model.openSelected()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.selectedItem == nil)

                Button("Quick View") {
                    model.quickViewSelectedItem()
                }
                .disabled(!model.canQuickViewSelectedItem)

                Button("New Folder") {
                    Task { await model.createFolder() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canCreateFolder)

                Divider()

                Button("Rename") {
                    model.requestRenameSelected()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedItem?.isNetworkLocation ?? true)

                Button(model.selectedItemsRequirePermanentDeletion ? "Delete Permanently" : "Move to Trash") {
                    model.requestTrashSelected()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canTrashSelectedItems)

                Divider()

                Button("Add to Favorites") {
                    model.pinSelectedFolderToFavorites()
                }
                .disabled(!(model.selectedItem.map(model.canPinFolder) ?? false))

                Divider()

                Button("Reveal in Finder") {
                    model.revealSelectedInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    if let terminal = focusedTerminal {
                        terminal.copy(self)
                    } else {
                        model.copySelectedItem()
                    }
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Cut") {
                    model.cutSelectedItem()
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!model.canCutSelectedItem)

                Button("Paste") {
                    if let terminal = focusedTerminal {
                        terminal.paste(self)
                    } else {
                        model.pasteItems(maximumConcurrentCopies: settings.maximumConcurrentCopiedFiles)
                    }
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("Select All") {
                    model.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!model.canSelectAll)

                Button("Copy Path") {
                    model.copySelectedPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }

            CommandMenu("View") {
                Button("Filter Items") {
                    model.focusFilterField()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Divider()

                Button("Reload") {
                    model.reload()
                }
                .keyboardShortcut("r", modifiers: .command)

                Toggle("Show Hidden Files", isOn: $tabs.showHiddenFiles)
                    .keyboardShortcut(".", modifiers: [.command, .shift])

                Toggle("Show Aliases", isOn: $tabs.showAliases)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            CommandMenu("Tabs") {
                Button("Select Next Tab") {
                    tabs.selectNextTab()
                }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(!tabs.canCycleTabs)

                Button("Select Previous Tab") {
                    tabs.selectPreviousTab()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(!tabs.canCycleTabs)
            }

            CommandMenu("Go") {
                Button("Back") {
                    model.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)

                Button("Forward") {
                    model.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)

                Button("Enclosing Folder") {
                    model.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUp)

                Button("Go to Folder...") {
                    model.showGoToFolder()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("Home") {
                    model.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Downloads") {
                    model.navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                }

                Divider()

                Button("Connect to Server") {
                    model.showConnectToServer()
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("Tools") {
                Toggle("Integrated Terminal", isOn: Binding(
                    get: { model.isIntegratedTerminalPresented },
                    set: { model.isIntegratedTerminalPresented = $0 }
                ))
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(!model.currentURL.isFileURL)

                Divider()

                Button("Open in Terminal") {
                    model.openSelectedInTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Copy Path") {
                    model.copySelectedPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }

            CommandGroup(after: .help) {
                Button("MaXplorer README") {
                    model.showReadme()
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(tabs)
                .environmentObject(settings)
                .environment(\.appColorTheme, settings.colorTheme)
                .preferredColorScheme(settings.preferredColorScheme)
                .tint(settings.colorTheme.tintColor)
                .background(WindowAppearanceBridge(
                    colorScheme: settings.preferredColorScheme,
                    colorTheme: settings.colorTheme
                ))
        }
    }

    private var focusedTerminal: TerminalView? {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if let terminal = current as? TerminalView {
                return terminal
            }
            responder = current.nextResponder
        }
        return nil
    }
}

private struct WindowAppearanceBridge: NSViewRepresentable {
    let colorScheme: ColorScheme
    let colorTheme: AppColorTheme

    func makeNSView(context: Context) -> WindowAppearanceView {
        WindowAppearanceView(colorScheme: colorScheme, colorTheme: colorTheme)
    }

    func updateNSView(_ nsView: WindowAppearanceView, context: Context) {
        guard nsView.colorScheme != colorScheme || nsView.colorTheme != colorTheme else { return }
        nsView.colorScheme = colorScheme
        nsView.colorTheme = colorTheme
    }
}

private final class WindowAppearanceView: NSView {
    var colorScheme: ColorScheme {
        didSet {
            applyAppearance()
        }
    }
    var colorTheme: AppColorTheme {
        didSet {
            applyAppearance()
        }
    }

    init(colorScheme: ColorScheme, colorTheme: AppColorTheme) {
        self.colorScheme = colorScheme
        self.colorTheme = colorTheme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    private func applyAppearance() {
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if window?.appearance?.name != appearanceName {
            window?.appearance = NSAppearance(named: appearanceName)
        }

        guard let window else { return }
        // Always transparent: with an opaque titlebar, NavigationSplitView's NSSplitView
        // draws a titlebar-height background (NSTitlebarBackgroundView) across the top of
        // the detail column. Our tab strip pushes the split view below the real titlebar,
        // so that band covers the browser toolbar. backgroundColor still tints the titlebar.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = titlebarBackgroundColor
    }

    private var titlebarBackgroundColor: NSColor {
        let base = colorScheme == .dark
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)

        let accent: NSColor
        switch colorTheme {
        case .default: return base
        case .water: accent = .systemBlue
        case .earth: accent = .systemGreen
        case .fire: accent = .systemOrange
        case .air: accent = .systemGray
        }

        let fraction: CGFloat = colorTheme == .air ? 0.10 : 0.16
        return base.blended(withFraction: fraction, of: accent) ?? base
    }
}
