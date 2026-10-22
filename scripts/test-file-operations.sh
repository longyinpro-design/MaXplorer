#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
: "${AGENT_BUILD_ROOT:?Run through agent-storage run --project <worktree> -- scripts/test-file-operations.sh}"
run="$AGENT_BUILD_ROOT/file-operation-tests/$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$run"
if [[ "${1:-}" == "--cross-volume" ]]; then
    image="$run/cross-volume.sparseimage"
    mount="$run/cross-volume"
    mkdir "$mount"
    hdiutil create -size 128m -fs APFS -type SPARSE -volname MaXplorerSafetyTest -o "$image" > "$run/image.log"
    hdiutil attach -nobrowse -mountpoint "$mount" "$image" >> "$run/image.log"
    trap 'hdiutil detach "$mount" >> "$run/image.log"' EXIT
    export MAXPLORER_CROSS_VOLUME_ROOT="$mount"
fi
sources=("$repo/MaXplorer/ViewModels/CopyQueueViewModel.swift")
if [[ -f "$repo/MaXplorer/Services/SafeFileOperations.swift" ]]; then
    sources+=("$repo/MaXplorer/Services/SafeFileOperations.swift"
        "$repo/MaXplorer/Services/FileSystemService.swift"
        "$repo/MaXplorer/Services/PreviewTextDecoder.swift"
        "$repo/MaXplorer/Models/FileItem.swift"
        "$repo/MaXplorer/Models/FinderTag.swift"
        "$repo/MaXplorer/Models/QuickViewContent.swift")
fi
printf 'Test receipt: %s\n' "$run"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -warnings-as-errors \
    -module-cache-path "$AGENT_BUILD_ROOT/swift-module-cache" \
    "${sources[@]}" "$repo/Tests/"*.swift -o "$run/file-operation-tests" 2>&1 | tee "$run/compile.log"
"$run/file-operation-tests" "$run/fixtures" 2>&1 | tee "$run/tests.log"
