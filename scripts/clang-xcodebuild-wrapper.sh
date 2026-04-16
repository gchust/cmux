#!/usr/bin/env bash
set -euo pipefail

# Xcode 26's SWBBuildService can deadlock while running clang's build-probe
# command (`clang -v -E -dM ...`) because the combined stdout/stderr output
# crosses the small pipe buffer used for the probe. For local wrapper builds,
# drop only `-v` from that specific probe so the macro output stays available
# while the probe output stays below the deadlock threshold.

DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
DEVELOPER_DIR_PATH="${DEVELOPER_DIR_PATH%/}"
if [[ "$DEVELOPER_DIR_PATH" == *.app ]]; then
  DEVELOPER_DIR_PATH="${DEVELOPER_DIR_PATH}/Contents/Developer"
fi
REAL_CLANG="${DEVELOPER_DIR_PATH}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

if [[ ! -x "$REAL_CLANG" ]]; then
  echo "error: real clang not found at $REAL_CLANG" >&2
  exit 1
fi

has_preprocess_dump=0
has_macro_dump=0
for arg in "$@"; do
  if [[ "$arg" == "-E" ]]; then
    has_preprocess_dump=1
  elif [[ "$arg" == "-dM" ]]; then
    has_macro_dump=1
  fi
done

if [[ "$has_preprocess_dump" -eq 1 && "$has_macro_dump" -eq 1 ]]; then
  filtered_args=()
  for arg in "$@"; do
    if [[ "$arg" == "-v" ]]; then
      continue
    fi
    filtered_args+=("$arg")
  done
  exec "$REAL_CLANG" "${filtered_args[@]}"
fi

exec "$REAL_CLANG" "$@"
