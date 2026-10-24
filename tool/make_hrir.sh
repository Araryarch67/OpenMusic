#!/usr/bin/env bash
# Makes assets/audio/hrir_kemar_48k.wav, the head-related impulse responses
# behind Virtual speakers: two loudspeakers at ±30° (the stereo triangle), as
# heard by each ear of MIT's KEMAR dummy head, diffuse-field equalized.
#
#   tool/make_hrir.sh            -> assets/audio/hrir_kemar_48k.wav
#
# Four channels, in FFmpeg `headphone=hrir=multich` order: left speaker to the
# left ear, left speaker to the right ear, right speaker to the left ear, right
# speaker to the right ear. 48 kHz, 32-bit float.
#
# Gain: the IR is scaled so no frequency comes out louder than it went in,
# whatever the two channels hold (max over f of |ipsi| + |contra| is 0 dB), as
# the equalizer's headroom does. Resampling an IR keeps its sample values, so
# its gain also grows by the rate ratio; that is taken back out.
#
# Data: Bill Gardner and Keith Martin, "HRTF Measurements of a KEMAR
# Dummy-Head Microphone", MIT Media Lab, 1994. Free to use provided the authors
# are cited (assets/audio/HRIR-NOTICE.txt). Needs curl, bsdtar, ffmpeg with
# soxr, python3 with numpy.
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

url=https://sound.media.mit.edu/resources/KEMAR/diffuse.zip
sum=a48e73137390626ef1e45d1de6a4d98530c6aa570e71b40f7c4442241ed5fa22
curl -fsSL -o "$work/diffuse.zip" "$url"
echo "$sum  $work/diffuse.zip" | sha256sum -c --quiet
mkdir "$work/d" && bsdtar -xf "$work/diffuse.zip" -C "$work/d"

# A source 30° to the right: channel 1 is the far (left) ear, channel 2 the near one.
ffmpeg -hide_banner -loglevel error -i "$work/d/elev0/H0e030a.wav" \
  -af "aresample=48000:resampler=soxr:precision=28" -f f32le -c:a pcm_f32le "$work/r.raw"

python3 - "$work/r.raw" "$work/hrir.raw" <<'EOF'
import sys
import numpy as np

x = np.fromfile(sys.argv[1], dtype='<f4').reshape(-1, 2).astype(np.float64)
x *= 44100 / 48000
contra, ipsi = x[:, 0], x[:, 1]
n, rate = 1 << 14, 48000
f = np.fft.rfftfreq(n, 1 / rate)
band = (f >= 20) & (f <= 20000)
worst = (np.abs(np.fft.rfft(ipsi, n)) + np.abs(np.fft.rfft(contra, n)))[band].max()
x /= worst
# The head is taken as symmetric: the left speaker is the right one mirrored.
out = np.stack([x[:, 1], x[:, 0], x[:, 0], x[:, 1]], axis=1).astype('<f4')
out.tofile(sys.argv[2])
print(f'{len(out)} taps, {20 * np.log10(1 / worst):.2f} dB')
EOF

mkdir -p "$project/assets/audio"
ffmpeg -hide_banner -loglevel error -y -f f32le -ar 48000 -ac 4 -i "$work/hrir.raw" -c:a pcm_f32le \
  -map_metadata -1 -fflags +bitexact "$project/assets/audio/hrir_kemar_48k.wav"
echo "Made $project/assets/audio/hrir_kemar_48k.wav"
