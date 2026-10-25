#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
: "${AGENT_BUILD_ROOT:?Run through agent-storage run --project <worktree> -- scripts/test-file-operations.sh}"
run="$AGENT_BUILD_ROOT/file-operation-tests/$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$run"
mode="${1:-}"
if [[ "$mode" == "--cross-volume" || "$mode" == "--exfat" || "$mode" == "--fat" || "$mode" == "--low-space" ]]; then
    fs=APFS
    size=128m
    if [[ "$mode" == "--exfat" ]]; then fs=ExFAT; size=64m; fi
    if [[ "$mode" == "--fat" ]]; then fs=MS-DOS; size=64m; fi
    if [[ "$mode" == "--low-space" ]]; then fs=HFS+; size=24m; fi
    image="$run/cross-volume.sparseimage"
    mount="$run/cross-volume"
    mkdir "$mount"
    TMPDIR=/tmp hdiutil create -size "$size" -fs "$fs" -type SPARSE -volname MaXplorerSafetyTest -o "$image" > "$run/image.log" 2>&1
    TMPDIR=/tmp hdiutil attach -nobrowse -mountpoint "$mount" "$image" >> "$run/image.log" 2>&1
    trap 'TMPDIR=/tmp hdiutil detach "$mount" >> "$run/image.log" 2>&1' EXIT
    export MAXPLORER_CROSS_VOLUME_ROOT="$mount"
    if [[ "$mode" == "--low-space" ]]; then
        export MAXPLORER_LOW_SPACE_ROOT="$mount"
    fi
fi
sources=("$repo/MaXplorer/ViewModels/CopyQueueViewModel.swift")
if [[ -f "$repo/MaXplorer/Services/SafeFileOperations.swift" ]]; then
    sources+=("$repo/MaXplorer/Services/SafeFileOperations.swift"
        "$repo/MaXplorer/Services/FileSystemService.swift"
        "$repo/MaXplorer/Services/FileSearchService.swift"
        "$repo/MaXplorer/Services/TransferPlanService.swift"
        "$repo/MaXplorer/Services/ArchiveService.swift"
        "$repo/MaXplorer/Services/FileUndoService.swift"
        "$repo/MaXplorer/Services/RecoveryScanner.swift"
        "$repo/MaXplorer/Services/PreviewTextDecoder.swift"
        "$repo/MaXplorer/Models/FileItem.swift"
        "$repo/MaXplorer/Models/SearchModels.swift"
        "$repo/MaXplorer/Models/TransferPlan.swift"
        "$repo/MaXplorer/Models/FileUndo.swift"
        "$repo/MaXplorer/Models/BatchRename.swift"
        "$repo/MaXplorer/Services/BatchRenameService.swift"
        "$repo/MaXplorer/ViewModels/FileUndoJournal.swift"
        "$repo/MaXplorer/Models/FinderTag.swift"
        "$repo/MaXplorer/Models/QuickViewContent.swift"
        "$repo/MaXplorer/Models/PreviewWindowPlacement.swift")
fi
printf 'Test receipt: %s\n' "$run"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -warnings-as-errors \
    -module-cache-path "$AGENT_BUILD_ROOT/swift-module-cache" \
    "${sources[@]}" "$repo/Tests/"*.swift -o "$run/file-operation-tests" 2>&1 | tee "$run/compile.log"
"$run/file-operation-tests" "$run/fixtures" 2>&1 | tee "$run/tests.log"
