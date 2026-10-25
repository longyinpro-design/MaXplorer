#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${AGENT_BUILD_ROOT:-}" ]]; then
    exec /Users/long/.local/bin/agent-storage run --project "$repo" -- "$0" "$@"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
run="$AGENT_BUILD_ROOT/file-drag-tests/$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$run"
printf 'Drag test receipt: %s\n' "$run"

# A second containment boundary: no test (or spawned reader) may connect to the
# user's WindowServer, drag server, or network. No NSApplication or window runs.
profile="$repo/Tests/DragRegression/desktop-denied.sb"
/usr/bin/sandbox-exec -f "$profile" /usr/bin/python3 \
    "$repo/Tests/DragRegression/check-boundary.py" 2>&1 | tee "$run/isolation.log"
run_isolated() {
    /usr/bin/python3 - "$profile" "$@" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(["/usr/bin/sandbox-exec", "-f", *sys.argv[1:]], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print("FAIL isolated drag test exceeded 30 seconds", file=sys.stderr)
    sys.exit(124)
PY
}

flags=(-parse-as-library -swift-version 5 -default-isolation MainActor -warnings-as-errors
       -module-cache-path "$AGENT_BUILD_ROOT/swift-module-cache")
xcrun swiftc "${flags[@]}" "$repo/MaXplorer/Views/FileDragPayload.swift" \
    "$repo/Tests/DragRegression/FileDragTests.swift" \
    -o "$run/file-drag-tests" 2>&1 | tee "$run/compile.log"
run_isolated "$run/file-drag-tests" "$run" 2>&1 | tee "$run/tests.log"

xcrun swiftc "${flags[@]}" "$repo/MaXplorer/Models/SelectionMode.swift" \
    "$repo/MaXplorer/Views/FileDragPayload.swift" "$repo/MaXplorer/Views/FileRowInteractionView.swift" \
    "$repo/Tests/DragRegression/NativeInteractionTests.swift" \
    -o "$run/native-drag-tests" 2>&1 | tee "$run/native-compile.log"
run_isolated "$run/native-drag-tests" 2>&1 | tee "$run/native-tests.log"
