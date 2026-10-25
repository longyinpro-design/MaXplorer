# Explorer combined and indexed search — 2026-10-25

Issue: [#12](https://github.com/longyinpro-design/MaXplorer/issues/12); queue: [#18](https://github.com/longyinpro-design/MaXplorer/issues/18).
Base: `76d1be2f423d5ad798c9fe4e1f59117f358552ce`. No application was installed or launched.

## Implemented semantics

- Names retain contains/glob modes. Type (any/files/folders/packages), final filename extension, inclusive size limits, and creation/modification date ranges combine with AND. Extension alternatives combine with OR and ignore case; names remain a separate condition. Filter-only searches are allowed; no conditions performs no scan.
- Size is known file bytes, never a synthetic zero for directories or unknown metadata. The UI accepts nonnegative integer MiB and rejects overflow. Date controls use the local calendar, including the selected end day via the next day's exclusive boundary. Missing dates do not satisfy enabled ranges.
- A nonempty content condition uses Spotlight's existing index as candidate source, followed by name and metadata filters. The query always receives the explicit root as its search scope before start. It uses a private serial OperationQueue, a parameterized predicate, 256-entry output batches, a 30-second query deadline and a 10,000-candidate limit. Failure/timeout/limit is an explicit error; previously delivered results remain.
- The explicit root is canonicalized once off-main. Indexed paths must be strict descendants; hidden ancestors, package descendants, symlink/alias ancestors, unreadable and vanished entries are rejected. Directory symlinks are not traversed. Metadata construction retains the existing six-worker limit. Existing filename traversal remains available without an index.
- Search uses the existing virtual tab, selection and safe file actions. Cancellation preserves already delivered items. The UI distinguishes index results and states that unindexed, unsupported or stale content may be missing; zero index matches are not presented as an exhaustive filesystem result. No cloud upload or index rebuild was added.

## Local validation

Evidence root: `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a`.

| Check | Result | Receipt |
| --- | --- | --- |
| Full safety/feature/search-performance suite | 256 PASS / 0 FAIL | `file-operation-tests/20261025T030658-28415`; `explorer-search-20261025/tests-full.log` |
| New filters | 7 PASS: kinds, Unicode/case suffixes, size/date boundaries, unknown metadata, AND and overflow | Same full receipt |
| Index driver lifecycle (injected driver) | 10 PASS: explicit scope, predicate input, batches, duplicate/outside candidates, timeout, error/limit, cancellation and late events | Same full receipt |
| Search integration | 6 PASS: filter-only, hidden/package/link/permission/stale boundaries, canonical root, partial error and invalid filters | Same full receipt |
| Existing real 10k filtering | Worst 43.55 ms (<100 ms) | Same full receipt |
| Existing real 100k filename scan | First result 0.50 ms, total 2347.22 ms, heartbeat maximum 37.12 ms | Same full receipt |
| Independent review | No blocking findings; all 12 source/test/script candidate hashes MATCH | `explorer-search-20261025/candidate.json` (receipt appended afterward) |
| Actual app build + strict signature | PASS, build-only and `codesign --verify --deep --strict` | `explorer-search-20261025/build.log`; `DerivedData/Build/Products/Debug/MaXplorer.app` |

## Actual system index probe

Native `NSMetadataQuery` was also compiled and run without GUI against one private generated fixture directory under the external build root, using a unique token. The selected volume reported `Index is read-only`. Thirty attempts finished with zero candidates; the last attempt timed out within the total 50.027-second probe budget. This is **NOT_PROVEN for positive content matching**, not a passing substitute and not sufficient to diagnose a service defect. The private fixture was removed. No home/full-volume query, index enablement or rebuild was executed. A scoped `mdimport -i` produced no output; its first exit code was not captured, so import success is not claimed.

Probe receipt: `/Volumes/yl/AgentData/build/spotlight-service-20261026-2e766bcd3237e0fd/spotlight-real-probe/20261025T030341-23755`, including runner, exact scope/token record, content/source hashes, query log, index status and cleanup confirmation.

## Remaining acceptance

Positive system-index matching remains NOT_PROVEN and requires a writable indexed private fixture location. Isolated GUI remains NOT_RUN for controls, keyboard/VoiceOver and result interactions. The unchanged filename 10k/100k benchmarks do not establish content-index coverage or new filter UI performance. Issue #12 remains open for these criteria. The candidate export excludes historical AppSettings/ContentView dirty changes; CI and final independent-review results are recorded against the resulting candidate/commit after they complete.

## CI performance configuration correction

Commit `6afc8684f49ba99bd6499cc8d0b9ffa8b2a68612`, CI run `40168122929` attempt 1: build and 254 core tests passed. The unoptimized standalone performance executable failed the unchanged 100 ms 10k filter budget at 121.05 ms; the 100k scan passed (first 19.71 ms, total 5307.26 ms). Drag/thumbnail steps were skipped after that failure. A similar unoptimized timing failure was recorded for #11; it is retained rather than represented as a green run.

The dedicated performance entry point now explicitly requests `-O`, while the ordinary safety suite keeps `-Onone`, Swift 5/default MainActor isolation and warnings-as-errors. Latency thresholds, fixture counts and production source are unchanged. These timings describe an optimized standalone executable, not GUI frame latency or an app Release archive.

Exact local correction receipt: `file-operation-tests/20261025T031652-44714`: 26 PASS / 0 FAIL; 10k worst 22.10 ms, 100k first 0.45 ms / total 1176.27 ms, heartbeat maximum 30.11 ms. CI for the correction is tracked in issue #12/#18 after push.
