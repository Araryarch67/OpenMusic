#!/usr/bin/env bash
# Builds the Windows release app on Linux, to run and test it under Wine.
# Flutter only builds Windows apps on Windows, so this does its steps by hand:
# the asset bundle, the Dart AOT snapshot (Windows gen_snapshot.exe, run in
# Wine), and the runner plus plugins cross-compiled with mingw-w64.
#
# Not a release build for users: it isn't MSVC-built, and the in-app browser
# (flutter_inappwebview, used for YouTube Music sign-in) is left out, since it
# needs MSVC and Edge WebView2.
#
#   tool/build_windows_wine.sh [out-dir]    (default: build/windows-wine)
#   DEBUG_SYMBOLS=1 tool/build_windows_wine.sh ...   (for winedbg backtraces)
#   wine <out-dir>/openmusic.exe
#
# Works on a copy of the project so the project's own build/ isn't touched.
# Needs flutter, x86_64-w64-mingw32-g++ and wine, and windows/libmpv/libmpv-2.dll.
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
out=$(realpath -m "${1:-$project/build/windows-wine}")
work=$(mktemp -d)
trap 'WINEPREFIX="$work/prefix" wineserver -k 2>/dev/null || true; rm -rf "$work"' EXIT

flutter_root=$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")
cache=$flutter_root/bin/cache
engine=$cache/artifacts/engine
flutter precache --windows >/dev/null

# ── Dart ──────────────────────────────────────────────────────────────────
src=$work/src
mkdir -p "$src"
tar -C "$project" -c --exclude=./build --exclude=./.dart_tool --exclude=./android/.gradle \
  --exclude=./windows/flutter/ephemeral --exclude=./linux/flutter/ephemeral . | tar -x -C "$src"
(cd "$src" && flutter pub get >/dev/null)
# The build hooks look for Visual Studio; none of them builds anything for Windows.
mkdir -p "$work/programfiles"
(cd "$src" && env "PROGRAMFILES(X86)=$work/programfiles" \
  flutter build bundle --release --target-platform=windows-x64 --asset-dir="$work/flutter_assets" >/dev/null)
(cd "$src" && "$cache/dart-sdk/bin/dartaotruntime" "$cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot" \
  --sdk-root "$engine/common/flutter_patched_sdk_product/" --target=flutter --no-print-incremental-dependencies \
  -Ddart.vm.profile=false -Ddart.vm.product=true --delete-tostring-package-uri=dart:ui \
  --delete-tostring-package-uri=package:flutter --aot --tfa --target-os windows \
  --packages .dart_tool/package_config.json --output-dill "$work/app.dill" \
  --source "file://$src/.dart_tool/flutter_build/dart_plugin_registrant.dart" \
  --source package:flutter/src/dart_plugin_registrant.dart \
  -Dflutter.dart_plugin_registrant="file://$src/.dart_tool/flutter_build/dart_plugin_registrant.dart" \
  package:openmusic/main.dart >/dev/null)
# Dart-only plugins (shared_preferences, path_provider, file picker) register from here.
grep -q SharedPreferencesWindows "$src/.dart_tool/flutter_build/dart_plugin_registrant.dart"

export WINEPREFIX="$work/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
wineboot -i >/dev/null 2>&1
winpath() { echo "Z:${1//\//\\}"; }
wine "$engine/windows-x64-release/gen_snapshot.exe" --deterministic --snapshot_kind=app-aot-elf \
  --elf="$(winpath "$work/app.so")" --strip "$(winpath "$work/app.dill")" 2>&1 | grep -v DWARF || true
[[ -s $work/app.so ]]

# ── Native ────────────────────────────────────────────────────────────────
plugins=$src/windows/flutter/ephemeral/.plugin_symlinks
wrapper=$engine/windows-x64/cpp_client_wrapper
# -fpermissive and msvc_compat.h: the plugins are written for MSVC.
cxx=(x86_64-w64-mingw32-g++ -std=c++17 -O2 -w -fpermissive -include "$project/tool/windows_wine/msvc_compat.h"
  -I"$project/tool/windows_wine/include" -DNOMINMAX -DFLUTTER_PLUGIN_IMPL ${DEBUG_SYMBOLS:+-g}
  -I"$engine/windows-x64-release" -I"$wrapper/include" -I"$wrapper/include/flutter" -I"$src/windows"
  -I"$src/windows/flutter" -I"$src/windows/runner")
unicode=(-DUNICODE -D_UNICODE)
objs=()
compile() { # source [flags...]
  local file=$1
  shift
  local obj=$work/obj/$(echo "$file" | md5sum | cut -c1-12)-$(basename "${file%.*}").o
  mkdir -p "$work/obj"
  "${cxx[@]}" "$@" -c "$file" -o "$obj"
  objs+=("$obj")
}

# As windows/flutter/CMakeLists.txt does (core_implementations.cc includes the rest).
for f in core_implementations standard_codec plugin_registrar flutter_engine flutter_view_controller; do
  compile "$wrapper/$f.cc" "${unicode[@]}"
done
for f in flutter_window main utils win32_window; do
  compile "$src/windows/runner/$f.cpp" "${unicode[@]}"
done
compile "$src/windows/flutter/generated_plugin_registrant.cc" "${unicode[@]}" \
  -I"$plugins/media_kit_libs_windows_audio/windows/include" -I"$plugins/screen_retriever_windows/windows/include" \
  -I"$plugins/url_launcher_windows/windows/include" -I"$plugins/window_manager/windows/include" \
  -I"$project/tool/windows_wine"

compile "$plugins/media_kit_libs_windows_audio/windows/media_kit_libs_windows_audio_plugin_c_api.cpp" "${unicode[@]}" \
  -I"$plugins/media_kit_libs_windows_audio/windows"
for f in "$plugins"/screen_retriever_windows/windows/*.cpp; do
  compile "$f" "${unicode[@]}" -I"$plugins/screen_retriever_windows/windows/include"
done
for f in "$plugins"/url_launcher_windows/windows/*.cpp; do
  compile "$f" "${unicode[@]}" -I"$plugins/url_launcher_windows/windows/include"
done
for f in "$plugins"/window_manager/windows/*.cpp; do
  compile "$f" "${unicode[@]}" -I"$plugins/window_manager/windows/include"
done
compile "$project/tool/windows_wine/inappwebview_stub.cpp" "${unicode[@]}" -I"$project/tool/windows_wine"

# The icon path in Runner.rc uses a backslash.
sed 's#\\\\#/#g' "$src/windows/runner/Runner.rc" >"$src/windows/runner/Runner.wine.rc"
(cd "$src/windows/runner" && x86_64-w64-mingw32-windres "${unicode[@]}" -DFLUTTER_VERSION='\"wine\"' \
  Runner.wine.rc -O coff -o "$work/obj/runner_rc.o")
objs+=("$work/obj/runner_rc.o")

mkdir -p "$out/data"
x86_64-w64-mingw32-g++ -municode -mwindows -static $([[ -n ${DEBUG_SYMBOLS:-} ]] || echo -s) -o "$out/openmusic.exe" "${objs[@]}" \
  "$engine/windows-x64-release/flutter_windows.dll" \
  -ldwmapi -lole32 -luuid -loleaut32 -lshlwapi -lshell32 -luser32 -lgdi32 -ladvapi32 -lshcore -lwinmm

# ── Bundle ────────────────────────────────────────────────────────────────
# OpenMusic's own libmpv, as the real build bundles it (windows/CMakeLists.txt).
libmpv=$project/windows/libmpv/libmpv-2.dll
[[ -f $libmpv ]] || { echo "missing $libmpv: run tool/build_libmpv_windows.sh" >&2; exit 1; }
cp "$engine/windows-x64-release/flutter_windows.dll" "$libmpv" "$out/"
cp "$work/app.so" "$engine/linux-x64/icudtl.dat" "$out/data/"  # ICU data is the same file on every OS
rm -rf "$out/data/flutter_assets"
cp -r "$work/flutter_assets" "$out/data/flutter_assets"
echo "Built $out/openmusic.exe"
