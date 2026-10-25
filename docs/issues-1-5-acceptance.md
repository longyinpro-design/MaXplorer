# Issues #1–#5 acceptance (2026-10-25)

This work follows base `161698dfae6811954a66aa8be434bd6e374e8259`. It was built and tested from a separate export of the exact staged task files. Existing AppSettings/network work and the sidebar drag change were excluded. No application was launched, no desktop automation was used, and the installed application was not replaced.

## Behavior repaired

- **#1 Search:** publish the first match immediately; flush later nonempty batches within roughly 150 ms; propagate cancellation through metadata workers; report missing/unreadable roots; keep Unicode glob character boundaries with a thread-local UTF-8 locale; count metadata failures alongside skipped directories. Folder filtering shares the tested display pipeline, filters before sorting, and uses a 50 ms debounce. Search results refresh after queue completions. Current-volume resolution runs off the main actor and does not silently fall back to scanning `/`.
- **#2 Basic actions:** create empty files atomically with exclusive POSIX creation, preserving the error and path. Duplicate planning runs in the background and reserves disk, queue and same-batch names; permission and overlong-name errors terminate planning. Get Info reloads metadata including EXIF date and Finder tags, supports switching among selected items, and cancels size work on dismissal. New File checks cached directory writability. Main and context menu shortcuts are connected.
- **#3 Archives:** add TAR and single-file GZIP compression. Empty ZIP/TAR archives are accepted. Compression requires explicit overwrite approval; extraction retains conflict handling. Cancelling or superseding an operation cannot overwrite a newer operation's UI state. Synchronous staging inspection/cleanup runs off the main actor.
- **#4 Transfer plan:** include small operations with conflicts; calculate in the background with scanned-item/byte progress and cancellation propagation. Same-volume overwrite moves reserve staging space. Missing/unreadable sources fail rather than producing a zero-byte success. Unknown capacity remains a warning; insufficient capacity blocks starting. Closing the sheet clears pending preparation.
- **#5 Queue:** a retry requires fresh overwrite approval; a batch retry leaves conflicting targets for explicit individual confirmation. Mixed old failures/new batches no longer report 100% prematurely. Copy and move use the same tested pause/resume/cancel/retry behavior at concurrency 1, 3 and 5.

## Reproducible checks

All local runs use `/Users/long/.local/bin/agent-storage run --project <worktree> -- <command>`. Build/test products and fixtures are on the external APFS volume. Use absolute command paths when testing an exported candidate, because the storage runner sets the working directory to its project argument.

| Check | Command / evidence | Result |
| --- | --- | --- |
| Full core regression | `MAXPLORER_SEARCH_PERFORMANCE=1 scripts/test-file-operations.sh` | 160 PASS / 0 FAIL (includes two real performance fixtures) |
| Application build and strict ad-hoc signature | `script/build_and_run.sh --build-only` | PASS; no app compiler warnings; only the existing skipped AppIntents-metadata notice |
| Real 10k / 100k search fixtures | `scripts/test-search-performance.sh` | PASS in the final 160-test run; 10k filter 7.55–38.65 ms, 100k first result 1.30 ms, full scan 1.55 s, 11 progress events, MainActor heartbeat max 25.15 ms |
| APFS disk-image cross-volume operations | `MAXPLORER_TEST_FILTER=cross-volume scripts/test-file-operations.sh --cross-volume` | 3 PASS / 0 FAIL |
| Real small-volume preservation | `MAXPLORER_TEST_FILTER=low-space scripts/test-file-operations.sh --low-space` | 2 PASS / 0 FAIL; safety-engine preservation plus actual TransferPlan capacity |
| Real TransferPlan capacity reader | private 24 MB HFS+ image, 32 MB source | copy/move: required 33,554,432 bytes, free 24,535,040 bytes, `canProceed=false`; no filesystem changes |
| exFAT disk image | `scripts/test-file-operations.sh --exfat` | NOT_RUN: `hdiutil create` refused formatting with “操作不被允许”; no mount or test execution |

Coverage includes atomic creation and 24 competing creators; permissions; stale metadata, EXIF and tags; sparse/dense search, Unicode, hidden files, packages, symlink loops and cancellation; ZIP/TAR/GZIP/BZIP2, compressed TAR aliases, empty archives, corrupt inputs, absolute/traversal/link escapes, explicit conflicts, and cancellation of real 512 MiB compression/extraction; preflight capacity, permissions, conflicts, 2048-file progress/cancellation; queue copy/move concurrency matrices and repeated failure/history accounting.

All actual private image mounts were detached by their scripts, and the mountpoints were verified empty on their parent filesystem. This validates native filesystems in disk images, not real exFAT hardware or SMB.

## Evidence limits and issue status policy

Independent read-only review verified all 20 task source/config/test file hashes. The Unicode glob finding was fixed and the affected scope was reviewed again with no remaining blocking findings.

Only acceptance criteria directly covered by the evidence are marked complete. #5's core queue matrix can be completed from these deterministic real-file operations. #1–#4 remain open where their original criteria explicitly require GUI interaction, UI tests, VoiceOver/Instruments, or actual network-volume behavior.

Not run: GUI search/menus/sheets and large-archive interactivity; Instruments/signpost no-main-thread-IO trace; end-to-end VoiceOver/keyboard; SMB latency, unknown capacity and disconnect/reconnect; real exFAT device. MainActor heartbeat is a service responsiveness measurement, not a rendered UI trace. Capacity injection tests do not prove SMB behavior; the low-space image separately proves the actual capacity-reader boundary. No distribution build, notarization, installation or release acceptance is claimed.

## Local receipts

Under `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`:

- `file-operation-tests/20261025T015817-18434`: final 160-test regression/performance run and empty compiler log.
- `app-validation/20261025T015817-18448`: final exact-export build, bundle path and strict signature check.
- `file-operation-tests/20261025T015524-12845`: real 10k/100k performance.

Under `/Volumes/yl/AgentData/build/issue45-transfer-20261025-2488124013db1b60`:

- `file-operation-tests/20261025T015522-12754`: APFS image cross-volume.
- `file-operation-tests/20261025T015538-13231/image.log`: exFAT creation refusal.
- `file-operation-tests/20261025T015720-16668`: small-volume preservation and the new permanent TransferPlan low-space regression.
- `real-plan-low-space-20261025`: production-source probe, commands, compile/test/image logs for actual preflight capacity.

GitHub CI runs the complete core suite and real 10k/100k search checks on the pushed commit. The issue updates link the final commit and its completed CI run.

## CI timing follow-up

The first remote run built successfully and passed 157 core cases, but the cancellation probe failed because it included a fixed 180 ms observation sleep in its 200 ms latency assertion; the runner resumed that observer at 263 ms. The probe now timestamps actual metadata-worker completion and waits for worker drainage, then checks a separate quiescence window for unexpected scheduling. The cancellation requirement remains **less than 200 ms**, with started/finished worker accounting and the maximum-concurrency bound unchanged. Production code is unchanged by this follow-up. Remote acceptance is based on the subsequent completed CI run linked from each issue.

Follow-up local checks: search/performance **13 PASS / 0 FAIL** (`file-operation-tests/20261025T020231-25653`, worker stop 0.042 ms); final fixture-validity assertions **1 PASS / 0 FAIL** (`file-operation-tests/20261025T020310-27061`, worker stop 0.027 ms). Both receipt directories use the main build root listed above.
