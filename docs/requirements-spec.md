# MaXplorer Requirements Specification

Version: 0.2
Date: 2026-06-14
Status: Implementation-aligned draft

## 1. Product Summary

MaXplorer is a native macOS file manager for users who find Finder slow, ambiguous, or inefficient for everyday file work. It should feel familiar to Windows Explorer users while still looking and behaving like a modern Mac app.

The first product goal is not to replace every Finder capability. The goal is to make high-frequency file workflows faster and clearer: folder navigation, network drive access, file operations, local and network search, path handling, terminal access, and repeatable copy/move/rename tasks.

## 2. Problem Statement

Finder is polished for light use, but public user reports and Finder-alternative coverage show recurring pain around:

- Search reliability and search context. Users report Finder failing to find visible files, depending heavily on Spotlight indexing, and producing confusing differences between "current folder" and broader searches.
- Large folder performance. Users report slow loading, laggy previews, and poor behavior with folders containing thousands of files, especially photos or network-backed folders.
- Network shares. SMB browsing and searching can be much slower than terminal equivalents, with poor transparency about whether the app is loading, indexing, filtering, or blocked.
- File operation visibility. Copy, move, delete, rename, archive, and conflict handling need clearer queues, progress, retry, pause, and undo behavior.
- Navigation ergonomics. Windows Explorer-style users expect a persistent tree, address/path bar, tabs, split panes, keyboard-first navigation, and obvious "open here in Terminal" actions.

## 3. Target Users

- Windows-to-Mac switchers who miss File Explorer's visible folder tree, address bar, and predictable keyboard workflows.
- Power users who frequently move files across local folders, external drives, network shares, and cloud-synced folders.
- Developers and technical users who often need to open a folder in Terminal, copy a path, or locate files by name quickly.
- Small office users who rely on shared SMB/network locations and need reliable filename search without teaching users terminal commands.

## 4. Product Principles

- Native first: use macOS conventions, accessibility, sandboxing, security-scoped bookmarks, Quick Look, context menus, and system file metadata where possible.
- Explorer familiarity: persistent sidebar/tree, visible path/address bar, tabs, split view, keyboard navigation, and explicit operations.
- Predictability over magic: distinguish search from filter, show what scope is active, expose permissions/indexing/network limitations, and make operation status visible.
- Performance transparency: large folders and network drives should show progressive loading and useful partial results instead of freezing the UI.
- Safety by default: destructive actions need undo or clear confirmation. File operations must preserve metadata where possible and report failures precisely.

## 5. Core Workflows

### 5.1 Browse Local Folders

Users can open the app and browse Home, Desktop, Documents, Downloads, external drives, mounted volumes, and custom pinned locations.

Requirements:

- Show a left navigation area with favorites, drives, network locations, recent folders, and an optional expandable folder tree.
- Show a main file list with columns for name, kind, size, modified date, permissions/status, and optional tags.
- Support list view as the MVP default. Icon/grid and column views can come later.
- Support Back, Forward, Up, Reload, Home, path/address entry, and breadcrumb navigation.
- Support tabs for multiple locations.
- Support split pane mode for source/destination work.
- Preserve view state per folder where practical, without making layout unpredictable.

Acceptance criteria:

- Opening common folders is interactive within 500 ms after app launch on a typical local SSD.
- Navigating to a folder with 10,000 files does not freeze the window. File rows load progressively.
- The current folder path is always visible and copyable.

### 5.2 File Operations

Users can create, copy, move, rename, duplicate, delete, restore, compress, extract, and reveal files.

Requirements:

- Support drag-and-drop copy/move within and across panes.
- Support toolbar and context menu actions for New Folder, Rename, Copy, Cut, Paste, Duplicate, Move to Trash, Delete Immediately, Compress, Get Info, Open With, Reveal in Finder, and Open in Terminal.
- Show an operation queue with progress, transfer speed, remaining time, current item, and error count.
- Support pause, resume, cancel, retry, and reveal destination for long-running operations.
- Detect conflicts and support Replace, Keep Both, Skip, Apply to All, and Compare basic metadata.
- Preserve extended attributes, resource forks, permissions, timestamps, aliases/symlinks, and package-directory semantics where possible.
- Use Trash by default for deletes on supported volumes. Fall back to permanent delete only with explicit confirmation.

Acceptance criteria:

- Copying or moving a folder continues even when a single item fails, then reports failed items.
- Rename works from keyboard and context menu without losing selection.
- Users can undo recent local rename, move-to-trash, and move operations where macOS APIs allow it.

### 5.3 Search and Filter

Users can quickly find files by name and refine the visible contents of the current folder.

Requirements:

- Separate "Filter current folder" from "Search location" in the UI.
- Filter current folder should operate on visible/current folder contents without relying on Spotlight.
- Search should support:
  - Current folder
  - Current folder recursively
  - This Mac
  - Selected volume
  - Selected network location
- Search modes:
  - Filename contains
  - Exact filename
  - Extension
  - Kind/category
  - Date modified range
  - Size range
  - Optional content search for supported/indexed locations
- Show whether results come from direct filesystem traversal, Spotlight metadata, cached index, or network traversal.
- Allow users to stop a search and keep partial results.
- Provide clear empty states that explain scope and limitations, especially for hidden/system folders, permissions, packages, and cloud placeholders.

Acceptance criteria:

- Filename filter in the current folder updates results in under 150 ms for 10,000 already loaded items.
- Filename search can find a file in the current folder without depending solely on Spotlight.
- Network search reports progress and partial results instead of appearing stuck.

### 5.4 Network Drives and Remote Locations

Users can connect to, browse, pin, and search network shares.

Requirements:

- Support mounted volumes shown by macOS.
- Provide a "Connect to Server" flow for SMB URLs in the MVP if feasible.
- Persist trusted locations using security-scoped bookmarks or macOS-supported equivalents.
- Detect offline/unavailable locations and show reconnect actions.
- Keep network operations cancellable.
- Avoid eager thumbnail/content loading on network locations by default.
- Use lazy metadata loading and progressive directory enumeration.

Acceptance criteria:

- A slow SMB folder does not block the rest of the app.
- Users can pin a network location and see whether it is connected.
- Searching a network location shows scanned count, result count, elapsed time, and cancel control.

### 5.5 Terminal and Developer Workflows

Users can open the current folder, selected folder, or selected file's parent folder in Terminal.

Requirements:

- Support Open in Terminal for current path and selected items.
- Support copying paths in POSIX, shell-escaped POSIX, file URL, and relative-to-current-root formats.
- Support "Open in Editor" as a later setting-driven feature.
- Support optional command palette for keyboard-driven actions.

Acceptance criteria:

- Open in Terminal launches the user's default Terminal app where possible.
- Copy Path actions work for filenames with spaces and special shell characters.

## 6. MVP Scope

The MVP should include:

- Native macOS desktop app.
- Sidebar with standard locations, mounted volumes, favorites, and basic folder tree.
- Main list view with sortable columns.
- Path/address bar and breadcrumbs.
- Tabs.
- Split pane mode.
- Core file operations: new folder, rename, copy, move, duplicate, trash, permanent delete with confirmation.
- Operation queue with progress and error reporting.
- Current-folder filter and recursive filename search.
- Mounted volume and basic SMB mounted-share support.
- Open in Terminal and copy path actions.
- Basic settings: startup location, default search scope, show hidden files, confirm destructive actions, network preview behavior.

Not in MVP:

- Full Finder replacement at OS integration level.
- iCloud/Dropbox/OneDrive provider-specific sync controls.
- Advanced duplicate finder.
- Custom file preview engine beyond system Quick Look.
- Full archive manager.
- Git client features beyond path/editor/terminal convenience.
- Admin/root file browser mode.

## 7. User Interface Requirements

Layout:

- Top toolbar: Back, Forward, Up, Reload, New Folder, Split Pane toggle, View menu, Search/Filter entry, Settings.
- Address area: editable path bar with breadcrumb fallback.
- Left sidebar: Favorites, Devices, Network, Recent, optional folder tree.
- Main pane: file table.
- Optional right details/preview inspector for selected item.
- Bottom/status area: selected count, total count, current path status, active task indicator.
- Operation center: popover or panel for copy/move/search tasks.

Behavior:

- Keyboard shortcuts should follow macOS conventions where they exist.
- Explorer-familiar shortcuts can be supported where they do not conflict.
- Enter should be configurable: default macOS behavior can rename, but Explorer mode can open.
- Space opens Quick Look.
- Command+Shift+. toggles hidden files.
- Command+L focuses path entry.
- Command+F focuses search.
- Command+Option+F focuses filter.

Visual direction:

- Modern macOS, not a Windows skin.
- Dense, practical file-management UI.
- High contrast enough for long work sessions.
- Clear focus rings, selection states, and inactive pane states.
- Avoid decorative surfaces that reduce information density.

## 8. Nonfunctional Requirements

Performance:

- App launch to usable shell: under 1 second on Apple Silicon development target.
- Local folder first visible rows: under 300 ms for common folders.
- Large local folders: progressive display and no main-thread blocking.
- Network folders: cancellable work and no global UI blocking.

Reliability:

- File operations must be resumable or at least recoverable through clear error reporting.
- The app should never silently skip failed files.
- The app should not modify file metadata unless an operation requires it.

Security and privacy:

- Follow macOS sandbox and file permission models.
- Request only required entitlements.
- Store bookmarks and settings securely.
- No telemetry in MVP unless explicitly added later.

Accessibility:

- Full keyboard navigation for file list, sidebar, toolbar, dialogs, and operation center.
- VoiceOver labels for actions and file metadata.
- Dynamic Type or system font scaling where feasible.
- Respect Reduce Motion and system appearance.

Compatibility:

- Target current supported macOS versions at build time.
- Initial technical assumption: Swift, SwiftUI for app structure, AppKit where needed for advanced file list behavior, drag/drop, menus, Quick Look, and file operation integration.

## 9. Data and State

Persist:

- Favorites and pinned locations.
- Recent locations.
- Open tabs and last session, configurable.
- View preferences.
- Search/filter preferences.
- Operation history summary for recent tasks.

Do not persist:

- Sensitive credentials.
- Full directory snapshots by default.
- Search content indexes unless a later feature explicitly introduces local indexing with user consent.

## 10. Risks and Constraints

- macOS sandbox permissions may complicate broad filesystem access. We need to decide early whether the app is sandboxed for App Store compatibility or distributed outside the App Store with broader access.
- Finder-level OS integration is limited. MaXplorer can be an alternative app, but cannot fully replace all Finder behaviors system-wide.
- SMB behavior depends on macOS networking APIs, server configuration, permissions, and indexing availability.
- Preserving all metadata across volumes is nontrivial and needs focused testing.
- Large-folder performance requires careful background enumeration, lazy metadata loading, and main-thread discipline.
- Search must avoid overpromising. Some folders may be inaccessible or intentionally excluded.

## 11. Initial Technical Recommendations

- Start with a Swift Package plus macOS app target once the app project is created.
- Use a view model around a filesystem service so directory enumeration, search, and operations are testable outside UI.
- Prefer asynchronous APIs and Operation/Task-backed queues for copy/move/search.
- Build the file table with AppKit integration if SwiftUI Table cannot meet performance and keyboard requirements.
- Treat network paths as a first-class source type with explicit loading policy.
- Add performance fixtures early: local folders with 1,000, 10,000, and 50,000 generated files; mounted external or test SMB share when available.

## 12. Planning Backlog

P0:

- Create native macOS project skeleton.
- Implement shell layout: sidebar, toolbar, path bar, file list.
- Implement local folder enumeration and basic navigation.
- Implement current-folder filter.
- Implement rename, new folder, trash.

P1:

- Tabs and split pane.
- Copy/move operation queue.
- Conflict handling.
- Recursive filename search.
- Open in Terminal and copy path formats.
- Favorites/pinned locations.

P2:

- Mounted volumes and network share polish.
- Search progress and partial result UX.
- Quick Look/details inspector.
- Settings.
- Accessibility pass.

P3:

- SMB connect flow.
- Archive actions.
- Batch rename.
- Customizable keyboard shortcuts.
- Open in editor.
- Optional command palette.

## 13. Open Decisions

- Which Terminal apps should be supported in MVP: Terminal.app only, iTerm2, Warp, configurable?


## 14. Resolved Decisions
- Distribution target: Open Source. Later on - AppStore/directo download
- Minimum macOS version: MacOS 15
- Default Enter key behavior: first-run choice. (rename like Finder, open like Explorer) -> can be modified in configuration laters
- Dual-pane is off by default default - optional from toolbar
- MaXplorer will keep search direct/Spotlight-based for MVP. Later on this might change to a build a local filename index.
- "Open in Finder" should exist as an escape hatch for every location

## 15. Current Implementation Snapshot

As of 2026-06-14, the app implements the following behavior.

Navigation and shell:

- Native SwiftUI macOS app distributed as a Swift Package executable.
- Sidebar with Favorites, Devices, Network, removable built-in favorites, custom pinned folders, and drag-to-pin support.
- Network entry points for mounted remote volumes, discovered network locations, and Connect to Server.
- Tab strip with configurable maximum tab count and keyboard tab cycling.
- Back, Forward, Up, Reload, Home, Downloads, Go to Folder, and editable path entry.
- Current path status and copy-path support.

File list:

- Main table view with Name, Kind, Size, and Modified columns.
- Sortable columns using SwiftUI table sort descriptors.
- Current-folder text filter that operates on loaded items without Spotlight.
- Multi-selection through table selection, row click targets, and range/toggle selection behavior.
- Modern file, folder, package, alias-folder, volume, and network icons.
- Cut items are visually dimmed until moved or cleared.

File actions:

- Open selected folders inside MaXplorer, including alias folders resolved to their target.
- Open selected non-folder items with the system default application.
- Context menu actions for Open, Quick View, Open With, Cut, Copy, Rename, Move to Trash, Add to Favorites, Copy Path, Open in Terminal, and Reveal in Finder.
- Quick View displays local files in an app popup using macOS Quick Look. It passes the original file URL to the system provider, preserving document/image formats and text encoding instead of filtering bytes into ASCII. Unsupported formats use the system fallback; Automatic mode delegates loading to the system without the former 10 MB cap. Plain text and source files also offer explicit UTF-8, UTF-16, GB18030/GBK and Big5 decoding for ambiguous encodings, bounded to a 10 MB read and reporting invalid bytes without stripping them.
- With keyboard focus in the file list, plain Space opens Quick View for the selected previewable file. Clicking a file transfers keyboard focus to the list; Space in text fields or other surfaces remains normal input.
- Open With lists applications returned by macOS for the selected item and opens the item with the chosen application.
- New Folder, Rename, Move to Trash, copy, cut, and paste.
- Copy queue with progress, speed, ETA, cancellation, copy conflict detection, overwrite/skip/cancel choices, and configurable concurrency.
- Cut and paste moves files using Command+X and Command+V.
- Move to Trash supports multiple selected local items and uses the system Trash.

Toolbar and commands:

- Toolbar groups for navigation, create folder, Terminal, reveal in Finder, connect to server, filter, path entry, and copy path.
- Custom topmost tooltip window with 0.5 second hover delay and light/dark color adaptation.
- Main menu commands for file actions, pasteboard actions, view toggles, tab selection, navigation, and tools.
- Keyboard shortcuts documented in the README.

Settings and persistence:

- Settings window available from the standard app Settings menu.
- Appearance setting supports Match System Settings, Light, and Dark.
- Configurable maximum concurrent tabs.
- Configurable Go to Folder history limit and persisted Go to Folder history.
- Configurable maximum concurrent copied files.
- Favorites, removed built-in favorites, and settings persist through UserDefaults.

Platform behavior:

- Minimum macOS target is macOS 15.
- macOS 26 glass styling is applied behind availability checks.
- Terminal opens at the selected folder/file parent or current folder and activates Terminal when possible.
- Finder is used as an escape hatch through Reveal in Finder.

Known implementation gaps:

- Finder's exact Open With grouping, ordering, icons, and recommended/default-app labeling are not fully reproduced in SwiftUI menus; the app uses macOS application resolution instead.
- Split pane, recursive search, advanced file operation undo, duplicate, compress/extract, permanent delete, pause/resume/retry, and full Quick Look integration remain future work.

## 16. Research Notes

Sources reviewed during this draft:

- Apple Community: Finder search can fail to find visible files and users are often pushed toward Spotlight reindexing or terminal commands: https://discussions.apple.com/thread/255244980
- Apple Community: Finder search scope and indexing limitations can make empty results ambiguous: https://discussions.apple.com/thread/256095170
- Apple Community: large folders and SMB-backed folders can produce severe Finder performance complaints: https://discussions.apple.com/thread/256205645
- Apple Community: SMB filename search can be much slower in Finder than command-line listing/filtering: https://discussions.apple.com/thread/250798695
- Windows Central on Files v4.0: useful product patterns include dual pane, separating search from filter, status center, open in terminal, and command/developer actions: https://www.windowscentral.com/software-apps/files-v4-ultimate-file-explorer-replacement-windows-11
- How-To Geek Finder alternatives overview: common differentiators include dual-pane workflows, clickable file trees, sync, remote/cloud support, and power-user navigation: https://www.howtogeek.com/best-finder-alternatives-for-mac/
