# Explorer navigation — 2026-10-25

Issue: [#10](https://github.com/longyinpro-design/MaXplorer/issues/10); execution queue: [#18](https://github.com/longyinpro-design/MaXplorer/issues/18).
Base: `f4bae7a2ba4f67b4c3618c58076fc8b77f1394f2`. No application was installed or launched.

## Implementation and boundaries

- The sidebar has a directory tree rooted at Home and `/`. Expanding reads only that directory's immediate children. One shared background actor serializes actual enumeration, so rapid expansion cannot spawn unbounded simultaneous filesystem calls. Collapsing cancels descendant requests; generations discard late results. A blocked OS call can only finish when the filesystem responds.
- Hidden folders follow the existing hidden-file preference. Packages are navigable leaves, never expanded. Symlinks and Finder aliases are omitted, and lexical ancestors are checked before listing. These read checks are not an atomic defense against a malicious concurrent path replacement.
- Current-folder changes reveal only its ancestor chain. If a cached parent lacks a newly created target, that parent refreshes once and its old descendant cache is discarded. Errors remain visible with retry; users can refresh an expanded branch. No recursive scan or filesystem watcher was added.
- Native disclosure/buttons, current-folder indication, open-in-new-tab, explicit drag preview and folder drop callbacks are wired into the sidebar. Existing favorite and device rows remain separate.
- The sidebar and Go menu open a recent-files sheet. It records this app's explicit file-open requests from normal/open-with, recent entries, Quick View and space analysis. Previewing alone does not record. Requests are not claimed as confirmed external-app success.
- Recent files are a local UserDefaults MRU capped at 50. Recording uses URL strings/date only; a background refresh checks those known paths. Missing/unreadable records remain visible, symlinks and directories are unavailable, Finder alias files are not resolved by the history probe. Clear/remove change history only. Late refreshes cannot restore cleared or replaced records.

## Verification

Evidence root: `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`.

| Check | Result | Receipt |
| --- | --- | --- |
| Full feature/safety/search-performance suite before review delta | 217 PASS / 0 FAIL, including 11 tree and 7 recent-files cases | `file-operation-tests/20261025T025101-2326`; `explorer-navigation-20261025/tests-full.log` |
| Final tree delta | 13 PASS / 0 FAIL: includes cached-parent/new-child, one refresh, descendant invalidation and cancellation | `explorer-navigation-20261025/tests-delta.log` |
| Final actual app build | PASS; build-only, no launch | `explorer-navigation-20261025/build-final.log` |
| Final strict bundle signature verification | PASS (`codesign --verify --deep --strict`) | `explorer-navigation-20261025/DerivedData/Build/Products/Debug/MaXplorer.app` |
| Independent review | 15 source/test/script hashes MATCH; two P2 findings fixed and incrementally re-reviewed | `explorer-navigation-20261025/candidate.json` (receipt doc appended afterward) |

The unchanged portion of the full suite is reused; the final candidate additionally runs the focused tree delta. Counts from these overlapping runs are not summed. CI is checked against the resulting commit after push, not inferred from local tests. Historical AppSettings network-callback and ContentView sidebar-drag changes are excluded from the clean candidate and commit.

## Still open

Isolated GUI testing is NOT_RUN: actual keyboard/VoiceOver navigation, directory-tree dragging and dropping, rendered selection/tab linkage, recent-sheet layout and real external opening need a separate macOS graphical session. Slow-network cancellation is covered by deterministic delayed loaders, not a real disconnected SMB mount. Existing #7/#8 SMB/exFAT/GUI requirements remain open. No user desktop was used as a substitute.
