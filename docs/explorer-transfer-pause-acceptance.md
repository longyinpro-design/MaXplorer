# Explorer in-flight transfer pause — 2026-10-25

Issue: [#14](https://github.com/longyinpro-design/MaXplorer/issues/14); queue: [#18](https://github.com/longyinpro-design/MaXplorer/issues/18).
Base: `76009c052faaec6836eb2ff2d36e8f75d90776b9`. No app was installed or launched and no desktop interaction was performed.

## Semantics

- Existing queue pause still stops scheduling new work, leaving already running work alone. Each running item separately offers pause/resume. A request displays “pausing” until the actual worker acknowledges a safe point; an acknowledged pause retains its running slot, destination reservation and current byte count. Queue resume does not resume individually paused items.
- Each attempt owns a new `TransferControl` with an NSCondition. Waiting releases the condition lock; resume, cancel and finish wake it. Callbacks run after unlocking and carry a monotonic revision. Queue updates also carry an attempt UUID, so late phase/progress events cannot revive a completed or retried item.
- Actual copyfile callbacks and directory metadata replay cooperate at checkpoints. No pause waits occur inside the global publication/mutation lock. Before final checks, rename/publication and source removal, the control atomically enters finalizing and refuses further pauses. A fast move may finish before pausing; it does not claim to be paused. EXDEV before publication restores the copy phase and pause gate for the cross-volume fallback.
- Task cancellation explicitly cancels the controller and wakes a paused worker, then waits for actual cleanup/commit acknowledgement before releasing ownership. The existing first copyfile IO-error handling and post-publication commit semantics remain. A pause cannot interrupt one in-progress kernel IO; it acts at the next cooperative checkpoint.
- Paused/non-copying phases hide speed and ETA. Resumed speed uses monotonic elapsed time excluding acknowledged pauses. This is continuation only within this process, not persistent crash/restart resumption.
- Normal application quit requests cancellation and asynchronously drains the shared queue before replying to AppKit. Shutdown rejects new enqueue and every retry entry before any state/target mutation. Forced termination remains covered only by existing recovery-residue handling.

## Exact headless evidence

Evidence root: `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`.
Export and hashes: `explorer-transfer-pause-20261025/{source,candidate.json}`; historical AppSettings/ContentView changes excluded.

| Scope | Result | Receipt |
| --- | --- | --- |
| Independent control contribution | 13 PASS, including 100 pause/finalize races, reentrant callbacks, cancellation, elapsed time and EXDEV state boundary | `/Volumes/yl/AgentData/build/transfer-control-20261026-98c6c5297bb0569f/transfer-control-tests/20261025T095946-90099` |
| Real integrated pause suite | 8 PASS; 32 MiB non-sparse payload pauses at 1 MiB, stable progress during acknowledgement, exact bytes after resume; old target preserved while paused/cancelled, source changes reject publication | `file-operation-tests/20261025T100413-94847`; `tests-focused.log` |
| Full pre-review-fix suite | 298 PASS / 0 FAIL, includes existing queue concurrency 1/3/5 and all previous safety/features | `file-operation-tests/20261025T100541-96215`; `tests-full.log` |
| Actual cross-filesystem move | 2 PASS: resume with exact bytes/removal only after commit, and cancel preserving source/no target; private APFS image detached (`disk10 ejected`) | `file-operation-tests/20261025T100541-96194`; `tests-cross-volume.log`, receipt `image.log` |
| Shutdown/retry fix, relevant final queue suite | 34 PASS / 0 FAIL, including all three retry entry points preserving cancelled state, destination, reservations and history after drain | `file-operation-tests/20261025T101056-3415`; `tests-delta.log` |
| Additional final 3-worker combination | 1 PASS: one paused worker retains slot/reservation while four other items drain; resume completes exactly once | `file-operation-tests/20261025T101503-7272`; `tests-concurrent.log` |
| App build-only + strict signature | PASS, final code | `build-final.log`; `DerivedData/Build/Products/Debug/MaXplorer.app` |

Log paths without a receipt prefix above are under `explorer-transfer-pause-20261025`. Independent review matched the original 10 code/test/script hashes and found one P2 shutdown-retry revival gap. It was fixed with guards before mutation plus state/target/reservation/history assertions; the reviewer rechecked that delta and the final additional test. The full pre-fix and narrow post-fix evidence are kept distinct. The document is appended to the final manifest after code review; CI is recorded against the pushed commit in #14/#18.

## Remaining environment evidence

Actual GUI buttons/phase labels, VoiceOver, window dismissal and AppKit normal-quit interaction remain NOT_RUN because no separate macOS GUI environment is available. The async queue drain itself and its cancellation/cleanup invariants were exercised headlessly. No persistent resume, SMB pause latency or hard-kill graceful cleanup is claimed. Existing #7/#8 environment acceptance remains open.

Final test-only cleanup: all four new queue-pause cases now drain workers in catch paths before the outer harness removes fixtures. Relevant final suite **4 PASS / 0 FAIL**, `file-operation-tests/20261025T101758-9825`, `tests-cleanup-final.log`. Independent delta review matched the final test hash and confirmed no open findings. Production source and final app build are unchanged by this test-only correction.
