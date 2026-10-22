#!/usr/bin/env bash
# Prints `flutter build` version flags for CI: the tag's version (v1.2.3 ->
# 1.2.3) and a build number from the workflow run. Prints nothing when the
# build isn't for a version tag, so pubspec.yaml's version is used.
#
# The build number is also Android's versionCode, the same for every APK
# (see the Android job). It starts at 10000: up to 1.6.0 the per-ABI APKs got
# 1000-4000 added to the run number, and a phone that installed one of those
# must see every later APK as newer, or it refuses to update.
set -euo pipefail
if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  echo "--build-name=${GITHUB_REF_NAME#v} --build-number=$((10000 + GITHUB_RUN_NUMBER))"
fi
