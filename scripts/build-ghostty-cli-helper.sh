#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build-ghostty-cli-helper.sh [--universal | --target <zig-target>] --output <path>

Options:
  --universal      Build a universal macOS helper (arm64 + x86_64).
  --target <triple>
                   Build a single target, e.g. `aarch64-macos` or `x86_64-macos`.
  --output <path>  Destination path for the built helper.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/ghostty"

OUTPUT_PATH=""
TARGET_TRIPLE=""
UNIVERSAL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal)
      UNIVERSAL="true"
      shift
      ;;
    --target)
      TARGET_TRIPLE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_PATH" ]]; then
  echo "Missing required --output path" >&2
  usage >&2
  exit 1
fi

# Allow CI to skip the zig build (e.g., macOS 26 where zig 0.15.2 can't link).
# Creates a stub binary so the Xcode Run Script file-existence check passes.
if [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  echo "Skipping zig CLI helper build (CMUX_SKIP_ZIG_BUILD=1)"
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  printf '#!/bin/sh\necho "ghostty CLI helper stub (zig build skipped)" >&2\nexit 1\n' > "$OUTPUT_PATH"
  chmod +x "$OUTPUT_PATH"
  exit 0
fi

if [[ "$UNIVERSAL" == "true" && -n "$TARGET_TRIPLE" ]]; then
  echo "--universal and --target are mutually exclusive" >&2
  usage >&2
  exit 1
fi

if [[ -n "$TARGET_TRIPLE" ]]; then
  case "$TARGET_TRIPLE" in
    aarch64-macos|x86_64-macos)
      ;;
    *)
      echo "Unsupported --target value: $TARGET_TRIPLE" >&2
      exit 1
      ;;
  esac

  # When the requested target matches zig's native output arch, drop -Dtarget
  # so zig uses native compilation. This avoids cross-linker issues on newer
  # SDKs (e.g., macOS Tahoe + zig 0.15.x). Note: zig may run under Rosetta,
  # so we detect native output arch from the zig binary itself, not uname -m.
  ZIG_ARCH="$(file "$(command -v zig)" 2>/dev/null | grep -oE '(arm64|x86_64)' | head -1)"
  case "$TARGET_TRIPLE" in
    aarch64-macos) [[ "$ZIG_ARCH" == "arm64" ]] && TARGET_TRIPLE="" ;;
    x86_64-macos)  [[ "$ZIG_ARCH" == "x86_64" ]] && TARGET_TRIPLE="" ;;
  esac
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig is required to build the Ghostty CLI helper" >&2
  exit 1
fi

if [[ ! -f "$GHOSTTY_DIR/build.zig" ]]; then
  echo "error: Ghostty submodule is missing at $GHOSTTY_DIR" >&2
  exit 1
fi

ghostty_version_string_override() {
  local exact_tag=""
  exact_tag="$(git -C "$GHOSTTY_DIR" describe --exact-match --tags 2>/dev/null || true)"
  if [[ -z "$exact_tag" ]]; then
    return 0
  fi

  case "$exact_tag" in
    tip|v[0-9]*.[0-9]*.[0-9]*)
      return 0
      ;;
  esac

  # Ghostty treats any exact tag as a release tag unless an explicit version is
  # provided. Our checkout is often pinned at internal cache tags such as
  # `xcframework-<sha>`, which are not valid Ghostty release versions and cause
  # the helper build to panic. In that case, force the build.zig.zon version so
  # the helper stays on the normal dev-build path.
  sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$GHOSTTY_DIR/build.zig.zon" \
    | head -n 1
}

build_helper() {
  local prefix="$1"
  local target="${2:-}"
  local version_override
  version_override="$(ghostty_version_string_override)"
  local args=(
    zig build
    cli-helper
    -Dapp-runtime=none
    -Demit-macos-app=false
    -Demit-xcframework=false
    -Doptimize=ReleaseFast
    --prefix
    "$prefix"
  )

  if [[ -n "$target" ]]; then
    args+=("-Dtarget=$target")
  fi
  if [[ -n "$version_override" ]]; then
    args+=("-Dversion-string=$version_override")
  fi

  (
    cd "$GHOSTTY_DIR"
    "${args[@]}"
  )
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$(dirname "$OUTPUT_PATH")"

if [[ "$UNIVERSAL" == "true" ]]; then
  ARM64_PREFIX="$TMP_DIR/arm64"
  X86_PREFIX="$TMP_DIR/x86_64"
  ZIG_ARCH="$(file "$(command -v zig)" 2>/dev/null | grep -oE '(arm64|x86_64)' | head -1)"
  # Use native compilation for the matching arch to avoid cross-linker issues
  if [[ "$ZIG_ARCH" == "arm64" ]]; then
    build_helper "$ARM64_PREFIX" ""
    build_helper "$X86_PREFIX" "x86_64-macos"
  elif [[ "$ZIG_ARCH" == "x86_64" ]]; then
    build_helper "$ARM64_PREFIX" "aarch64-macos"
    build_helper "$X86_PREFIX" ""
  else
    build_helper "$ARM64_PREFIX" "aarch64-macos"
    build_helper "$X86_PREFIX" "x86_64-macos"
  fi
  /usr/bin/lipo -create \
    "$ARM64_PREFIX/bin/ghostty" \
    "$X86_PREFIX/bin/ghostty" \
    -output "$OUTPUT_PATH"
else
  SINGLE_PREFIX="$TMP_DIR/single"
  build_helper "$SINGLE_PREFIX" "$TARGET_TRIPLE"
  install -m 755 "$SINGLE_PREFIX/bin/ghostty" "$OUTPUT_PATH"
fi

chmod +x "$OUTPUT_PATH"
