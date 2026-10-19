#!/usr/bin/env bash
# Unit tests for the platform-independent part of the ASIO audio output
# (third_party/mpv_asio/asio_samples.*): writing the sample formats ASIO
# drivers take. Runs on Linux; tool/test_asio_wine.sh tests the rest.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
c++ -std=c++17 -O1 -Wall -Wextra -Werror -fsanitize=address,undefined -Ithird_party/mpv_asio \
  third_party/mpv_asio/asio_samples.cpp third_party/mpv_asio/test/asio_samples_test.cpp -o "$work/test"
"$work/test"
