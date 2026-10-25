# Explorer conflict decisions — 2026-10-25

Issue: [#13](https://github.com/longyinpro-design/MaXplorer/issues/13); queue: [#18](https://github.com/longyinpro-design/MaXplorer/issues/18).
Base: `4c7a50ae022cc537bcd3ce9adb0736742f1ad40e`. No app was installed or launched and no current-desktop interaction was performed.

## Behavior and safety

- Conflict decisions now include keep both and apply to all remaining conflicts, overwrite/all, skip/all and cancel. The panel asynchronously compares source/target type, strict byte count and modification time. Errors require a new read or a different decision; unreadable objects are never automatically approved. Directory sizes are the strict recursive payload sum used by the transfer engine.
- Keep both uses `name copy.ext`, `name copy 2.ext`; files keep the final extension (`archive.tar.gz` becomes `archive.tar copy.gz`), while directories/packages retain the whole name (`Example.app copy`). Parent aliases, NFC and case are conservatively unified for batch/queue reservations. Only ENOENT means an available candidate. Permission, directory enumeration and overlong-name errors are explicit; cancellation and integer overflow are checked.
- Preflight accounts for active queue destinations and all original names in this batch. A reserved name cannot be approved for overwrite of a future queue result. After asynchronous work and before enqueue, the UI compares the queue reservation set again; if it changed, the entire new batch is stopped with an explicit request to start the transfer again. Existing queue work is untouched. This conservative check can require a new transfer even when an unrelated queue item finishes.
- An opaque overwrite approval binds canonical source/target URLs, parent device/inode identities and both complete strict filesystem snapshots. The engine checks it against freshly captured state when the queued attempt starts, then retains its existing publication checks. Source/target/descendant replacement or modification invalidates approval before staging/publication. This remains metadata change detection, not a filesystem snapshot.
- All-overwrite captures a new comparison/approval for each remaining object; an error or reservation returns to single-item handling. Cancel invalidates the request generation and cancels asynchronous work. Retry clears old approval; overwrite retry requires a new comparison, and keep-both retry carries the actual renamed target.
- Actual destination URLs reach queue history, completion observers and undo. A new copy may be removed by undo; a move may return to its source. Overwrite is explicitly non-restorable, and replaces the whole target directory rather than merging. Final publication of keep-both remains exclusive: a third party winning the planned name causes failure, never overwrite.

## Headless evidence

Evidence root: `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`.
Candidate export: `explorer-conflicts-20261025/source`; hashes: `explorer-conflicts-20261025/candidate.json`. Historical AppSettings/ContentView changes are excluded.

- Initial integrated full suite: **276 PASS / 0 FAIL**, strict Swift 5/default MainActor/warnings-as-errors, receipt `file-operation-tests/20261025T095046-78186`; log `explorer-conflicts-20261025/tests-full.log`.
- Conflict-focused suite: **23 PASS / 0 FAIL**, receipt `file-operation-tests/20261025T094950-77080`.
- New coverage includes 5 naming groups, 10 approval cases and 7 planner/queue/undo cases. Actual file tests cover nested edits, source/target/parent replacement, wrong approval pair, non-overwrite misuse, cancellation, unreadable/missing target, batch/canonical/case/NFC reservations, external name winner, explicit destination history and copy/move undo.
- Actual app build-only and `codesign --verify --deep --strict` passed; `explorer-conflicts-20261025/build.log` and its `DerivedData/Build/Products/Debug/MaXplorer.app`.
- Independent review matched all 13 candidate hashes and checked the VM→queue→engine flow. A concrete repeated-directory-enumeration performance issue in bulk duplicate was identified during final review; its correction and focused evidence are recorded below before commit.

## Remaining acceptance

Isolated GUI is **NOT_RUN**: all button branches, multiple-sheet lifecycle, dismissal, keyboard/VoiceOver and actual window interaction need a separate graphical environment. Existing lack of real SMB/exFAT conditions remains unchanged. Service, disk-fixture and static review results do not establish these UI/environment criteria. Issue #13 remains open. CI is recorded against the final pushed commit in #13/#18.

## Final bulk-naming correction

The batch now normalizes queue reservations once, caches canonical input parents and enumerates each canonical destination directory once. Candidate allocation still performs every lstat/permission/cancellation/error check and immediately reserves each allocated name. A real 1000-item batch with 100 disk case/NFC collisions and 100 queue reservations planned in 41.72 ms in the worker receipt, without a timing threshold. New naming coverage is now 6 groups.

The final integrated candidate passed **277 / 0 FAIL**, receipt `file-operation-tests/20261025T095606-86032`, log `explorer-conflicts-20261025/tests-final.log`. Incremental build-only and strict signature verification also passed, log `build-final.log`. Independent review verified the two changed hashes and reused the other 11 matching hashes; no new blocking finding. This document was appended to the candidate manifest after code review.
