#!/usr/bin/env bash
# End-to-end test of the ASIO audio output in OpenMusic's libmpv
# (third_party/mpv_asio, built by tool/build_libmpv_windows.sh), run on Linux:
# registers a test driver (third_party/mpv_asio/test/test_driver.cpp) in a
# throwaway Wine prefix and plays FLAC files through mpv's "asio" output.
# Needs x86_64-w64-mingw32-g++, wine, ffmpeg, and the libmpv build.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${OPENMUSIC_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/openmusic-build}/libmpv
dll=windows/libmpv/libmpv-2.dll
if [[ ! -f $dll || ! -f $build/build/mpv/libmpv.dll.a ]]; then
  echo "Build libmpv first: tool/build_libmpv_windows.sh" >&2
  exit 1
fi
work=$(mktemp -d)
trap 'WINEPREFIX="$work/prefix" wineserver -k 2>/dev/null || true; rm -rf "$work"' EXIT

cxx=(x86_64-w64-mingw32-g++ -std=c++17 -O1 -Wall -Wextra -Werror -static -Ithird_party/asiosdk/common)
"${cxx[@]}" -shared third_party/mpv_asio/test/test_driver.cpp -lole32 -luuid -o "$work/openmusic_test_asio.dll"
mkdir -p "$work/include/mpv"
cp "$build/src/mpv/libmpv/client.h" "$work/include/mpv/"
"${cxx[@]}" -I"$work/include" third_party/mpv_asio/test/mpv_asio_test.cpp "$build/build/mpv/libmpv.dll.a" \
  -o "$work/mpv_asio_test.exe"

sine() { # output rate seconds ffmpeg-options...: a half-scale 997 Hz sine, both channels
  local out=$1 rate=$2 seconds=$3
  shift 3
  ffmpeg -v error -f lavfi -i "aevalsrc=0.5*sin(2*PI*997*t)|0.5*sin(2*PI*997*t):s=$rate:d=$seconds" "$@" "$work/$out"
}
sine 44k16.flac 44100 2 -sample_fmt s16
sine 48k24.flac 48000 2 -sample_fmt s32 -bits_per_raw_sample 24
sine 96k24.flac 96000 2 -sample_fmt s32 -bits_per_raw_sample 24
sine 44k16-6s.flac 44100 6 -sample_fmt s16

export WINEPREFIX="$work/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
wineboot -i >/dev/null 2>&1
cp "$work/openmusic_test_asio.dll" "$work/mpv_asio_test.exe" "$work"/*.flac "$dll" "$work/prefix/drive_c/"
clsid='{5C1E4D52-8A4F-4E5B-9D7B-0E6A1F3C2B11}'
wine reg add "HKCR\\CLSID\\$clsid\\InprocServer32" /ve /d 'C:\openmusic_test_asio.dll' /f >/dev/null
wine reg add "HKCR\\CLSID\\$clsid\\InprocServer32" /v ThreadingModel /d Apartment /f >/dev/null
wine reg add "HKLM\\Software\\ASIO\\OpenMusic Test" /v CLSID /d "$clsid" /f >/dev/null
wine reg add "HKLM\\Software\\ASIO\\OpenMusic Test" /v Description /d "OpenMusic Test" /f >/dev/null

cd "$work/prefix/drive_c"
# Each sample format the driver may use: Int16LSB, Int24LSB, Int32LSB, Float32LSB.
status=0
for type in 16 17 18 19; do
  echo "== driver sample type $type"
  OPENMUSIC_TEST_ASIO_TYPE=$type WINEDEBUG=-all \
    wine 'C:\mpv_asio_test.exe' 'C:\44k16.flac' 'C:\48k24.flac' 'C:\96k24.flac' 'C:\44k16-6s.flac' || status=1
done
exit $status
