#!/usr/bin/env bash
# Adds the ASIO audio output to an mpv source tree (used by
# tool/build_libmpv_windows.sh). Usage: apply.sh <mpv-src> <openmusic-root>
set -euo pipefail
mpv=$1
here=$(cd "$(dirname "$0")" && pwd)
sdk=$2/third_party/asiosdk

mkdir -p "$mpv/audio/out/asio/sdk"
cp "$here/ao_asio.c" "$mpv/audio/out/"
cp "$here/asio_host.h" "$here/asio_host.cpp" "$here/asio_samples.h" "$here/asio_samples.cpp" "$mpv/audio/out/asio/"
cp -r "$sdk/common" "$sdk/host" "$mpv/audio/out/asio/sdk/"
# The SDK's driver list is written against the ANSI Windows API.
for f in common/asio host/asiodrivers host/pc/asiolist; do
  printf '#undef UNICODE\n#undef _UNICODE\n#include "sdk/%s.cpp"\n' "$f" >"$mpv/audio/out/asio/sdk_$(basename "$f").cpp"
done

python3 - "$mpv" <<'EOF'
import sys
mpv = sys.argv[1]

def patch(path, old, new):
    p = f"{mpv}/{path}"
    s = open(p).read()
    if new in s:
        return
    assert s.count(old) == 1, (path, old)
    open(p, "w").write(s.replace(old, new))

patch("meson_options.txt",
      "option('wasapi', type: 'feature', value: 'auto', description: 'WASAPI audio output')\n",
      "option('wasapi', type: 'feature', value: 'auto', description: 'WASAPI audio output')\n"
      "option('asio', type: 'feature', value: 'auto', description: 'ASIO audio output (OpenMusic)')\n")

patch("meson.build",
      "                     'audio/out/ao_wasapi_utils.c')\nendif\n",
      "                     'audio/out/ao_wasapi_utils.c')\nendif\n"
      "\n"
      "asio = get_option('asio').require(features['win32-desktop'] and get_option('gpl')).allowed()\n"
      "features += {'asio': asio}\n"
      "if features['asio']\n"
      "    add_languages('cpp', native: false)\n"
      "    # Its own library: mpv's include path has a pthread shim that breaks C++.\n"
      "    asio_host = static_library('asio_host',\n"
      "        files('audio/out/asio/asio_host.cpp', 'audio/out/asio/asio_samples.cpp',\n"
      "              'audio/out/asio/sdk_asio.cpp', 'audio/out/asio/sdk_asiodrivers.cpp',\n"
      "              'audio/out/asio/sdk_asiolist.cpp'),\n"
      "        include_directories: include_directories('audio/out/asio/sdk/common',\n"
      "                                                 'audio/out/asio/sdk/host',\n"
      "                                                 'audio/out/asio/sdk/host/pc'),\n"
      "        cpp_args: ['-std=c++17', '-w'])\n"
      "    dependencies += [declare_dependency(link_with: asio_host),\n"
      "                     cc.find_library('ole32'), cc.find_library('uuid'), cc.find_library('advapi32')]\n"
      "    sources += files('audio/out/ao_asio.c')\n"
      "endif\n")

# mpv of 2023 against newer mingw-w64 headers: ksmedia.h wants mmreg.h first.
patch("audio/out/ao_wasapi_utils.c",
      "#include <math.h>\n",
      "#include <math.h>\n#include <windows.h>\n#include <mmreg.h>\n")

patch("audio/out/ao.c",
      "extern const struct ao_driver audio_out_wasapi;\n",
      "extern const struct ao_driver audio_out_wasapi;\n"
      "extern const struct ao_driver audio_out_asio;\n")
# After WASAPI, so --audio-device=auto still picks WASAPI.
patch("audio/out/ao.c",
      "#if HAVE_WASAPI\n    &audio_out_wasapi,\n#endif\n",
      "#if HAVE_WASAPI\n    &audio_out_wasapi,\n#endif\n#if HAVE_ASIO\n    &audio_out_asio,\n#endif\n")
EOF
