# Explorer permissions and Finder tags — 2026-10-25

Issue [#16](https://github.com/longyinpro-design/MaXplorer/issues/16), queue [#18](https://github.com/longyinpro-design/MaXplorer/issues/18). Base `9ee1956495948afcb1d28461b164d62688e17a33`. This slice never installs/launches the application or operates the current desktop.

## Behavior

“显示简介” → “编辑权限与标签…” opens a per-item editor for the exact selected URLs. Every item shows original octal rwx permissions and tag names. Fields are disabled for editing until explicitly enabled; there is no implicit apply-to-all. Each tag is a separate row and commas remain part of its name. Removing all rows explicitly clears tags. The confirmation page shows original → new values and holds immutable changes, so later draft changes cannot alter the authorization. Directories only affect themselves; no recursion, chown, privilege prompt or special permission-bit editor is implemented.

The service mints opaque snapshots from no-follow-opened ordinary files/directories. Identity includes device/inode/type/birth time; versions also contain mode/owner/group/flags/ctime plus original tag bytes. Each field write revalidates the opened descriptor and current path, then uses fchmod/fsetxattr/fremovexattr on that descriptor. Final symlinks, FIFOs and special files fail explicitly. Target replacement/stale metadata fails before write. After a successful syscall, successful fields remain reported even if a later verification or second field fails. POSIX provides no atomic compare-and-swap across metadata operations: external changes can still race a write, but no path-based rollback or replacement write is attempted.

Only 000–777 rwx bits are changed; existing special bits and unrelated xattrs are retained. Finder tag data must be a bounded valid binary plist; malformed/oversized data refuses editing. NFC normalization is case-sensitive, preserves first-input order, and retains existing raw tag spelling/color suffixes. New tags get the no-color suffix. Bounds are 100 tags, 255 UTF-8 bytes/name and 64 KiB encoded data. Empty/whitespace-only/NUL/newline names are rejected. Cancellation prevents unstarted items; completed writes remain visible. Batch errors do not erase other results.

## Verified limitations

On this host, O_EVTONLY (also O_RDONLY) returns EACCES for an already mode000 owned file. Such a file cannot be inspected/edited with the descriptor-only policy. No path chmod fallback is used. A readable file can become000 through its held descriptor; subsequent tags may then fail, accurately reporting permissions as already applied. This tool therefore does not promise to recover an existing000 file.

No recursive rights, ACL editor, ownership editor, elevated helper, Finder color picker, or arbitrary file flags editor is included. Only the documented rwx and tag fields are editable.

## Exact validation

Export `explorer-properties-20261025/{source,candidate.json}` under `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a` excludes historical AppSettings/ContentView dirty changes.

| Scope | Actual result | Receipt |
| --- | --- | --- |
| Service private real fixtures | 14 PASS / 0 FAIL | `/Volumes/yl/AgentData/build/file-property-service-20261025-c3684c21865f4637/property-tests/tests.log` |
| Private HFS+ read-only volume | 1 PASS, separate permission and tag write attempts both EROFS; disk10 detached | Same root `readonly/tests.log` and image logs |
| Integrated service/editor focused | 18 PASS / 0 FAIL | `file-operation-tests/20261025T110846-66820` |
| Full strict regression | 349 PASS / 0 FAIL | `file-operation-tests/20261025T110933-67956`; export `tests-full.log` |
| Production service compile without fault macro | PASS, no warnings | Worker `compile-production.log` |
| Actual app build + strict signature | PASS; build-only | Export `build.log`, `codesign --verify --deep --strict` on its DerivedData Debug app |

Cases cover retained special bits/other xattrs, nonrecursive directory change, colored Unicode/comma labels, clear/no-op/raw byte retention, malformed/oversized/nonbinary metadata, invalid inputs, stale permissions/tags/replaced inode, symlink/FIFO rejection,000 refusal,000 plus partial-field failure, cancellation, batch continuation and immutable reviewed values. Final independent review and CI are recorded on the exact pushed commit in #16/#18.

## Remaining acceptance

Actual isolated GUI confirmation, accessibility/keyboard, row editing and visible partial-failure feedback are **NOT_RUN**. No independent macOS graphical test environment exists. These criteria keep #16 open; headless model tests and build/signature checks do not replace them. The current installed app remains unchanged.
