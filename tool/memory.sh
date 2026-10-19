#!/usr/bin/env bash
# Measures memory use (integration_test/memory_test.dart) in profile mode, in a
# headless Weston on the GPU with throwaway data, a fresh app process per run.
# Usage: tool/memory.sh [runs]   (default 3; prints the MEM lines of each run)
set -euo pipefail
cd "$(dirname "$0")/.."
runs=${1:-3}

scratch=$(mktemp -d)
trap 'kill $weston 2>/dev/null || true; rm -rf "$scratch"' EXIT
weston --backend=headless --renderer=gl --socket=om-mem --width=2560 --height=1600 >/dev/null 2>&1 &
weston=$!
sleep 1

for i in $(seq 1 "$runs"); do
  echo "── run $i"
  rm -rf "$scratch/data"
  env -u DISPLAY WAYLAND_DISPLAY=om-mem GDK_BACKEND=wayland XDG_DATA_HOME="$scratch/data" \
    flutter drive --profile -d linux \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/memory_test.dart 2>&1 | grep -E "^MEM|Some tests failed|EXCEPTION|Expected|Actual|TimeoutException|Exception:" || true
done
