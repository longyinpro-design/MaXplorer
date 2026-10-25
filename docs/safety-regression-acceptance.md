# Safety and regression acceptance — 2026-10-25

## Candidate and scope

This delivery follows baseline `dcd6ec9071aadbee6c27a96edc3b16395cf95ca2` for issues #7 and #8. The continuing Explorer work queue is [#18](https://github.com/longyinpro-design/MaXplorer/issues/18), with feature issues #9–#17. This document records evidence, not completion of that queue.

The existing AppSettings network callback and ContentView sidebar-drag working-tree changes are excluded. Application builds use an export of the baseline with only this delivery's files overlaid. No app was launched or installed; no GUI, user share, Finder, Dock or current-desktop automation was used.

## Fixes

- Recovery cleanup captures `lstat` identity when scanning and rejects replaced entries before cleanup. Directory permissions are prepared without following the final symbolic link. Tests preserve both the original residue and the replacement file/directory, nested link targets and mode-000 directory cleanup. This detects stale scan results; recursive cleanup is not an atomic transaction against adversarial concurrent writers.
- Native copy callbacks preserve the first error. A later ECANCELED callback no longer replaces an earlier ENOSPC/network failure with a misleading cancellation error.
- Release packaging propagates build failures, refuses an existing output path, routes DerivedData/package caches to the selected output/storage root, checks the executable and signature, and verifies the DMG. It never deletes an earlier distribution folder.
- The safety harness enables fault injection with `MAXPLORER_FAULT_TESTS`; the application build does not define it and has no runtime switch to enable injected faults.
- CI additionally runs the existing drag regression harness with WindowServer, drag services and network denied.

## Results

| Check | Result | Evidence level |
| --- | --- | --- |
| Recovery stale-path regression before fix | 3 passed, 2 failed | Real temporary files; replacement directory and file both reproduced deletion |
| Focused recovery candidate | 6 passed, 0 failed | Headless real filesystem; integrated content assertions also passed in full suite |
| Mid-copy injected errno regression before fix | 0 passed, 4 failed | ENOSPC/ENOTCONN/ETIMEDOUT/EHOSTDOWN were reported as cancellation |
| Publication/rollback/permissions/cleanup/mid-copy faults after fix | 12 passed, 0 failed | Deterministic injected syscall/callback failures; source/target/recovery bytes and error paths checked |
| Full safety/feature/search performance suite | 176 passed, 0 failed | Actual production sources, plus 10k/100k local fixtures; no GUI acceptance implied |
| Real 24 MiB HFS+ low-space image | 3 passed, 0 failed | Mid-directory-copy ENOSPC, source/old-target preservation, no staging residue, successful retry after freeing space; capacity preflight also checked |
| Isolated drag regressions | 5 payload + 13 native seam passed | Boundary probe confirmed permission denial for WindowServer and both drag services; no real desktop drag |
| Universal Release archive | PASS, x86_64 + arm64 | Actual Xcode archive, version 1.11/build 1, strict deep codesign verification |
| DMG and SHA-256 | PASS | hdiutil verify and independently recomputed SHA-256 |
| Packaging failure/overwrite guards | PASS | Stub xcodebuild exit 42 preserved; an existing output directory and sentinel file preserved. Real archive verified separately |
| exFAT private RAW image with new diskutil interface | NOT_RUN | Creation failed before attach with LOCALIZED_STRING_UNAVAILABLE; no image/mount left behind |
| True SMB, isolated GUI/VoiceOver/Instruments | NOT_RUN | No suitable environment available; no current desktop substitution |

The first low-space fixture used one preallocated file, so filling remaining space did not cause copy failure. It was corrected to a three-file directory: copying is paused after positive native progress, only the private test volume is filled until actual ENOSPC, then the worker resumes. The successful receipt below is the acceptance evidence; the earlier fixture failure is not classified as a product defect.

Search evidence in the full run: 10k filter 7.94–38.56 ms; 100k first result 0.506 ms, scan 1.364 s, 9 progress updates; MainActor heartbeat max 25.07 ms. These measure the service pipeline, not rendered UI or Instruments traces.

## Local receipts

Root: `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`.

- `safety-regression-20261025/candidate.json`: exact overlay hashes and exported source.
- `file-operation-tests/20261025T021946-51183`: four failing error-classification probes.
- `file-operation-tests/20261025T022010-52617`: all 12 fault tests passing.
- `file-operation-tests/20261025T022046-53884`: full 176-test run.
- `file-operation-tests/20261025T022300-58797`: real HFS+ mid-copy ENOSPC and capacity checks; private image detached on exit.
- `file-drag-tests/20261025T022044-53799`: isolation proof, payload and native seam tests.
- `exfat-acceptance-20261025T021753-48904`: actual diskutil image create command/error and cleanup audit.
- `safety-regression-20261025/distribution-release.log` and `distribution-release/`: actual Release archive, signature and DMG validation.
- `safety-regression-20261025/packaging-guards-zbtajhn2`: stub boundary checks, separately labelled.

Recovery test-first receipts are under `/Volumes/yl/AgentData/build/safety-recovery-20261025-f53df2a1904878bb/file-operation-tests/`: `20261025T021738-48550` (red) and `20261025T021929-50861` (green).

DMG SHA-256: `1af559efb63f223becf58b50fc15864bc6901e01311e213ae5962085e9a742a3`.

## Distribution and remaining acceptance

The DMG is a local validation artifact with ad-hoc signing. It is not Developer ID signed or notarized; Gatekeeper first launch was not tested. No GitHub Release was published. CI status is recorded on the matching commit and issues after push, not assumed from local tests.

Issues #1–#4 retain their unmet GUI/network conditions. #7 still requires real SMB disconnect/reconnect and exFAT coverage; injected errors and APFS/HFS+ do not substitute. #8 still requires the full interaction/VoiceOver matrix, final release notes/localization review and external release acceptance. At the first delivery, the capability cache only remembered unsupported swap results; the follow-up below completes successful-volume caching.

Historical receipt note: the 2026-10-25 exFAT log path in `issues-1-5-acceptance.md` is no longer present. The 2026-10-24 old-command failure log remains at `file-operation-tests/20261024T113505-81026/image.log`; this delivery adds the valid new-interface receipt above.

## Capability-cache follow-up

Following `aa3bab3fc09fb073934ec060388296416f60cbc0`, capability results now cache both support and lack of support, keyed by both components of the actual mounted filesystem `f_fsid`. A failed identity lookup is not cached. A real unsupported publication downgrades a prior success; a racing successful probe cannot overwrite a negative result. Concurrent first probes may duplicate; filesystem I/O is never held under the capability-cache lock.

- 3 focused cache cases PASS: supported, unsupported probe, and cached success downgraded by a real publication error (error injected; file operations real).
- Full local candidate regression/performance: **179 PASS / 0 FAIL**, receipt `file-operation-tests/20261025T022705-63721`.
- Actual two-filesystem APFS matrix: **4 PASS / 0 FAIL**, receipt `file-operation-tests/20261025T022757-65861`; includes distinct-device cache separation and the original cross-volume operations. The private image was detached.
- Actual application build with fault configuration disabled plus strict signature: **PASS**, receipt `app-validation/20261025T022731-64293`. Build-only used a fresh `safety-capability-20261025/DerivedData`, without launching the app.
- Exact source/overlay hashes: `safety-capability-20261025/candidate.json`. Independent read-only review passed for the production/test changes and the added cross-volume fixture.
- The universal Release DMG above belongs to the earlier `aa3bab3` candidate; this follow-up has its own Debug build and commit CI. It does not relabel that DMG as a newer build.

The first delivery CI [40165453076](https://github.com/longyinpro-design/MaXplorer/actions/runs/40165453076) succeeded on `aa3bab3`: build, 174 core tests, 13 search/performance tests, 5 drag payload tests and 13 native seam tests. The follow-up's CI must be checked independently after push.


## Recovery-root and exclusive-rename completion

Following `7e1f2100f9fb23cd6a7dfed9dddb409b2c65ab38`:

- Every queued copy/move/duplicate records its destination parent in a bounded history (20 roots by default); retry refreshes that root. Recording only normalizes URL strings and writes preferences. Startup recovery scans these roots plus home/current and the legacy chooser destination on the existing background worker. Scanning does not delete residues. Older roots beyond the history limit are not searched automatically.
- All exclusive renames pass through one helper, which observes capability using the opened destination directory's filesystem identity. Success and explicit ENOTSUP/ENOSYS update the observation; EXDEV/EEXIST/EACCES/EINVAL do not. The cache adds a clear unsupported diagnostic while preserving POSIX error identity. Every actual rename, retry and rollback still executes its syscall.
- New history tests use isolated preference suites, and existing queue fixtures inject a no-op recorder, so they do not populate the user's production transfer history.
- Focused tests: 3 recovery-history + 11 exclusive-rename cases PASS. Full integrated regression/performance: **193 PASS / 0 FAIL**, receipt `file-operation-tests/20261025T023739-83272`.
- Actual private APFS cross-volume matrix: **4 PASS / 0 FAIL**, receipt `file-operation-tests/20261025T023826-84685`.
- Private HFS+ real ENOSPC/capacity and space calculations: **6 PASS / 0 FAIL**, receipt `file-operation-tests/20261025T023828-84736`. Three cases exercise the actual private low-space filesystem; the remaining three check space calculations. Both private images were detached.
- Actual application Debug build and strict signature verification: PASS. Source manifest and build log: `safety-completion-20261025/candidate.json` and `safety-completion-20261025/build.log`. No app launch or installation.
- Independent review matched all ten production/test/script hashes and found no blocking issue. Documentation was added afterwards without changing those sources.

CI [40165802946](https://github.com/longyinpro-design/MaXplorer/actions/runs/40165802946) succeeded on `7e1f210`: build, 177 core, 13 search/performance, 5 payload and 13 native drag cases. This completion receives its own exact-commit CI after push. It does not change the candidate identity of the earlier Release DMG. Real SMB/exFAT, GUI responsiveness/recovery interactions and the rest of the release matrix remain unaccepted.
