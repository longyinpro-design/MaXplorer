#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-run}"
case "$mode" in run|--build-only|--verify|--debug|--logs) ;; *)
    echo "Usage: $0 [--build-only|--verify|--debug|--logs]" >&2; exit 2 ;;
esac
if [[ -z "${AGENT_BUILD_ROOT:-}" ]]; then
    exec /Users/long/.local/bin/agent-storage run --project "$repo" -- "$0" "$@"
fi
: "${AGENT_XCODE_DERIVED_DATA:?Use agent-storage run for build output routing}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$AGENT_BUILD_ROOT/clang-module-cache"
bundle="$AGENT_XCODE_DERIVED_DATA/Build/Products/Debug/MaXplorer.app"
binary="$bundle/Contents/MacOS/MaXplorer"
receipt="$AGENT_BUILD_ROOT/app-validation/$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$receipt"
printf 'Build receipt: %s\n' "$receipt"

# Stop only an earlier instance of this exact build, never another installation.
if [[ "$mode" != "--build-only" ]]; then
    while IFS= read -r pid; do
        command="$(ps -p "$pid" -o comm=)"
        if [[ "$command" == "$binary" ]]; then
            kill -TERM "$pid"
            for _ in {1..50}; do
                if ! kill -0 "$pid" 2>/dev/null; then break; fi
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                echo "Previous instance did not exit; refusing to overwrite its bundle." >&2
                exit 1
            fi
        fi
    done < <(pgrep -x MaXplorer || true)
fi

xcodebuild -project "$repo/MaXplorer.xcodeproj" -scheme MaXplorer \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$AGENT_XCODE_DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$AGENT_BUILD_ROOT/SourcePackages" \
    -packageCachePath "$AGENT_BUILD_ROOT/SwiftPackageCache" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= \
    build 2>&1 | tee "$receipt/build.log"
test -x "$binary"
printf '%s\n' "$bundle" | tee "$receipt/app-path.txt"
/usr/bin/codesign --verify --strict "$bundle" 2>&1 | tee "$receipt/signature.log"

case "$mode" in
    --build-only) exit 0 ;;
    --debug) exec xcrun lldb -- "$binary" ;;
    *) /usr/bin/open -n "$bundle" ;;
esac
if [[ "$mode" == "--logs" ]]; then
    exec /usr/bin/log stream --info --style compact --predicate 'process == "MaXplorer"'
fi
if [[ "$mode" == "--verify" ]]; then
    sleep 1
    found=false
    while IFS= read -r pid; do
        if [[ "$(ps -p "$pid" -o comm=)" == "$binary" ]]; then
            printf 'Running build PID: %s\n' "$pid" | tee "$receipt/process.log"
            found=true
        fi
    done < <(pgrep -x MaXplorer || true)
    "$found"
fi
