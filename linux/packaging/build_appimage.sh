#!/usr/bin/env bash
# Packages the release bundle as an AppImage that runs on most distros: it
# carries libmpv and the FFmpeg libraries it needs; GTK, OpenGL and the
# display/sound libraries come from the system.
# Usage: linux/packaging/build_appimage.sh <output.AppImage>
# Needs: a release build, libmpv installed, and linuxdeploy + appimagetool
# (downloaded here when missing).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(realpath -m "$1")
bundle=build/linux/x64/release/bundle
tools=build/appimage-tools
appdir=build/OpenMusic.AppDir
export APPIMAGE_EXTRACT_AND_RUN=1 # no FUSE on CI runners

mkdir -p "$tools"
fetch() { [ -x "$tools/$1" ] || { curl -fsSL -o "$tools/$1" "$2" && chmod +x "$tools/$1"; }; }
fetch linuxdeploy https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
fetch appimagetool https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage

libmpv=$(ldconfig -p | awk '/libmpv\.so\.2 .*x86-64/ {print $NF}' | head -n1 || true)
[ -n "$libmpv" ] || { echo "libmpv.so.2 not found" >&2; exit 1; }

rm -rf "$appdir"
mkdir -p "$appdir/usr/lib" "$appdir/usr/share/openmusic"
cp -r "$bundle"/. "$appdir/usr/share/openmusic/"
# libmpv and its dependencies into usr/lib (linuxdeploy leaves out what
# every system has: glibc, GL, X11/Wayland, ALSA...).
"$tools/linuxdeploy" --appdir "$appdir" --library "$libmpv"
# GTK's own stack must come from the system too: an older bundled GLib or
# libstdc++ in LD_LIBRARY_PATH would break the system's GTK on newer distros.
(cd "$appdir/usr/lib" && rm -f libglib-2.0.so* libgio-2.0.so* libgobject-2.0.so* libgmodule-2.0.so* \
  libgthread-2.0.so* libffi.so* libcairo*.so* libpango*.so* libharfbuzz*.so* libfontconfig.so* \
  libfreetype.so* libpixman-1.so* libgdk_pixbuf-2.0.so* libglycin*.so* libdbus-1.so* libsystemd.so* \
  libblkid.so* libmount.so* libselinux.so* libpcre2-*.so* libz.so* libstdc++.so* libgcc_s.so* \
  libpng16.so* libexpat.so* libuuid.so* libbsd.so* libmd.so* libdatrie.so* libthai.so* libgraphite2.so*)

# media_kit tries "libmpv.so" first; make that the bundled one too, or a
# system libmpv would load against the bundled FFmpeg.
ln -sf libmpv.so.2 "$appdir/usr/lib/libmpv.so"

cp linux/packaging/openmusic.desktop "$appdir/openmusic.desktop"
cp linux/runner/openmusic.png "$appdir/openmusic.png"
ln -sf openmusic.png "$appdir/.DirIcon"
cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
# media_kit dlopen()s libmpv by name; let it find the bundled one.
export LD_LIBRARY_PATH="$here/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$here/usr/share/openmusic/openmusic" "$@"
APPRUN
chmod +x "$appdir/AppRun"

ARCH=x86_64 "$tools/appimagetool" --no-appstream "$appdir" "$out"
