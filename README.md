# MaXplorer

MaXplorer is a native macOS file manager that combines Windows Explorer-style navigation with a polished, modern Mac experience. Browse quickly, work across local and network storage, and keep every file operation visible and under control.

## Features

- **True tabbed browsing** — open up to 50 folders in tabs, reorder them by dragging, duplicate tabs, sort them by name. The clipboard and favourites stay in sync across every tab.
- **Cut & paste for moves** — use `⌘X` / `⌘V` to move files the way Windows users expect. Moves work across local drives and mounted network volumes, without relying on Finder's less discoverable modifier-key workflow.
- **Paste straight into another tab** — copy or cut items, then use a destination tab's context menu to paste there without navigating away from the folder you are viewing.
- **Visible, responsive copy and move queue** — watch every active transfer in a dedicated queue with per-file progress, overall progress, transfer speed, and estimated time remaining. Network conflict checks and progress updates run without blocking the interface, and you choose how many files MaXplorer processes concurrently.
- **Granular conflict resolution** — when pasting or dropping files that already exist, choose Overwrite, Overwrite All, Skip, Skip All, or Cancel — one conflict at a time, with no surprises.
- **Built-in Space Analyzer** — scan any folder into an interactive, colour-coded treemap, monitor scanning live, and open, browse to, or copy the path of large items directly. There is no need to install a separate disk-usage visualizer.
- **Integrated terminal** — open a terminal pane inside the current tab, already set to that folder, or launch a separate Terminal window from the toolbar or context menu.
- **Instant folder filtering** — `⌥⌘F` focuses a live filter field that narrows the current folder in real time, no Spotlight index required.
- **Network browsing built in** — discover local SMB servers, browse mounted SMB/AFP volumes, connect directly to a known server, and quickly reconnect from a remembered server list. Successful connections open in a new MaXplorer tab, with correct free-space information for mounted network storage.
- **Customisable, shared sidebar** — pin any folder as a favourite, remove built-in locations you never use, reorder pins by dragging, and see changes reflected across all open tabs. Settings and About are always within reach at the bottom of the sidebar.
- **Drag & drop everywhere** — drop files onto a folder row or a tab to copy or move them; spring-loaded tab switching activates the target tab automatically.
- **Quick View and Open With** — preview a selected file with Space and choose a compatible application from the same file context menu.
- **Personalised appearance** — choose light, dark, or system appearance; optional banded file rows; Mac-style blue or Xplorer-style yellow folder icons; and an element-inspired color theme: Default, 💧 Water, 🌍 Earth, 🔥 Fire, or 🌬️ Air. Each theme carries across the window, tabs, sidebar, toolbars, sheets, file surfaces, and terminal while preserving light/dark brightness.
- **Liquid Glass design** — toolbar, filter field, path bar, sidebar, and settings surfaces use macOS 26 Liquid Glass, so MaXplorer looks at home alongside the rest of the system. The Air theme adds an even more transparent, gray-tinted treatment.
- **Finder integration when you need it** — reveal any item in Finder from the context menu or keyboard shortcut without giving up MaXplorer's workflow.

## Keyboard Shortcuts

### File & Folder Actions
| Shortcut | Action |
| --- | --- |
| `⌘O` | Open selected item |
| `Space` | Quick View selected item |
| `⌘⇧N` | New Folder |
| `⌘⇧R` | Rename selected item |
| `⌘⌫` | Move selected items to Trash |
| `⌃⌘R` | Reveal selected item in Finder |
| `⌘⇧T` | Open Terminal at selected item/current folder |

### Edit & Clipboard
| Shortcut | Action |
| --- | --- |
| `⌘C` | Copy selected items |
| `⌘X` | Cut selected items for move on paste |
| `⌘V` | Paste copied or cut items |
| `⌘A` | Select all items in the current folder |
| `⌘⌥C` | Copy selected path, or current folder path if nothing is selected |

### View
| Shortcut | Action |
| --- | --- |
| `⌥⌘F` | Focus the filter field |
| `⌘R` | Reload current folder |
| `⌘⇧.` | Toggle hidden files |
| `⌘⇧A` | Toggle aliases |

### Tabs
| Shortcut | Action |
| --- | --- |
| `⌘T` | New Tab |
| `⌘⇧D` | Duplicate Tab |
| `⌃⇥` | Select next tab |
| `⌃⇧⇥` | Select previous tab |

### Navigation
| Shortcut | Action |
| --- | --- |
| `⌘[` | Back |
| `⌫` | Back (when the file list is focused) |
| `⌘]` | Forward |
| `⌘↑` | Enclosing folder |
| `⌘⇧G` | Go to Folder |
| `⌘⇧H` | Home |
| `⌘K` | Connect to Server |

## Platform support

MaXplorer targets macOS 26 and newer (deployment target 26.5), so it adopts the latest system polish — most notably Liquid Glass — directly, without availability checks.

Current macOS 26 enhancements:

- Liquid Glass surfaces for the toolbar button groups, filter field, path bar, and sidebar.
- The About and Settings canvases use Liquid Glass cards, with color themes that extend across the app window and supporting sheets.
- The Air color theme uses higher-transparency materials across app surfaces.

## Origin

MaXplorer is a modified derivative of [MacXplorer](https://github.com/adisapir/MacXplorer) by Adi Sapir. The upstream project and its commit history are preserved. This repository focuses on large-folder browsing performance, transactional file transfers, Quick View, and Space Analyzer responsiveness.

## License

MaXplorer is free software licensed under the [GNU General Public License version 3](LICENSE). You may redistribute and modify it under the terms of that license. Copyright in the original MacXplorer code remains with its authors.
