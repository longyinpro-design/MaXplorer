# Explorer archive browsing and selected extraction — 2026-10-25

Issue [#15](https://github.com/longyinpro-design/MaXplorer/issues/15); queue [#18](https://github.com/longyinpro-design/MaXplorer/issues/18).
Base `a563c24f45c5cd5e88655ff4b5d75de081ff2d16`. No application was installed or launched and no current-desktop interaction was performed.

## Supported behavior and backend

- ZIP/TAR (including existing gzip/bzip tar aliases), 7z and RAR can open as a read-only virtual directory, from Open, recent files, the menu or context menu. Enter/Return/double-click navigates directories; Up returns. Listing does not create extraction output. Plain GZIP/BZIP2 retain their existing full-decompression behavior rather than pretending to contain a directory table.
- Selection preserves archive-relative paths. Selecting a directory includes its descendants; links and special files cannot be selected for extraction, and selecting a parent containing them fails explicitly. Only selected payloads are materialized. A solid-format backend may decode preceding data internally to advance headers, so this is not a random-access or zero-decompression claim.
- Existing full ZIP/TAR/GZIP/BZIP2 extraction is retained, including safe internal symlink behavior. New selective extraction and full 7z/RAR use the stricter structured backend and reject links/special files. Output is owner-private (files 0600, directories 0700); owner, special permissions and xattrs from untrusted entries are not restored.
- Ordinary 7z creation uses `/usr/bin/tar --format 7zip`; the app dynamically links the macOS `/usr/lib/libarchive.2.dylib` for structured listing/selection. No 7zz/unrar installation or bundled executable is required. RAR is read/extract only; RAR creation, password handling and multi-volume assembly are not implemented. Unsupported codecs, encrypted data/headers and malformed content fail explicitly.
- The C module declares the narrow system ABI from official libarchive v3.7.4 headers. The upstream notice is retained in `MaXplorer/Support/CArchive/Libarchive-LICENSE.txt`, distinct from the app's GPL LICENSE; both bundled copies were hash-verified. Seven tiny official RAR/7z fixtures retain their sources, hashes and license under `Tests/Fixtures/ArchiveCatalog`.

Official sources: [archive API](https://raw.githubusercontent.com/libarchive/libarchive/v3.7.4/libarchive/archive.h), [entry API](https://raw.githubusercontent.com/libarchive/libarchive/v3.7.4/libarchive/archive_entry.h), [COPYING](https://raw.githubusercontent.com/libarchive/libarchive/v3.7.4/COPYING).

## Safety and interaction boundaries

- Only ZIP/TAR/7z/RAR/RAR5 plus none/gzip/bzip2/xz built-in filters are registered. No `format_all`, mtree, raw reader, external filter program, password or volume callback is enabled. Names are structured UTF-8 metadata, never parsed by lines or passed as glob selection patterns. The system tar probe demonstrated why `[a].txt` must not be passed as a selection pattern.
- Catalog entries bind source fd identity and actual header ordinal/path/metadata. Both source fd and path are rechecked before and after extraction. Only no-follow-opened regular archive files are accepted. Absolute paths, traversal, backslashes/drive prefixes, duplicate/case/NFC collisions, file ancestors and invalid types fail. Inferred directories are merged only with their matching explicit directory entry.
- Limits default to 100,000 entries including inferred directories, 2 GiB per file, 4 GiB declared/actual extracted total, 4096 path bytes and depth 128. Known sizes are checked before output; actual bytes are checked during reads/writes. The limits are logical output bounds, not a hard bound on libarchive's internal allocations or duration of one native call.
- Extraction uses a destination-parent fd and exclusive random `mkdirat(0700)`, then no-follow directory/file descriptors and O_EXCL files. Failure/cancellation uses anchored cleanup. Progress reports bytes actually written, first nonzero immediately and then approximately every 250 ms. A native call cannot be interrupted until it returns; cancellation is checked between calls/blocks.
- Selected output feeds the existing top-level preflight/conflict flow and SafeFileOperations. Overwrite approvals now bind complete source/target snapshots for extraction. An unapproved late destination fails exclusively; a planned skip stays skipped even if its old target vanishes. Existing top-level directory overwrite semantics replace the whole folder, without merging; this can remove its other existing contents and is explicitly stated in the browser and confirmation UI.
- Creation now prepares a private archive before confirmation, captures a strict comparison to the target, then publishes with its approval. A target or prepared payload changed after confirmation is rejected. The prior bool-only UI overwrite race was fixed for all formats, including new 7z. Cancel/dismiss/model release cleans owned pending output.
- Browser and directory-panel callbacks carry an active request UUID and archive URL. The panel is retained and cancelled on browser disappearance; old, closed, replaced or wrong-archive callbacks cannot retain a later extraction. Pending selection is consumed once only after the browser sheet dismisses.

## Exact validation

Evidence root `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`; export `explorer-archives-20261025/{source,candidate.json}` excludes historical AppSettings/ContentView dirty changes.

| Scope | Result | Receipt |
| --- | --- | --- |
| Final full suite | **331 PASS / 0 FAIL**, strict Swift 5/default MainActor/warnings-as-errors | `file-operation-tests/20261025T105248-42982`; `explorer-archives-20261025/tests-full.log` |
| Archive-focused after review fixes | **35 PASS / 0 FAIL** | `explorer-archives-20261025/tests-reviewed.log` |
| Actual data cancellation | 32 MiB TAR cancelled after 65,536 bytes written; CancellationError, no staging/unselected output, archive byte-for-byte unchanged | worker `archive-catalog-20261025-2585aba6ac9a19c1/catalog-check/partial-final.log`, then integrated full suite |
| Formats/special names | Actual ZIP/TAR/7z, RAR3/RAR5 stored/compressed; Unicode/newline/literal `[a].txt`, inferred/empty directories and selected-file/parent extraction | Integrated full suite; fixture provenance in source |
| Adversarial paths and content | Traversal/absolute/Windows paths, case/NFC/duplicate/ancestor collision, symlink/hardlink/FIFO/device, stale source, limits, corrupt and four encrypted fixtures | Same full receipt |
| Publication/session regressions | ZIP/7z confirmed target replacement, prepared payload change, late target, planned skip, closed/reopened/superseded callback, virtual navigation/cancel/model lifetime | Same full receipt |
| Actual build + link + strict signature/notices | PASS, build-only; libarchive.2 linked and GPL/libarchive resource hashes MATCH | `explorer-archives-20261025/build-final.log`; its `DerivedData/Build/Products/Debug/MaXplorer.app` |
| Independent review | Initial 26 hashes + final 27 hashes; P1 compression approval and P2 late callback fixed and rechecked; last deinit cleanup delta verified, no open findings | Candidate manifest; this receipt appended after review |

Backend probe `archive-backend-probe-20261025/probe-result.json` SHA256 `b857597ff037e47216149b00d638659ce60a754d3dc72b3eac052ba3099b3ed3` separately records system versions, raw ABI/CLI probes and fixtures. Initial app build failed due duplicate resource name LICENSE; the upstream notice was renamed and final build/notices verified. CI is reported against the final pushed commit in #15/#18.

## Remaining acceptance

Isolated GUI remains **NOT_RUN** for actual browser/Return/selection, sheet-panel dismissal, conflict prompts, keyboard/VoiceOver and visible cancellation. Complex/solid RAR codecs, multi-volume combinations and large-solid native-call cancellation latency are not proven. Actual-byte limits are implemented, but supported real fixtures report known sizes, so the unknown-size regular-file branch lacks dynamic evidence. Issue #15 remains open for its explicit GUI/environment criteria. No current desktop was used as a substitute.
