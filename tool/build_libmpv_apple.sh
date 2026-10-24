#!/usr/bin/env bash
# Builds Mpv.xcframework for macOS (arm64 + x86_64) and iOS (devices, and the
# Simulator on arm64 + x86_64), with the FFmpeg filters the app uses:
# equalizer, volume, crossfeed, afir and amovie (room correction), headphone
# (Virtual speakers). media_kit's macOS and iOS builds have only equalizer and
# aresample. Same mpv and FFmpeg as the Windows and Android builds.
#
#   tool/build_libmpv_apple.sh [macos] [ios]
#     -> third_party/media_kit_libs_macos_audio/macos/Frameworks/Mpv.xcframework
#     -> third_party/media_kit_libs_ios_audio/ios/Frameworks/Mpv.xcframework
#
# Runs on a Mac with Xcode (CI builds it on GitHub's macOS runners). Sources
# are pinned and checked against SHA-256 sums; everything builds statically
# into one framework that exports only mpv's API. Needs meson, ninja, nasm,
# cmake, pkg-config (Homebrew). Work files go to ~/.cache/openmusic-build.
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
root=${OPENMUSIC_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/openmusic-build}/libmpv-apple
mkdir -p "$root/src" "$root/build"
jobs=$(sysctl -n hw.ncpu)
# The app's deployment targets (Runner.xcodeproj).
macos_min=12.0
ios_min=15.0

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
    echo "$sum  $file" | shasum -a 256 -c --quiet
    tar -xf "$file" -C "$root/src/$name" --strip-components=1
  fi
}
for s in "${sources[@]}"; do
  # shellcheck disable=SC2086
  fetch $s
done

if [[ ! -f $root/src/mpv.patched ]]; then
  # mpv of 2023 compiles Objective-C for Cocoa and the iOS output without asking meson for it
  # (media-kit/libmpv-darwin-build carries the same fix).
  perl -0pi -e "s/(if features\['cocoa'\]\n)/\$1    add_languages('objc')\n/; s/(if features\['audiounit'\]\n)/\$1    add_languages('objc')\n/" \
    "$root/src/mpv/meson.build"
  touch "$root/src/mpv.patched"
fi

# Every audio decoder (the audio, PCM and ADPCM sections of FFmpeg's codec list); cover art is read
# by the app itself.
audio_decoders=$(sed -n '/^\/\* audio codecs \*\//,/^\/\* subtitles \*\//p' "$root/src/ffmpeg/libavcodec/allcodecs.c" |
  grep -oE 'ff_[a-z0-9_]+_decoder' | sed 's/^ff_//; s/_decoder$//' | sort -u | paste -sd, -)

build_slice() { # slice -> $root/build/<slice>/libmpv.dylib
  local slice=$1 sdk target arch os
  case $slice in
    macos-arm64) sdk=macosx target=arm64-apple-macos$macos_min arch=arm64 os=macos ;;
    macos-x86_64) sdk=macosx target=x86_64-apple-macos$macos_min arch=x86_64 os=macos ;;
    ios-arm64) sdk=iphoneos target=arm64-apple-ios$ios_min arch=arm64 os=ios ;;
    iossim-arm64) sdk=iphonesimulator target=arm64-apple-ios$ios_min-simulator arch=arm64 os=ios ;;
    iossim-x86_64) sdk=iphonesimulator target=x86_64-apple-ios$ios_min-simulator arch=x86_64 os=ios ;;
  esac
  local cpu_family host ffarch
  if [[ $arch == arm64 ]]; then cpu_family=aarch64 host=aarch64-apple-darwin ffarch=aarch64; else cpu_family=x86_64 host=x86_64-apple-darwin ffarch=x86_64; fi
  local sysroot cc cxx flags work=$root/build/$slice prefix=$root/prefix/$slice
  sysroot=$(xcrun --sdk $sdk --show-sdk-path)
  cc=$(xcrun --sdk $sdk -f clang)
  cxx=$(xcrun --sdk $sdk -f clang++)
  flags="-target $target -isysroot $sysroot"
  mkdir -p "$work" "$prefix"
  [[ -f $work/libmpv.dylib ]] && return

  local cross=$work/cross.txt
  local list="'-target', '$target', '-isysroot', '$sysroot'"
  cat >"$cross" <<EOF
[binaries]
c = ['$cc', $list]
cpp = ['$cxx', $list]
objc = ['$cc', $list]
objcpp = ['$cxx', $list]
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$arch'
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
      -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_C_COMPILER="$cc" -DCMAKE_C_FLAGS="$flags" \
      -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DUSE_SHARED_MBEDTLS_LIBRARY=OFF >/dev/null
    ninja -C "$work/mbedtls" install >/dev/null
    done_ mbedtls
  fi
  meson_dep freetype -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=disabled
  meson_dep fribidi -Ddocs=false -Dtests=false -Dbin=false
  meson_dep harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled \
    -Dcoretext=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled

  if ! stamp libass; then
    rm -rf "$work/libass" && mkdir -p "$work/libass"
    (cd "$work/libass" && CC="$cc $flags" "$root/src/libass/configure" --host=$host --prefix="$prefix" \
      --enable-static --disable-shared --with-pic --disable-asm --disable-fontconfig --disable-coretext \
      --disable-require-system-font-provider >/dev/null && make -j"$jobs" install >/dev/null)
    done_ libass
  fi

  if ! stamp ffmpeg; then
    rm -rf "$work/ffmpeg" && mkdir -p "$work/ffmpeg"
    (cd "$work/ffmpeg" && "$root/src/ffmpeg/configure" --prefix="$prefix" --target-os=darwin \
      --arch=$ffarch --enable-cross-compile --cc="$cc" --cxx="$cxx" --pkg-config=pkg-config \
      --pkg-config-flags=--static --extra-cflags="$flags -I$prefix/include" \
      --extra-ldflags="$flags -L$prefix/lib" --enable-static --disable-shared --enable-pic \
      --disable-programs --disable-doc --disable-debug --disable-encoders --disable-muxers --disable-devices \
      --disable-avdevice --disable-postproc --disable-hwaccels --disable-indevs --disable-outdevs \
      --disable-autodetect --enable-network --enable-zlib --enable-mbedtls --enable-version3 \
      --disable-decoders --enable-decoder="$audio_decoders" --disable-filters \
      --enable-filter=abuffer,abuffersink,aformat,anull,aresample,volume,equalizer,crossfeed,afir,amovie,headphone,pan \
      >/dev/null && make -j"$jobs" install >/dev/null)
    done_ ffmpeg
  fi

  local outputs
  if [[ $os == macos ]]; then
    # mpv of 2023 needs Cocoa even without video (media-kit/libmpv-darwin-build found the same).
    outputs="-Dcocoa=enabled -Dcoreaudio=enabled -Daudiounit=disabled"
  else
    outputs="-Dcocoa=disabled -Dcoreaudio=disabled -Daudiounit=enabled"
  fi
  rm -rf "$work/mpv"
  # shellcheck disable=SC2086
  meson setup "$work/mpv" "$root/src/mpv" --cross-file "$cross" --buildtype=release \
    -Ddefault_library=shared -Dlibmpv=true -Dcplayer=false -Dtests=false -Dmanpage-build=disabled \
    -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled \
    -Dcdda=disabled -Duchardet=disabled -Drubberband=disabled -Dlcms2=disabled -Dzimg=disabled \
    -Djpeg=disabled -Dlibplacebo=disabled -Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled \
    -Dgl=disabled -Dgl-cocoa=disabled -Dplain-gl=disabled -Dvideotoolbox-gl=disabled -Dios-gl=disabled \
    -Dswift-build=disabled -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled -Dmacos-touchbar=disabled \
    -Dvapoursynth=disabled -Dsdl2-audio=disabled -Dsdl2-video=disabled -Dopenal=disabled -Diconv=disabled \
    $outputs \
    `# Only mpv's API is exported: the static libraries' symbols stay inside.` \
    `# libc++ for HarfBuzz, which is C++.` \
    -Dc_link_args="-Wl,-exported_symbol,_mpv_* -Wl,-dead_strip -lc++" \
    -Dobjc_link_args="-Wl,-exported_symbol,_mpv_* -Wl,-dead_strip -lc++"
  ninja -C "$work/mpv" | grep -E "error|FAILED" || true
  local built
  built=$(find "$work/mpv" -maxdepth 1 -name 'libmpv*.dylib' -type f | head -1)
  [[ -n $built ]]
  strip -x -o "$work/libmpv.dylib" "$built"
}

# Mpv.framework from one or more slices (lipo'd into one binary).
framework() { # out-dir layout(macos|ios) slices...
  local out=$1 layout=$2
  shift 2
  local fw=$out/Mpv.framework bin plist
  rm -rf "$fw"
  if [[ $layout == macos ]]; then
    mkdir -p "$fw/Versions/A/Resources"
    bin=$fw/Versions/A/Mpv plist=$fw/Versions/A/Resources/Info.plist
    ln -s A "$fw/Versions/Current"
    ln -s Versions/Current/Mpv "$fw/Mpv"
    ln -s Versions/Current/Resources "$fw/Resources"
  else
    mkdir -p "$fw"
    bin=$fw/Mpv plist=$fw/Info.plist
  fi
  local inputs=() s
  for s in "$@"; do inputs+=("$root/build/$s/libmpv.dylib"); done
  lipo -create "${inputs[@]}" -output "$bin"
  install_name_tool -id "@rpath/Mpv.framework/$([[ $layout == macos ]] && echo Versions/A/)Mpv" "$bin"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Mpv</string>
  <key>CFBundleIdentifier</key><string>io.mpv.Mpv</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Mpv</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.36.0</string>
  <key>CFBundleVersion</key><string>1</string>
  $([[ $layout == ios ]] && echo "<key>MinimumOSVersion</key><string>$ios_min</string>")
</dict>
</plist>
EOF
}

for os in ${*:-macos ios}; do
  case $os in
    macos)
      build_slice macos-arm64
      build_slice macos-x86_64
      framework "$root/out/macos" macos macos-arm64 macos-x86_64
      dest=$project/third_party/media_kit_libs_macos_audio/macos/Frameworks
      rm -rf "$dest/Mpv.xcframework" && mkdir -p "$dest"
      xcodebuild -create-xcframework -framework "$root/out/macos/Mpv.framework" -output "$dest/Mpv.xcframework" >/dev/null
      ;;
    ios)
      build_slice ios-arm64
      build_slice iossim-arm64
      build_slice iossim-x86_64
      framework "$root/out/ios" ios ios-arm64
      framework "$root/out/iossim" ios iossim-arm64 iossim-x86_64
      dest=$project/third_party/media_kit_libs_ios_audio/ios/Frameworks
      rm -rf "$dest/Mpv.xcframework" && mkdir -p "$dest"
      xcodebuild -create-xcframework -framework "$root/out/ios/Mpv.framework" \
        -framework "$root/out/iossim/Mpv.framework" -output "$dest/Mpv.xcframework" >/dev/null
      ;;
    *) echo "unknown target: $os (macos, ios)" >&2 && exit 1 ;;
  esac
  echo "Built $dest/Mpv.xcframework"
done
