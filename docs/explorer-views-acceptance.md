# Explorer browsing views — 2026-10-25

Issue: [#9](https://github.com/longyinpro-design/MaXplorer/issues/9); queue: [#18](https://github.com/longyinpro-design/MaXplorer/issues/18).
Base: `2269985a5e8590266dd6cf9118634991332efa3a`. The installed app was not replaced or launched.

## Implementation

- Details, icons and tiles share selection and actions. View mode, icon size and grouping persist in settings; controls are available in the browser/search toolbar and View menu. The details table retains native columns, custom widths/visibility and sorting.
- Type and modified-date grouping runs in the existing generation-checked background display pipeline. The model's flattened visible order is also used for Shift ranges and drag selection. Grid arrows follow actual rows, including partial rows at group boundaries.
- Lazy grid cells request system Quick Look thumbnails for images, movies and PDFs. Metadata keys include URL, mtime, file size and pixel size. An actor deduplicates requests, permits at most three active providers, cancels consumers independently, and limits the LRU cache to 256 entries / 64 MiB. Failure falls back to the existing type icon. Directory changes destroy old cells without replacing the scroll/focus container.
- Native drag behavior remains in the existing AppKit boundary. The collection only adds a focus callback and uses the same snapshot of all selected file URLs. Both cell and background context menus are available.

## Candidate and verification

Evidence root: `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`.

| Check | Result | Receipt |
| --- | --- | --- |
| Complete safety/feature/search-performance suite | 199 PASS / 0 FAIL | `file-operation-tests/20261025T024045-88697` |
| Presentation cases within that suite | 6 PASS: persistence codec/size bounds, natural grouping, fixed-date DST buckets, visible selection order, section-aware navigation, 10k entries | Same receipt |
| Thumbnail scheduler | 14 PASS, including deduplication, three-provider bound, cancellation, late-result isolation, fallback, metadata keys and count/cost LRU | `file-thumbnail-tests/20261025T024132-90204` |
| Actual Quick Look providers | PNG 32x32 and private MOV 64x42 PASS | Same receipt; video generated from a private 1-second fixture |
| Isolated drag regression | 5 payload + 14 native PASS, including focus callback before selection | `file-drag-tests/20261025T024134-90282` |
| Actual app build and strict signature | PASS after fixing the key-handler argument label and review findings | `explorer-views-20261025/build-final.log` |
| Independent review | No blocking findings; background context menu restored; focus node retained | Exact 16 source/test/CI files in candidate manifest; receipt document added later |

The thumbnail and drag harnesses explicitly deny WindowServer, both drag services and network. Their boundary probes confirmed permission denial. No NSApplication, user window or desktop drag was used. CI adds the isolated thumbnail scheduler suite; real providers are optional probes, not an assumed CI service.

`explorer-views-20261025/candidate.json` binds file hashes. The export excludes historical AppSettings network-callback and ContentView sidebar-drag changes, using a task-only patch for those two files. They remain uncommitted in the working tree.

## Remaining acceptance

Issue #9 remains open until isolated GUI acceptance. Build, pure model and provider tests do not prove rendered layout, real keyboard focus, right-click hit testing, cross-application drag from new views, VoiceOver, actual lazy-cell lifetime or peak memory while scrolling 10k files. No Instruments session was run. Existing #7/#8 SMB/exFAT/GUI conditions remain open. CI is checked against the resulting commit after push; it is not inferred from local results.
