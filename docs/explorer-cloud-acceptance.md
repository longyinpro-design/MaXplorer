# Explorer iCloud state and local copies — 2026-10-25

Issue [#17](https://github.com/longyinpro-design/MaXplorer/issues/17), queue [#18](https://github.com/longyinpro-design/MaXplorer/issues/18). Base `92aab3e1154151dc6a4735223aa4f1cc22ca2140`. Production adapter is compiled only: no real account, cloud directory, download, eviction, app launch or desktop interaction was used for this slice.

## Official support matrix

| Provider/capability | This slice |
| --- | --- |
| Selected URL explicitly reporting isUbiquitousItem == true | Foundation iCloud metadata states; gated single ordinary-file download and local-copy eviction requests |
| isUbiquitousItem nil or false | Unknown/unconfirmed support; never inferred local, synchronized or uploaded; all actions disabled |
| Third-party File Provider domain not owned by this app | Unsupported; no fabricated manager/domain/item identifiers |
| Permanent “Keep Downloaded” / pin | Unsupported; the FileProvider content policy is not a generic ordinary-client setter |
| Directory, special file or missing identity | No eviction; download also requires a confirmed regular file; symlinks/special files fail inspection |

Apple's [download status definitions](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus) distinguish `notDownloaded`, `downloaded` (stale local version) and `current` (device's known latest version). `current` does not promise permanent offline retention. The implementation also shows downloading, uploading, requested, unresolved-conflict and error states. Optional values remain optional: absent booleans are not assumed safe. Original NSError domain/code/message are retained in snapshots and UI feedback.

[startDownloadingUbiquitousItem](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem%28at%3A%29) submits a download/synchronization request; the return does not prove completion. [evictUbiquitousItem](https://developer.apple.com/documentation/foundation/filemanager/evictubiquitousitem%28at%3A%29) removes the local copy while retaining iCloud content, and must not be wrapped in an external coordinated write. Both are used directly; no removeItem, Trash, setUbiquitous(false), xattr hack or deletion fallback exists.

Third-party restrictions follow [getIdentifierForUserVisibleFile](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getidentifierforuservisiblefile%28at%3Acompletionhandler%3A%29), whose documented scope is the caller's own provider/domain, and the SDK NSFileProviderManager.h restrictions for extension/containing-app executables. [downloadEagerlyAndKeepDownloaded](https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy/downloadeagerlyandkeepdownloaded) is a provider content policy, not an arbitrary file manager's pin API. These restrictions prevent claiming universal Dropbox/OneDrive integration.

API availability was checked against the installed macOS SDK: NSURL.h ubiquitous keys (10.7–10.10+) and distinct download constants; NSFileManager.h download/evict (10.7+); NSFileProviderManager.h caller/domain restrictions. Current APIs all compile in the app's normal deployment target. No account token, ubiquity container discovery or synchronization settings are read or changed.

## Interaction and safety

The user explicitly opens “显示简介” → “云端状态…”. Only the selected URLs are read, on a detached worker; no folder scanning, contents, thumbnails or eager background provider reads occur. Metadata refresh clears NSURL's cached resource values. The full selected path, known status, errors and unavailable-action reasons are shown. No implicit batch action is provided.

Each single-file action has a confirmation bound to the exact snapshot and a fresh UUID. Closed/cancelled/replaced confirmations and duplicate submissions cannot execute. UI dismissal is disabled while the request is running. Download and eviction return “request submitted”; a later metadata read supplies the displayed state instead of inventing completion. Cancellation after a successful system call does not claim the submitted request was revoked.

Eviction is a conservative product policy: single-link ordinary file, explicit iCloud, current version, uploaded == true, every uploading/downloading/request/conflict flag explicitly false, and no known sync errors. Unknown values disable it. Downloads require known notDownloaded/downloaded state and known nonbusy/nonconflict conditions. All requests re-read the full no-follow lstat identity and relevant provider metadata, reject any changes, then check identity again before the Foundation operation. Nonfile/foreign-host/NUL paths are rejected before the adapter.

Foundation's public actions take a URL, not a held descriptor. External processes or the provider can still change a path/state after the last check; this is not an atomic CAS or a proof of remote durability. The system/provider remains the final permission and synchronization authority. We do not attempt an unsafe rollback or fallback deletion.

## Validation and exact candidate

Export `explorer-cloud-20261025/{source,candidate.json}` under `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a` excludes historical AppSettings/ContentView changes.

- Service worker: **13 fake-provider groups PASS / 0 FAIL**, strict Swift 5/default MainActor/warnings-as-errors. Production Foundation keys/download/evict compiled, never executed. Manifest `/Volumes/yl/AgentData/build/cloud-file-service-20261025-404e7f5d508a12c4/cloud-check/delivery-manifest.json`, receipt `cloud-check/final`.
- Integrated service and confirmation model: **17 PASS / 0 FAIL**, `file-operation-tests/20261025T111500-74368`.
- Actual app build and strict signature: **PASS**, export `build.log`, `codesign --verify --deep --strict` on its DerivedData Debug app. Build-only, no launch.
- Full strict unoptimized regression: **366 PASS / 0 FAIL**, `file-operation-tests/20261025T111543-75613`; export `tests-full.log`.
- Independent final review: all 8 source/test hashes MATCH, no open P1/P2 findings. CI is recorded on the exact pushed commit in #17/#18.

Fake coverage includes optional/missing/unsupported states, stale/current distinction, every eviction gate, missing identity, stale inode/content/cloud metadata, no-follow and link-count guards, NSError identity, exact request count, read/submit cancellation semantics, no unselected traversal, invalid URL/NUL rejection, confirmation tokens and request-versus-completion UI behavior. Fake provider operations deliberately leave private fixture bytes present; this demonstrates no deletion fallback, not real iCloud eviction. An initial malformed NUL test construction was corrected because Foundation had truncated the test input; the final encoded-NUL test reaches the intended validation boundary.

## Remaining acceptance

Real iCloud download/eviction/state transitions require a specifically authorized dedicated test folder/account scope and remain **NOT_PROVEN**. No such scope was supplied, and no user cloud data was touched. Third-party provider integration and permanent pin remain unsupported. Isolated GUI/accessibility/confirmation feedback are **NOT_RUN**. These gaps keep #17 open; production API compilation and fake tests do not close provider acceptance. The installed app remains unchanged.
