#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${AGENT_BUILD_ROOT:-}" ]]; then
    exec /Users/long/.local/bin/agent-storage run --project "$repo" -- "$0" "$@"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
run="$AGENT_BUILD_ROOT/file-thumbnail-tests/$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$run"
printf 'Thumbnail test receipt: %s\n' "$run"
profile="$repo/Tests/DragRegression/desktop-denied.sb"
/usr/bin/sandbox-exec -f "$profile" /usr/bin/python3 "$repo/Tests/DragRegression/check-boundary.py" 2>&1 | tee "$run/isolation.log"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -warnings-as-errors \
    -module-cache-path "$AGENT_BUILD_ROOT/swift-module-cache" \
    "$repo/MaXplorer/Services/FileThumbnailService.swift" \
    "$repo/Tests/ThumbnailRegression/FileThumbnailServiceTests.swift" \
    -o "$run/thumbnail-tests" 2>&1 | tee "$run/compile.log"
/usr/bin/python3 - "$profile" "$run/thumbnail-tests" <<'PY' 2>&1 | tee "$run/tests.log"
import subprocess, sys
try:
    sys.exit(subprocess.run(["/usr/bin/sandbox-exec", "-f", *sys.argv[1:]], timeout=40).returncode)
except subprocess.TimeoutExpired:
    print("FAIL thumbnail regression exceeded 40 seconds", file=sys.stderr)
    sys.exit(124)
PY

if [[ "${1:-}" == "--probe" || "${1:-}" == "--probe-video" ]]; then
    ffmpeg_path="$(command -v ffmpeg || true)"
    /usr/bin/python3 - "$profile" "$run/thumbnail-tests" "$run" "$ffmpeg_path" "$1" <<'PYPROBE' 2>&1 | tee "$run/provider.log"
import subprocess, sys
profile, binary, run, ffmpeg, mode = sys.argv[1:]
if not ffmpeg:
    print("NOT_PROVEN video fixture generation requires an existing ffmpeg", file=sys.stderr)
    sys.exit(2)
try:
    generated = subprocess.run(["/usr/bin/sandbox-exec", "-f", profile, ffmpeg,
        "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-f", "lavfi",
        "-i", "color=c=blue:s=96x64:r=4:d=1", "-an", "-c:v", "mpeg4",
        run + "/probe.mov"], timeout=15)
    if generated.returncode:
        print("NOT_PROVEN private video fixture generation failed", file=sys.stderr)
        sys.exit(2)
    print("PASS private video fixture generated: 1 second, 96x64, MPEG-4 MOV", flush=True)
    sys.exit(subprocess.run(["/usr/bin/sandbox-exec", "-f", profile,
        binary, mode, run], timeout=15).returncode)
except subprocess.TimeoutExpired:
    print("NOT_PROVEN isolated video generation or Quick Look probe exceeded 15 seconds", file=sys.stderr)
    sys.exit(124)
PYPROBE
fi
