#!/usr/bin/env bash
# Prints `flutter build` version flags for CI: the tag's version (v1.2.3 ->
# 1.2.3) and the workflow run number as the build number. Prints nothing when
# the build isn't for a version tag, so pubspec.yaml's version is used.
set -euo pipefail
if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  echo "--build-name=${GITHUB_REF_NAME#v} --build-number=${GITHUB_RUN_NUMBER}"
fi
