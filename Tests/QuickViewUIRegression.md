# Quick View UI regression checks

These checks exercise the macOS Quick Look provider and keyboard routing in the running application. The command-line preview tests verify file/encoding boundaries; they do not prove that Office or PDF content was rendered.

## Password submission regression

1. Open a password-protected `.xlsx`, `.pptx`, `.docx`, or PDF with Space from the file table.
2. Click the native password field, enter an incorrect test password, then press Return.
3. Confirm the preview stays open and displays the provider's incorrect-password message.
4. Select all in the password field, enter the known correct password, then press Return.
5. Confirm the original document's expected content is visible. For a multi-page deck, inspect the second page too.
6. Press Escape and confirm the preview sheet closes. Open another file with Space to check repeated use.

Before this fix, step 2 dismissed the sheet: the Done button's `.defaultAction` consumed Return before the native password field. Done now uses `.cancelAction`. MaXplorer does not collect, log, cache, or decrypt passwords itself; the system preview owns password entry.

## Legacy format and fallback checks

1. Use real OLE `.xls`/`.ppt` files, not renamed OOXML ZIPs. Check Chinese text, numeric formatting, worksheet navigation, and slide content where supported.
2. If the provider shows only an icon or rejects a known password, the legacy-format advisory must remain visible without hiding the provider.
3. Choose Open in Default App. Confirm that the correct file opens in the associated application. If a password is needed, enter it there and inspect the document.
4. Close the external test document without saving; return to MaXplorer. Confirm the source file hash is unchanged.

The advisory is based on the legacy Office extension only. It does not assert that a particular file is encrypted or that rendering failed. `QLPreviewView` provides no public load/error callback, so assignment of `previewItem`, a timeout, or `displayState` must not be treated as rendering success/failure. A default application may have its own format limitations; opening the application is not proof that it rendered the document.

## Recorded acceptance: 2026-10-22

Environment: macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), arm64 local Debug build. Fixture names below are task-owned copies. Modern encrypted fixtures were generated from known plaintext, verified with a password/integrity check, and compared byte-for-byte after decryption. Legacy fixtures were verified as OLE containers.

| Fixture | Actual Quick View result | Other evidence |
| --- | --- | --- |
| `01-Legacy-中文报表.xls` | PASS: Chinese, 350.75/125.00, both worksheets | Generated BIFF workbook, not renamed OOXML |
| `02-Legacy-中文演示.ppt` | LIMITATION: icon only | Saved by Microsoft PowerPoint as 97-2003; PowerPoint opens both slides. Explicit `qlmanage` type/generator also produces no preview |
| `03-Encrypted-Excel.xlsx` | PASS: wrong-password retry, correct-password unlock, Chinese and 350.75 | AES encrypted OOXML |
| `04-Encrypted-PPT.pptx` | PASS: wrong-password retry, correct-password unlock, both slides and graphics | AES encrypted OOXML |
| `05-Encrypted-Word.docx` | PASS: wrong-password retry, correct-password unlock, Chinese/English | AES encrypted OOXML |
| `06-Encrypted-PDF.pdf` | PASS: wrong-password retry, correct-password unlock, text and blue graphic | AES-256 PDF |
| `07-Encrypted-Legacy-Excel.xls` | LIMITATION: icon only | XOR encryption; Open in Default App opens Excel and the correct password reveals values 1, 2, 3 |
| `08-Encrypted-Legacy-PPT.ppt` | NOT ACCEPTED as a local compatibility baseline | Known password decrypts with msoffcrypto; Quick Look rejects it, and current PowerPoint cannot read the file either |
| `09-Encrypted-Legacy-PPT-56.ppt` | PASS: wrong-password retry, correct-password unlock, one-slide text | POI 56-bit encrypted fixture |
| `10-Encrypted-Legacy-Excel-RC4.xls` | PASS: wrong-password retry, correct-password unlock, `hello there!` | POI RC4 CryptoAPI fixture |
| `11-Encrypted-Legacy-PPT-PNG.ppt` | LIMITATION: native provider rejects the correct password | Open in Default App opens PowerPoint; correct password displays text and the embedded PNG |

The format limitations remain limitations, not PASS results. The implementation fixes password submission and supplies an explicit path to an installed application; it does not add a replacement Office renderer or automatic file conversion.

Fixture provenance:

- Apache POI `REL_5_4_1`, `test-data/spreadsheet/xor-encryption-abc.xls` (public test password `abc`) and `35897-type4.xls` (`freedom`).
- Apache POI `REL_5_4_1`, `test-data/slideshow/Password_Protected-hello.ppt` and `Password_Protected-56-hello.ppt` (`hello`), plus `ppt_with_png_encrypted.ppt` (`password`).
- POI `TestDocumentEncryption`, `TestPictures`, and `TestBugs` document the fixture passwords and read/decrypt checks. These are public synthetic test values, not user credentials.
- All self-authored modern encrypted fixtures use the synthetic test value `Preview-Test-2026`.

Local evidence root: `/Volumes/yl/AgentData/build/file-operation-safety-dc4382bd30f7681a/legacy-preview-validation`. Compact receipts and fixture-generation script: `/Users/long/Code/文件管理器/research/2026-10-22/legacy-preview`.

Validation commands:

```sh
MAXPLORER_TEST_FILTER=preview /Users/long/.local/bin/agent-storage run --project "$WORKTREE" -- "$WORKTREE/scripts/test-file-operations.sh"
"$WORKTREE/script/build_and_run.sh" --build-only
```

Result: 5 command-line preview tests passed, 0 failed; full Debug build and strict signature verification passed. The only build warning was skipped AppIntents metadata extraction. File-operation/cross-volume tests were not rerun for this UI change. Native UI checks were performed through computer use; they are not an unattended XCUITest suite.

## Chinese interface and preview size: 2026-10-22

Scope: Simplified Chinese for app-owned menus, sidebars, toolbar help, settings, dialogs, transfer/space-analysis labels, and bundled help/changelog. Stable enum raw values and preferences retain their original identifiers. User filenames, original document contents, application names, encoding names, paths, and terminal output are not translated. Third-party/system diagnostics may retain their own wording.

Checks performed through native computer use:

- Relaunch the built app and verify Chinese AppKit menus, sidebar, column titles, status text, dates, and system file-kind descriptions. Verify settings and the bundled help/changelog actually render Chinese text.
- Inspect legacy and modern Office entries. File list and preview header must use the same Chinese type name, including installations whose registered Office type description is English.
- Open a real `.xls` with Space. Verify 350.75/125.00 and worksheet controls remain visible in the larger preview. The final candidate opened at 1200 × 820 points (2400 × 1640 in the Retina capture); the former default was 680 × 460 points.
- Open the encrypted `.xlsx` sample. Confirm the native prompt is Chinese, an incorrect password displays Chinese retry text without closing the sheet, and the correct password reveals the expected 350.75 total. Press Escape to close.
- Initial window sizing must occur once per attached window. The bridge enables native resizing; manual edge dragging was attempted through automation but did not produce a verified size change, so interactive dragging is not recorded as a PASS. Multi-display and smaller-display fitting were not exercised in this run.

Validation: full Debug build and strict signature verification passed; the existing command-line suite passed 33 tests with 0 failures. Cross-volume tests were not rerun because the file-operation engine changed only in error wording. These checks do not reclassify any earlier legacy-provider limitation.

Compact candidate, build/test receipts, and translation audit: `/Users/long/Code/文件管理器/research/2026-10-22/chinese-ui`.


## Independent preview window and display placement: 2026-10-22

This acceptance supersedes the earlier sheet-size implementation and its unresolved upper-edge behavior. A sheet remains attached to its browser window; setting its resizable style alone did not make its upper edge freely draggable. Quick View now uses a separate standard NSWindow with native resizing. Quick Look still receives the original URL. The hosting controller does not impose intrinsic content sizing on the window.

Repeatable checks:

1. Open a document with Space. Drag the upper edge both upward and downward. Also exercise left/right/bottom edges and all four corners, checking content reflow and minimum dimensions.
2. Use the system Zoom Window action. Change a text preview from Automatic to UTF-8; the new content must not reset the window dimensions.
3. Close with Escape, Done, Command-W, and the native close button; reopen with Space. Close the owning browser window and check that its preview disappears.
4. Verify an encrypted workbook's wrong-password retry and successful Return submission. The preview must stay open for both operations.
5. With physical displays, open from each display, move between displays of different sizes/scales, rearrange displays, and disconnect the display containing the preview. All window chrome must remain reachable after fitting. Do not equate pure geometry tests with these physical checks.

Recorded results:

| Check | Evidence and result |
| --- | --- |
| Upper-edge resizing | PASS by the user's direct manual confirmation: dragging both up and down works. Retina capture changed from 2400 × 1704 to 2134 × 1630 pixels after manual resizing. The one-line close-state follow-up does not change resizing code. |
| Other edges/corners | Automation attempted right and bottom-right dragging but did not establish a size change; outside-border coordinates returned windowNotFoundAtPosition. These are not recorded as individual PASS results. |
| Native Zoom Window | PASS: 4032 × 2346 pixel capture, content remains visible. |
| Size retained on text encoding change | PASS: 4032 × 2346 before and after switching to UTF-8. |
| Escape, Command-W, repeated Space | PASS through native computer use; text preview reopened correctly. |
| Owner closure | PASS: after closing the owning browser window, Window menu contains no orphan Quick View entry. |
| Encrypted Excel | PASS on final rebuilt candidate: wrong password retains window with Chinese retry text; correct synthetic password plus Return reveals Chinese rows and total 350.75. |
| Physical dual-display / unplug | NOT PROVEN: user confirmed there is no second display available. |
| Display geometry | PASS: 7 automated tests, including owner-display opening, left/right/above/below layouts and negative coordinates; small/short/Retina point bounds; preserved user geometry; overlap-based destination selection; large-to-small fitting; removal fallback; repeated-notification stability. |

The coordinator fits only after dragging/resizing finishes and removes observers when it closes. Closing cancels the selection known at that time, including a queued replacement; the deferred clear checks its UUID so a later request survives. Independent read-only review identified this pending-selection boundary; the follow-up fix was reviewed and accepted.

Validation: full Debug build and strict signature verification passed. The command-line suite passed 40 tests with 0 failures (33 existing plus 7 geometry tests). No file-operation engine behavior changed, so cross-volume tests were not rerun. The only build warning was skipped AppIntents metadata extraction. Native UI checks and the user's manual confirmation are separate from unattended automated test results.

Compact exact-candidate manifest, command logs, and acceptance receipt: `/Users/long/Code/文件管理器/research/2026-10-22/preview-window`.
