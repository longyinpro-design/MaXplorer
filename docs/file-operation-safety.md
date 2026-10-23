# File operation safety

This slice replaces the queue and service's destructive overwrite paths with one shared transfer engine. It does not add UI features.

## Status and candidate

- Implementation and independent read-only review: complete; the one review finding was reproduced, fixed, and re-reviewed.
- Regression suite: **30 PASS / 0 FAIL**, including a real second APFS filesystem.
- Full Xcode Debug application build and local startup smoke acceptance: **PASS** after the user accepted the Xcode license. Built with Xcode 27.1 (`27A9275`) and local ad-hoc signing; strict code-signature verification passed. No packaging, notarization, or release acceptance is claimed.
- Upstream base: `542f2bba70d1b41227f3134750c1d724a9f7646e`.
- Seven-file implementation/test manifest SHA-256: `7e4700fa36e4c02f6f6e8ac77fe01d0ff5cf7933c7e0a774cb932813e90155bb`.

The manifest covers the three modified existing Swift files, `SafeFileOperations.swift`, both files under `Tests`, and `scripts/test-file-operations.sh`. Its digest is SHA-256 of Python `json.dumps(rows, sort_keys=True).encode()`, with rows sorted by path and each row containing `path` and the file's `sha256`. This document is excluded from that digest.

## Behavior

1. Validate filesystem identities using `lstat`, resolve parent aliases without dereferencing the final symlink, and reject self-copy, hardlink aliases, copying a folder into itself, or replacing an ancestor containing the source. Missing/unreadable sources and unsupported special objects fail before touching the old destination.
2. Copy to a unique private directory inside the destination parent. Darwin `copyfile` preserves ordinary mode bits, ACLs, extended attributes, resource forks, timestamps, and symlinks, including dangling links. Hidden files participate in progress and source validation.
3. Compare complete source snapshots and, for directory overwrites, complete old-destination snapshots before publication. An ordinary edit observed during copying prevents replacement. Snapshot comparisons include device/inode, type/mode, size, nanosecond modification/change times, and flags; reading access times is deliberately excluded.
4. Publish with `renameatx_np`: `RENAME_EXCL` for a new name, `RENAME_SWAP` for a confirmed overwrite. An old destination stays in place until the staged copy is complete. Unsupported rename capabilities fail without a remove-and-retry fallback.
5. Same-volume moves to a new name use exclusive rename. Overwrite moves and actual `EXDEV` moves use the staged copy path. After publication, source removal failures retain the complete destination and the remaining source and report the partial move. The complete destination is never deleted to undo failed source removal.
6. Cancellation is honored before publication. After publication, finishing the committed operation takes precedence. A running queue item keeps its task and concurrency slot until the worker actually terminates; it cannot produce a false successful history entry after an acknowledged cancellation.
7. Queue and service transfers share one publication lane. Payload copies run concurrently in private staging directories; only final validation, rename, and source removal are serialized. This keeps the correctness properties above while honoring the configured copy concurrency.

## Directory permissions and recovery

The native recursive copy implementation copies symlinks in a second pass, after its normal directory permission cleanup. Final directory metadata is therefore deferred until all links have been copied, then applied child-first. This allows a readable `0555` directory with symlinks to be copied correctly.

Darwin can also reject renaming write-disabled directories. Only the private payload root temporarily receives owner-write permission. Its original mode is restored synchronously through a retained directory descriptor after rename, before any source removal. There is a short publication-to-mode-restoration window; final metadata and name publication are not one atomic operation. Restoration failure keeps the destination, source, and old recovery payload and reports their locations.

Existing read-only destinations are not chmod'ed to force replacement. A denied replacement fails safely and retains their original contents and permissions. Failed unpublished copies may have their own directory permissions relaxed for cleanup; symbolic links are not followed. If cleanup cannot complete, the error includes the private `.maxplorer-transfer-*` recovery path. A cleanup failure after publication is reported as committed destination plus retained recovery files, not silent success.

## Reproduce validation

All build and fixture output must remain under the `agent-storage` environment:

```sh
/Users/long/.local/bin/agent-storage run --project "$PWD" -- scripts/test-file-operations.sh --cross-volume
```

The optional `--cross-volume` flag creates a task-owned 128 MB APFS sparse image under `AGENT_BUILD_ROOT`, mounts it only for testing, and detaches it on exit. The source-deletion failure test uses a genuinely read-only source parent; it does not mock removal. Run without the flag for same-volume tests, which explicitly report cross-volume coverage as `NOT_PROVEN`. Run as the normal user, not root, so permission failures remain meaningful.

For a focused rerun:

```sh
MAXPLORER_TEST_FILTER='nested destination edit' /Users/long/.local/bin/agent-storage run --project "$PWD" -- scripts/test-file-operations.sh
```

The harness compiles the actual queue, shared engine, service, and required models with Swift 5 language mode, MainActor default isolation, and warnings as errors. It exits nonzero on a failed assertion or a filter matching no tests.

## Evidence

Environment: macOS 27.0.1 (`26A434`), arm64, Apple Swift 6.4 (`swiftlang-6.4.0.34.1`). Receipts are beneath `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`:

| Check | Receipt | Result |
| --- | --- | --- |
| Initial upstream regressions; only worker visibility changed for the harness | `file-operation-tests/20261022T103430-49957/tests.log` | 0 PASS / 7 FAIL |
| Independent review finding reproduced: in-place edit of old target's nested file | `file-operation-tests/20261022T104653-66842/tests.log` | 0 PASS / 1 FAIL |
| Final candidate, all regressions and real cross-volume tests | `file-operation-tests/20261022T104721-67637/tests.log` | 30 PASS / 0 FAIL |
| Final core compilation, warnings treated as errors | `file-operation-tests/20261022T104721-67637/compile.log` | PASS, no diagnostics |
| Initial full Xcode build attempt | `full-app-build.log` | Initially blocked by license; resolved below |
| Full Debug app build after user accepted license | `app-validation/20261022T113024-4514/build.log` | BUILD SUCCEEDED |
| Local code signature verification | `app-validation/20261022T113024-4514/signature.log` | PASS |

The final tests cover overwrite failure preservation; self/parent/hardlink aliases; descendant and ancestor rejection; files, directories, symlinks, dangling links, hidden children, ACLs, resource forks, timestamps and ordinary permissions; recursive read errors; FIFO rejection; pre/post-publication cancellation; source and destination edits, including a nested in-place edit; concurrent exclusive publication; service routing; queue cancellation ownership; actual cross-volume movement and source removal failure. Independent review matched the final manifest and closed its sole finding.

## Acceptance limits

- This is local APFS/core evidence. SMB, exFAT, network disconnects, ENOSPC, and power-loss recovery have not been accepted. No filesystem snapshot or crash-recovery journal is implemented; files/directories are not fsync'ed as a durability protocol.
- Metadata checks detect observed ordinary edits, but cannot eliminate external changes in the interval between a final check and rename/removal. Hostile external mutation is outside this acceptance boundary.
- Native copying does not preserve hardlink topology, and does not enable preservation of setuid/setgid privilege bits. Copying source owners across accounts and special filesystem objects is not promised.
- Permission-restoration and post-publication backup-cleanup failures have explicit retention paths, but those rare branches have not been fault-injected in this suite.
- Complete Debug application compilation and the focused UI flow below passed. This is local ad-hoc acceptance; Xcode disables Hardened Runtime for this signing mode. Distribution signing, notarization, and the remaining product features have not been accepted.

## Full application startup acceptance (2026-10-22)

The application source remained exactly at `226ad341652d416238a748feb438b8d795b09974`; its seven-file regression manifest above was unchanged. The built bundle is `DerivedData/Build/Products/Debug/MaXplorer.app` under the receipt root above, bundle ID `doccolabs.MaXplorer`, version `1.09`. A running process was matched to this exact bundle path. The main window and Home listing loaded successfully. The only build warning was skipped AppIntents metadata extraction because this app has no AppIntents dependency; there were no application compiler warnings.

Native UI acceptance used `app-validation/ui-smoke-20261022` exclusively for file operations. Go to Folder navigation passed. Copying `probe.txt` first exercised Skip, preserving the old destination hash, then Overwrite, producing the source hash while retaining the source. Cut/Paste moved `move.txt`, removing its old path and preserving exact content at the destination. Copy Queue visibly showed `Copied`, `Moved`, and `0 active`; filesystem checks found no staging residue. The app and the tiny fixture were retained for the user to inspect. Existing user tabs were preserved.

The reproducible entrypoint is `script/build_and_run.sh`, also wired to the Codex Run action. It routes build outputs and package caches through agent-storage, builds Debug with local ad-hoc signing, and verifies the bundle signature. Default mode launches the bundle; `--build-only` was the exercised build mode, followed by native UI launch and inspection. `--verify`, `--logs`, and `--debug` are available for future use. Only a running instance whose executable exactly matches this build is stopped by the default relaunch path.

```sh
./script/build_and_run.sh --build-only
./script/build_and_run.sh
```

A compact local proof copy, including byte-level UI checks and the build log, is retained at `/Users/long/Code/文件管理器/research/2026-10-22/safety-stage/receipts/app-ui-validation.json`.
