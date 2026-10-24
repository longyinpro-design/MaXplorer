# Change Log

## 2026-10-24 — v1.11

- Added recursive filename search for the current folder or volume, with substring and wildcard masks, live progress, cancellation, and a Search & Select command that highlights matches in the browser without changing the listing.
- Added Duplicate, Get Info, New File, Copy To and Move To, all routed through the transactional file operations stack.
- Added ZIP and TAR.GZ compression plus extraction of zip, tar, gz, bz2 and their tar variants into a new folder, with progress and error reporting.
- Added a transfer plan preview before moves and copies that reports space requirements, naming conflicts and permission problems before anything is written.
- Added pause, resume, retry and retry-all to the copy queue, including per-item progress and cancellation that leaves existing destinations intact.
- Added an undo journal for renames, moves and non-overwriting copies: ⌘Z restores the last operation, a whole batch undoes as one step, undo is refused when the files changed or the original location is occupied, copies are removed through the Trash, and overwriting operations are marked as not undoable instead of pretending. Edit → Undo History lists the last 20 operations and explains that history is cleared when MaXplorer quits.
- Hardened moves and copies on SMB, exFAT and space-constrained volumes with volume capability probing, ENOSPC preflight, disconnection handling and a startup scan for leftover staging and backup files.

## 2026-10-23 — v1.10

- Localized the interface into Simplified Chinese, including menus, settings, Space Analyzer, Copy Queue, and preview windows.
- Improved Quick View with Quick Look previews, explicit text encodings, legacy Office warnings, reliable password submission, and better window resizing and placement across displays.
- Made copies and moves transactional: files are staged privately, verified, then published atomically while preserving permissions, ACLs, extended attributes, resource forks, and timestamps. Cancellation or failure keeps the original destination intact.
- Significantly improved large-folder browsing: rows appear progressively, sorting and filtering run off the main actor, type descriptions are cached per extension, and icons and volume information load asynchronously.
- Parallelized Space Analyzer scans with bounded concurrency and optimized treemap layout, including smoother window resizing for large scans.

## 2026-10-13 — v1.09

- Added Finder tag color dots to file and folder icons.
- Remembered sort order per folder, with a configurable default sort field and order in Settings.
- Added a native column header menu to show or hide columns, synced with the toolbar column chooser, plus Reset Columns.
- Improved listing performance by caching sorted and filtered items.
- Fixed the browser toolbar (navigation buttons and filter field) being hidden on macOS 27 with the Default theme.
- Fixed sidebar navigation publishing state changes during view updates.
- Raised the minimum macOS version to 26 and resolved Swift concurrency warnings.

## 2026-08-17 — v1.08

- Added All Files and Drill-Down modes to Space Analyzer, including a configurable default mode.
- Added folder breadcrumb navigation in Drill-Down Mode and double-click navigation into folders.
- Improved Drill-Down visualization with a WinDirStat-style proportional treemap that keeps smaller items visible while reflecting relative sizes.
- Standardized folder tile colors in Drill-Down Mode to match the default folder color.
- Fixed incorrect zero free-space reporting for network volumes and aligned Space Analyzer’s used/free capacity display with standard folder navigation.

## 2026-08-11 — v1.07

- Added a dedicated Copy Queue tab beside Space Analyzer, with transfer progress that continues correctly while switching tabs.
- Added Copy Queue history for completed copy and move operations, configurable under File Transfers settings and limited to the latest 100 entries by default.
- Added clickable destination-folder links to active transfers; selecting one switches to an existing folder tab or opens a new tab.
- Improved transfer cancellation and failure handling: cancelled tasks disappear immediately, progress stops correctly, unexpected abort reasons are displayed, and partial destination files are removed.
- Prioritized UI responsiveness during local and mounted-network copy and move operations by keeping filesystem work off the main thread and throttling progress updates.
- Improved deletion on network volumes by permanently deleting files when the volume does not support Trash and presenting an accurate confirmation.
- Grouped Space Analyzer and Copy Queue beneath Devices in the sidebar, while hiding the Devices section when no devices are available.
- Improved the default window layout so the current-folder path and filter controls are fully visible at launch.

## 2026-08-03 — v1.06

- Added an Appearance settings group with light, dark, and system modes; optional banded file rows; and Mac-style or Xplorer-style folder icons.
- Added app-wide element color themes: Default, 💧 Water, 🌍 Earth, 🔥 Fire, and 🌬️ Air. Themes extend across the window, title bar, tabs, sidebar, toolbars, sheets, file surfaces, Space Analyzer, and integrated terminal; Air adds a more transparent treatment.
- Improved the Settings layout with wider controls and separate Appearance, Workspace, and File Transfers groups.
- Added close controls to browser tabs and fixed sidebar sizing, selection state, and its persistent Settings/About controls.
- Remember successful server connections for quick reconnection and open connected locations in new MaXplorer tabs.
- Kept copy and move startup responsive, particularly for network destinations, by moving conflict preflight work off the main thread and coalescing progress updates.
- Refreshed README feature coverage.

## 2026-07-29 — v1.05

- Added favorites persistence and integrated favorite paths with browser tabs and file browser navigation.
- Added paste support through the tab strip and shared browser/file clipboard plumbing.
- Improved file refresh behavior after filesystem changes.
- Refined copy queue behavior for clearer progress and completion handling.
- Improved Space Analyzer tile hover tooltips so size appears first, followed by the item name and full path.
- Made About popups for README and Changelog resizable.
- Refreshed README feature coverage, including advantages over Finder.
- Improved app color scheme handling and sidebar layout polish.

## 2026-07-12 — v1.04

- Cut and paste now moves files reliably between local drives and mounted network volumes.
- Added **MaXplorer README** to the Help menu.
- The status bar shows the selected item count and total size of selected files, returning to the normal item count when the selection is cleared.
- The current folder refreshes automatically when items are added, removed, renamed, or modified externally.
- Mounted network volumes now report their available space correctly instead of showing zero bytes free.
- The integrated terminal now supports the standard Command-C and Command-V clipboard shortcuts.

## 2026-07-11

- Added integrated terminal (in addition to standard new window terminal)

## 2026-07-03 (later) — v1.02

- New **Space Analyzer** (disk storage map): a GrandPerspective-style treemap of everything under a chosen folder, opened from the sidebar, a toolbar button, a distinct coloured tab, or a folder's right-click menu. Only one analyzer tab exists at a time.
- Scanning runs fully in the background (UI stays responsive), shows live progress, has an always-visible Cancel Scan button, and keeps running when you switch tabs.
- Tiles are coloured by file category via an editable `file-categories.json` (Videos, Music, Images, Apps, Archives, Documents). Right-click a tile for Open, Browse Location, or Copy Path.
- Scans ignore symlinks and Finder aliases so only physical items are measured.
- Status bar now shows volume Used / Free (with free-space %) instead of the current folder path.
- Context menu items now display their keyboard shortcuts.
- Favorites and Network sidebar sections can be collapsed/expanded (remembered between runs).
- Long-press a file row to rename it; hover tooltips follow the cursor and dismiss on right-click.

## 2026-07-03

- Conflict resolution now works per-file: each clash shows the filename and prompts Overwrite, Overwrite All, Skip, Skip All, or Cancel. "All" variants apply to the rest of the queue without further prompts.
- Conflict resolution also applies to move operations (drag-drop onto a folder, cut-paste), not just copies.
- Duplicate Tab added (⌘⇧D).
- ⌘F focuses the filter field directly from the keyboard.
- About surface gains a README button that opens the project README in a popup, rendered with the same markdown viewer as the changelog.
- Keyboard shortcuts table in README reorganised into sections and brought up to date.
- README "Current implementation status" section replaced with a user-facing Features section.

## 2026-07-02 (later)

- Drag & drop to copy files from Finder or another tab into the current folder.
- Drag a file onto a tab to spring-load switch to it, then drop to copy in.
- Reorder folder tabs by dragging; right-click a tab for Sort by Name / Close Duplicate Tabs.
- Configurable file columns (Kind, Size, Date Modified/Created/Taken, Owner), remembered between runs; Name is always shown.
- Sidebar rows gain a modern glass hover effect; drag folders in to pin and reorder favorites.

## 2026-07-02

- Added keyboard shortcuts: Quick View (Space), Select All (⌘A), Rename (⌘⇧R); Reveal in Finder moved to ⌃⌘R.
- Fixed menu keyboard shortcuts that stayed disabled because the commands did not observe the active tab's model.
- Modernized the look and feel with Liquid Glass across the toolbar, filter field, and path bar.
- Added Settings and About surfaces to the sidebar, shown on the main canvas.
- About includes a "View Changelog" button that opens this changelog in a popup.
- Resolved all Swift 6 concurrency build warnings.

## 2026-07-01

- Changelog started
