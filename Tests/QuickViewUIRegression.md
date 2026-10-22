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
