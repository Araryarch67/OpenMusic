#!/usr/bin/env bash
# Builds libmpv-2.dll for Windows on Linux (mingw-w64), with OpenMusic's ASIO
# audio output (third_party/mpv_asio) and the FFmpeg filters the app uses
# (equalizer, crossfeed, afir, amovie). It replaces the DLL media_kit ships,
# which has neither.
#
#   tool/build_libmpv_windows.sh            -> windows/libmpv/libmpv-2.dll
#
# Sources are pinned and checked against SHA-256 sums; everything builds
# statically into the one DLL. Needs x86_64-w64-mingw32-gcc, meson, ninja,
# nasm, pkg-config, curl. Work files go to ~/.cache/openmusic-build.
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
root=${OPENMUSIC_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/openmusic-build}/libmpv
prefix=$root/prefix
mkdir -p "$root/src" "$root/build" "$prefix"
jobs=$(nproc)
host=x86_64-w64-mingw32

# name url sha256
sources=(
  "ffmpeg https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz 8684f4b00f94b85461884c3719382f1261f0d9eb3d59640a1f4ac0873616f968"
  "freetype https://download.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.xz 12991c4e55c506dd7f9b765933e62fd2be2e06d421505d7950a132e4f1bb484d"
  "fribidi https://github.com/fribidi/fribidi/releases/download/v1.0.13/fribidi-1.0.13.tar.xz 7fa16c80c81bd622f7b198d31356da139cc318a63fc7761217af4130903f54a2"
  "harfbuzz https://github.com/harfbuzz/harfbuzz/releases/download/8.3.0/harfbuzz-8.3.0.tar.xz 109501eaeb8bde3eadb25fab4164e993fbace29c3d775bcaa1c1e58e2f15f847"
  "libass https://github.com/libass/libass/releases/download/0.17.1/libass-0.17.1.tar.xz f0da0bbfba476c16ae3e1cfd862256d30915911f7abaa1b16ce62ee653192784"
  # The mpv commit media_kit_libs_windows_audio 1.0.9 ships.
  "mpv https://github.com/mpv-player/mpv/archive/652a1dd90711839acdccc08004056d25514ef2d8.tar.gz 926dce4dfb918cbbac603ad5d453d453d0036d1e00e77baaf5d76ca99ce7a419"
)

fetch() { # name url sha256
  local name=$1 url=$2 sum=$3
  local file=$root/dl/$name-$sum
  if [[ ! -d $root/src/$name ]]; then
    mkdir -p "$root/dl" "$root/src/$name"
    [[ -f $file ]] || curl -fsSL -o "$file" "$url"
    echo "$sum  $file" | sha256sum -c --quiet
    tar -xf "$file" -C "$root/src/$name" --strip-components=1
  fi
}
for s in "${sources[@]}"; do
  # shellcheck disable=SC2086
  fetch $s
done

cross=$root/cross.txt
cat >"$cross" <<EOF
[binaries]
c = '$host-gcc'
cpp = '$host-g++'
ar = '$host-ar'
strip = '$host-strip'
windres = '$host-windres'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[built-in options]
prefix = '$prefix'
default_library = 'static'
EOF
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig PKG_CONFIG_PATH=
stamp() { [[ -f $root/build/$1.done ]]; }
done_() { touch "$root/build/$1.done"; }

meson_dep() { # name meson-options...
  local name=$1
  shift
  stamp "$name" && return
  rm -rf "$root/build/$name"
  meson setup "$root/build/$name" "$root/src/$name" --cross-file "$cross" --buildtype=release "$@" >/dev/null
  ninja -C "$root/build/$name" install >/dev/null
  done_ "$name"
}

if ! stamp freetype; then
  rm -rf "$root/build/freetype"
  meson setup "$root/build/freetype" "$root/src/freetype" --cross-file "$cross" --buildtype=release \
    -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=disabled >/dev/null
  ninja -C "$root/build/freetype" install >/dev/null
  done_ freetype
fi
meson_dep fribidi -Ddocs=false -Dtests=false -Dbin=false
meson_dep harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled \
  -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled

if ! stamp libass; then
  rm -rf "$root/build/libass" && mkdir -p "$root/build/libass"
  (cd "$root/build/libass" && "$root/src/libass/configure" --host=$host --prefix="$prefix" --enable-static \
    --disable-shared --disable-fontconfig --disable-require-system-font-provider --enable-directwrite \
    >/dev/null && make -j"$jobs" install >/dev/null)
  done_ libass
fi

if ! stamp ffmpeg; then
  rm -rf "$root/build/ffmpeg" && mkdir -p "$root/build/ffmpeg"
  # Playback only: no encoders, muxers, devices or hardware video. https
  # through Windows' own TLS (schannel), as media_kit's build does.
  (cd "$root/build/ffmpeg" && "$root/src/ffmpeg/configure" --prefix="$prefix" --target-os=mingw32 \
    --arch=x86_64 --cross-prefix=$host- --pkg-config=pkg-config --enable-static --disable-shared \
    --disable-programs --disable-doc --disable-debug --disable-encoders --disable-muxers --disable-devices \
    --disable-avdevice --disable-postproc --disable-hwaccels --disable-indevs --disable-outdevs \
    --enable-schannel --enable-network --disable-autodetect --enable-w32threads \
    --disable-videotoolbox --disable-vaapi --disable-vdpau --disable-cuda --disable-cuvid \
    --disable-nvenc --disable-nvdec --disable-d3d11va --disable-dxva2 --disable-mediafoundation \
    --enable-filter=equalizer,crossfeed,afir,amovie,volume,aresample,anull >/dev/null &&
    make -j"$jobs" install >/dev/null)
  done_ ffmpeg
fi

if ! stamp mpv-patched; then
  # OpenMusic's ASIO output, plus the ASIO SDK host files it builds on.
  "$project/third_party/mpv_asio/apply.sh" "$root/src/mpv" "$project"
  done_ mpv-patched
fi
rm -rf "$root/build/mpv"
meson setup "$root/build/mpv" "$root/src/mpv" --cross-file "$cross" --buildtype="${MPV_BUILDTYPE:-release}" \
  -Ddefault_library=shared -Dlibmpv=true -Dcplayer=false -Dtests=false -Dmanpage-build=disabled \
  -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled \
  -Dcdda=disabled -Duchardet=disabled -Drubberband=disabled -Dlcms2=disabled -Dzimg=disabled \
  -Djpeg=disabled -Dlibplacebo=disabled -Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled \
  -Dgl=disabled -Dd3d11=disabled -Ddirect3d=disabled -Degl-angle=disabled -Dvapoursynth=disabled \
  -Dsdl2-audio=disabled -Dsdl2-video=disabled -Dopenal=disabled -Dwasapi=enabled -Dasio=enabled \
  `# mpv of 2023 relies on "= {0}" zeroing a whole union, which GCC 15+ only does with this flag.` \
  -Dc_args="-fzero-init-padding-bits=unions" \
  -Dc_link_args="-static-libgcc -static-libstdc++ -Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic" \
  -Dcpp_link_args="-static-libgcc -static-libstdc++ -Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic"
ninja -C "$root/build/mpv" | grep -E "error|warning: implicit|FAILED" || true
[[ -f $root/build/mpv/libmpv-2.dll ]]
mkdir -p "$project/windows/libmpv"
$host-strip -o "$project/windows/libmpv/libmpv-2.dll" "$root/build/mpv/libmpv-2.dll"
echo "Built $project/windows/libmpv/libmpv-2.dll"
