#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/opennomi-connection-test.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
swiftc -parse-as-library \
  "$project_root/OpenNomi/XiaozhiServerConfiguration.swift" \
  "$project_root/scripts/connection-regression.swift" \
  -o "$test_directory/connection-regression"
"$test_directory/connection-regression"
