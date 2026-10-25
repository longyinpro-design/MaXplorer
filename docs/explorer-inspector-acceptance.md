# Explorer preview and details pane — 2026-10-25

Issue: [#11](https://github.com/longyinpro-design/MaXplorer/issues/11); queue: [#18](https://github.com/longyinpro-design/MaXplorer/issues/18).
Base: `2df745539797ce60eb22dbf1ddd90ffd1eb7a8c4`. No application was installed or launched.

## Implementation

- Ordinary file browsing has an optional right pane with Preview/Details modes, a native split divider, a close button and Command-Option-I toggle. Visibility, mode and width persist; width defaults to 320 and clamps to 240–520. Search, copy queue, space analysis and settings retain their existing surfaces.
- The pane reads selection snapshots from the browser. Details show name, kind, known size, dates and path without additional filesystem I/O. Directory/package/network/multiple/empty selections have explicit states. Multiple-item size uses known file bytes only, never recursive folder totals.
- Single-file preview reuses the existing `LocalFileSystemService.quickViewContent`, `QLPreviewView` and bounded `PreviewTextDecoder`. Text encodings, legacy Office advice, errors and retry are exposed. Closing the pane dismantles the system preview. It does not modify the independent Quick View window, its Space handler or `quickViewContent` state.
- Each model retains one latest pending request and rejects stale results by generation. A shared coordinator serializes the complete metadata/decode operation across model lifetimes: destroying and recreating the pane does not free capacity while an uninterruptible filesystem call still runs. Cancellation reaches cooperative work; queued cancelled operations do not start. Existing synchronous OS reads can only finish when the filesystem responds.

## Verification

Evidence root: `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`.

| Check | Result | Receipt |
| --- | --- | --- |
| Full feature/safety/search-performance suite before review delta | 231 PASS / 0 FAIL, including 12 inspector cases and existing Quick View/text encoding tests | `file-operation-tests/20261025T025745-13380`; `explorer-inspector-20261025/tests-full.log` |
| Final inspector delta | 14 PASS / 0 FAIL, adding cross-model actual-I/O serialization and queued cancellation | `file-operation-tests/20261025T030035-18325`; `explorer-inspector-20261025/tests-delta.log` |
| Final actual app build | PASS, build-only | `explorer-inspector-20261025/build-final.log` |
| Final strict signature | PASS (`codesign --verify --deep --strict`) | `explorer-inspector-20261025/DerivedData/Build/Products/Debug/MaXplorer.app` |
| Independent exact-candidate review | 10 source/test/script hashes MATCH; cross-model P2 fixed and incrementally re-reviewed | `explorer-inspector-20261025/candidate.json` (receipt appended afterward) |

The unchanged full-suite evidence is reused alongside the final focused delta; overlapping counts are not added. The export excludes historical AppSettings network-callback and ContentView sidebar-drag changes through task-only patches. CI is checked against the resulting commit after push.

## Remaining acceptance

Isolated GUI remains NOT_RUN: rendered layout, divider/width restoration, narrow windows, keyboard and VoiceOver, Quick Look provider/password focus, simultaneous pane and independent Quick View, and common document formats require an independent macOS graphical session. Delayed injected loaders prove lifecycle behavior but are not a real disconnected network mount. Existing #7/#8 environment gaps remain open. This receipt does not claim graphical acceptance from source/build success.
