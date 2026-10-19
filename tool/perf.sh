#!/usr/bin/env bash
# Runs the performance test (integration_test/performance_test.dart) in profile
# mode inside a headless Weston, so no window opens on your desktop and your
# real library / YouTube Music account are never touched.
# Results: printed as "PERF ..." lines and saved to build/perf/<date>.json.
set -euo pipefail
cd "$(dirname "$0")/.."

scratch=$(mktemp -d)
trap 'kill $weston 2>/dev/null || true; rm -rf "$scratch"' EXIT
weston --backend=headless --socket=om-perf >/dev/null 2>&1 &
weston=$!
sleep 1

env -u DISPLAY WAYLAND_DISPLAY=om-perf GDK_BACKEND=wayland XDG_DATA_HOME="$scratch" \
  flutter drive --profile -d linux \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/performance_test.dart "$@" 2>&1 | grep -E "PERF|Expected|Actual|Which|reason|All tests|Some tests|failed"
