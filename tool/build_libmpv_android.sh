#!/usr/bin/env bash
# Builds libmpv.so for Android (arm64-v8a, armeabi-v7a, x86_64) with the
# FFmpeg filters the app uses: crossfeed, afir and amovie (room correction),
# headphone (Virtual speakers). media_kit's Android build has only equalizer,
# volume and aresample. Same mpv and FFmpeg as the Windows build
# (tool/build_libmpv_windows.sh); TLS through mbedtls, as media_kit's.
#
#   tool/build_libmpv_android.sh   -> third_party/media_kit_libs_android_audio/android/src/main/jniLibs/<abi>/libmpv.so
#
# Sources are pinned and checked against SHA-256 sums; everything builds
# statically into one libmpv.so per ABI. Needs the Android NDK (the version
# Flutter uses, found under $ANDROID_HOME/ndk or ~/Android/Sdk/ndk), meson,
# ninja, nasm, cmake, pkg-config, curl. Work files go to
# ~/.cache/openmusic-build/libmpv-android.
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
root=${OPENMUSIC_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/openmusic-build}/libmpv-android
mkdir -p "$root/src" "$root/build"
jobs=$(nproc)
api=24 # Flutter's minSdkVersion
ndk_version=28.2.13676358
ndk=${ANDROID_NDK_HOME:-${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/$ndk_version}
[[ -d $ndk ]] || { echo "Android NDK $ndk_version not found at $ndk" >&2; exit 1; }
bin=$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin

# name url sha256
sources=(
  "ffmpeg https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz 8684f4b00f94b85461884c3719382f1261f0d9eb3d59640a1f4ac0873616f968"
  "mbedtls https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.2/mbedtls-3.6.2.tar.bz2 8b54fb9bcf4d5a7078028e0520acddefb7900b3e66fec7f7175bb5b7d85ccdca"
  "freetype https://download.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.xz 12991c4e55c506dd7f9b765933e62fd2be2e06d421505d7950a132e4f1bb484d"
  "fribidi https://github.com/fribidi/fribidi/releases/download/v1.0.13/fribidi-1.0.13.tar.xz 7fa16c80c81bd622f7b198d31356da139cc318a63fc7761217af4130903f54a2"
  "harfbuzz https://github.com/harfbuzz/harfbuzz/releases/download/8.3.0/harfbuzz-8.3.0.tar.xz 109501eaeb8bde3eadb25fab4164e993fbace29c3d775bcaa1c1e58e2f15f847"
  "libass https://github.com/libass/libass/releases/download/0.17.1/libass-0.17.1.tar.xz f0da0bbfba476c16ae3e1cfd862256d30915911f7abaa1b16ce62ee653192784"
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

build_abi() { # abi
  local abi=$1 triple cpu_family ffarch
  case $abi in
    arm64-v8a) triple=aarch64-linux-android cpu_family=aarch64 ffarch=aarch64 ;;
    armeabi-v7a) triple=armv7a-linux-androideabi cpu_family=arm ffarch=arm ;;
    x86_64) triple=x86_64-linux-android cpu_family=x86_64 ffarch=x86_64 ;;
  esac
  local prefix=$root/prefix/$abi work=$root/build/$abi
  local cc=$bin/$triple$api-clang cxx=$bin/$triple$api-clang++
  mkdir -p "$prefix" "$work"
  local cross=$work/cross.txt
  cat >"$cross" <<EOF
[binaries]
c = '$cc'
cpp = '$cxx'
ar = '$bin/llvm-ar'
strip = '$bin/llvm-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = '$cpu_family'
cpu = '$cpu_family'
endian = 'little'
[built-in options]
prefix = '$prefix'
default_library = 'static'
b_staticpic = true
EOF
  export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig PKG_CONFIG_PATH=
  stamp() { [[ -f $work/$1.done ]]; }
  done_() { touch "$work/$1.done"; }
  meson_dep() { # name meson-options...
    local name=$1
    shift
    stamp "$name" && return
    rm -rf "$work/$name"
    meson setup "$work/$name" "$root/src/$name" --cross-file "$cross" --buildtype=release "$@" >/dev/null
    ninja -C "$work/$name" install >/dev/null
    done_ "$name"
  }

  if ! stamp mbedtls; then
    rm -rf "$work/mbedtls"
    cmake -S "$root/src/mbedtls" -B "$work/mbedtls" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" -DANDROID_ABI="$abi" \
      -DANDROID_PLATFORM=$api -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DUSE_SHARED_MBEDTLS_LIBRARY=OFF >/dev/null
    ninja -C "$work/mbedtls" install >/dev/null
    done_ mbedtls
  fi
  meson_dep freetype -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=disabled
  meson_dep fribidi -Ddocs=false -Dtests=false -Dbin=false
  meson_dep harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled \
    -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled

  if ! stamp libass; then
    rm -rf "$work/libass" && mkdir -p "$work/libass"
    (cd "$work/libass" && CC=$cc AR=$bin/llvm-ar RANLIB=$bin/llvm-ranlib "$root/src/libass/configure" \
      --host="$triple" --prefix="$prefix" --enable-static --disable-shared --with-pic --disable-asm \
      --disable-fontconfig --disable-require-system-font-provider >/dev/null && make -j"$jobs" install >/dev/null)
    done_ libass
  fi

  if ! stamp ffmpeg; then
    rm -rf "$work/ffmpeg" && mkdir -p "$work/ffmpeg"
    # Playback of music only: every audio decoder (the audio, PCM and ADPCM sections of FFmpeg's codec list) and
    # demuxer, the filters mpv and the app use; no video, encoders, muxers or devices. Cover art is
    # read by the app itself.
    local audio_decoders
    audio_decoders=$(sed -n '/^\/\* audio codecs \*\//,/^\/\* subtitles \*\//p' "$root/src/ffmpeg/libavcodec/allcodecs.c" |
      grep -oE 'ff_[a-z0-9_]+_decoder' | sed 's/^ff_//; s/_decoder$//' | sort -u | paste -sd,)
    (cd "$work/ffmpeg" && "$root/src/ffmpeg/configure" --prefix="$prefix" --target-os=android \
      --arch=$ffarch --enable-cross-compile --cc="$cc" --cxx="$cxx" --ar="$bin/llvm-ar" --nm="$bin/llvm-nm" \
      --ranlib="$bin/llvm-ranlib" --strip="$bin/llvm-strip" --pkg-config=pkg-config --pkg-config-flags=--static \
      --extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib" \
      --enable-static --disable-shared --enable-pic \
      --disable-programs --disable-doc --disable-debug --disable-encoders --disable-muxers --disable-devices \
      --disable-avdevice --disable-postproc --disable-hwaccels --disable-indevs --disable-outdevs \
      --disable-autodetect --enable-network --enable-zlib --enable-mbedtls --enable-version3 \
      --disable-vulkan --disable-mediacodec --disable-jni \
      --disable-decoders --enable-decoder="$audio_decoders" --disable-filters \
      --enable-filter=abuffer,abuffersink,aformat,anull,aresample,volume,equalizer,crossfeed,afir,amovie,headphone,pan \
      >/dev/null &&
      make -j"$jobs" install >/dev/null)
    done_ ffmpeg
  fi

  rm -rf "$work/mpv"
  meson setup "$work/mpv" "$root/src/mpv" --cross-file "$cross" --buildtype=release \
    -Ddefault_library=shared -Dlibmpv=true -Dcplayer=false -Dtests=false -Dmanpage-build=disabled \
    -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled \
    -Dcdda=disabled -Duchardet=disabled -Drubberband=disabled -Dlcms2=disabled -Dzimg=disabled \
    -Djpeg=disabled -Dlibplacebo=disabled -Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled \
    -Dgl=disabled -Degl-android=disabled -Dandroid-media-ndk=disabled -Dvapoursynth=disabled \
    -Dsdl2-audio=disabled -Dsdl2-video=disabled -Dopenal=disabled -Diconv=disabled \
    -Dopensles=enabled \
    `# Only mpv's API is exported: the static libraries' symbols stay inside.` \
    -Dc_link_args="-static-libstdc++ -Wl,-soname,libmpv.so -Wl,--exclude-libs,ALL -Wl,--gc-sections" \
    -Dcpp_link_args="-static-libstdc++"
  ninja -C "$work/mpv" | grep -E "error|FAILED" || true
  local built
  built=$(find "$work/mpv" -maxdepth 1 -name 'libmpv.so*' -type f | head -1)
  [[ -n $built ]]
  local out=$project/third_party/media_kit_libs_android_audio/android/src/main/jniLibs/$abi
  mkdir -p "$out"
  "$bin/llvm-strip" --strip-unneeded -o "$out/libmpv.so" "$built"
  echo "Built $out/libmpv.so"
}

for abi in ${ABIS:-arm64-v8a armeabi-v7a x86_64}; do
  build_abi "$abi"
done
