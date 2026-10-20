#!/usr/bin/env bash
# Prints the app version for package names: the tag's (v1.2.3 -> 1.2.3) on a
# tag build, else pubspec.yaml's (without the +build part).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  echo "${GITHUB_REF_NAME#v}"
else
  sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml
fi
