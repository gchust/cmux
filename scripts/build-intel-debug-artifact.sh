#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build-intel-debug-artifact.sh --tag <name> [options]

Build a tagged x86_64 Debug app, package it with provenance metadata, and
optionally send the tarball over Tailscale.

Options:
  --tag <name>           Required. Tag used for the app name, bundle ID, sockets,
                         DerivedData path, and artifact names.
  --output-root <dir>    Where to place the unpacked artifact folder and tarball.
                         Default: ./.artifacts
  --send-to <host>       Optional. Send the tarball and metadata JSON via
                         `tailscale file cp` to the given host after packaging.
  -h, --help             Show this help.
EOF
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool not found: $tool" >&2
    exit 1
  fi
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.//; s/\.$//; s/\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="intel"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="intel"
  fi
  echo "$cleaned"
}

plist_set_string() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$plist" >/dev/null
}

plist_set_or_create_dict_string() {
  local plist="$1"
  local dict_key="$2"
  local key="$3"
  local value="$4"
  /usr/libexec/PlistBuddy -c "Add :${dict_key} dict" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Set :${dict_key}:${key} ${value}" "$plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :${dict_key}:${key} string ${value}" "$plist" >/dev/null
}

main_binary_archs() {
  local binary_path="$1"
  /usr/bin/lipo -archs "$binary_path" 2>/dev/null || true
}

validate_macho_architectures() {
  local app_path="$1"
  local report_path="$2"
  local target_arch="$3"

  : > "$report_path"
  while IFS= read -r -d '' path; do
    local description
    description="$(file -b "$path" 2>/dev/null || true)"
    [[ "$description" == *"Mach-O"* ]] || continue

    local archs
    archs="$(/usr/bin/lipo -archs "$path" 2>/dev/null || true)"
    if [[ -z "$archs" ]]; then
      echo "error: could not inspect Mach-O architectures for $path" >&2
      exit 1
    fi
    if [[ " $archs " != *" ${target_arch} "* ]]; then
      echo "error: $path is missing ${target_arch} support (${archs})" >&2
      exit 1
    fi

    printf '%s\t%s\n' "$path" "$archs" >> "$report_path"
  done < <(find "$app_path" -type f -print0)
}

write_metadata_json() {
  local metadata_path="$1"
  local repo_status_path="$2"
  local bonsplit_status_path="$3"
  local artifact_dir="$4"
  local report_path="$5"
  local tarball_path="$6"
  local tag="$7"
  local tag_slug="$8"
  local bundle_id="$9"
  local app_name="${10}"
  local app_path="${11}"
  local derived_data="${12}"
  local xcode_log="${13}"
  local repo_head="${14}"
  local bonsplit_head="${15}"
  local cmux_commit="${16}"
  local app_binary_archs="${17}"
  local helper_archs="${18}"
  local plugin_archs="${19}"
  local tar_sha="${20}"

  python3 - <<'PY' \
    "$metadata_path" \
    "$repo_status_path" \
    "$bonsplit_status_path" \
    "$artifact_dir" \
    "$report_path" \
    "$tarball_path" \
    "$tag" \
    "$tag_slug" \
    "$bundle_id" \
    "$app_name" \
    "$app_path" \
    "$derived_data" \
    "$xcode_log" \
    "$repo_head" \
    "$bonsplit_head" \
    "$cmux_commit" \
    "$app_binary_archs" \
    "$helper_archs" \
    "$plugin_archs" \
    "$tar_sha"
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    metadata_path,
    repo_status_path,
    bonsplit_status_path,
    artifact_dir,
    report_path,
    tarball_path,
    tag,
    tag_slug,
    bundle_id,
    app_name,
    app_path,
    derived_data,
    xcode_log,
    repo_head,
    bonsplit_head,
    cmux_commit,
    app_binary_archs,
    helper_archs,
    plugin_archs,
    tar_sha,
) = sys.argv[1:]

def read_lines(path: str):
    text = Path(path).read_text(encoding="utf-8")
    return [line for line in text.splitlines() if line.strip()]

metadata = {
    "generatedAtUTC": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "tag": tag,
    "tagSlug": tag_slug,
    "targetArch": "x86_64",
    "bundleID": bundle_id,
    "appName": app_name,
    "appPath": app_path,
    "artifactDirectory": artifact_dir,
    "derivedDataPath": derived_data,
    "xcodebuildLogPath": xcode_log,
    "tarballPath": tarball_path,
    "tarballSHA256": tar_sha,
    "repoHead": repo_head,
    "repoStatus": read_lines(repo_status_path),
    "bonsplitHead": bonsplit_head,
    "bonsplitStatus": read_lines(bonsplit_status_path),
    "infoPlistCMUXCommit": cmux_commit,
    "appBinaryArchitectures": app_binary_archs.split(),
    "ghosttyHelperArchitectures": helper_archs.split(),
    "dockPluginArchitectures": plugin_archs.split(),
    "machoArchitectureReportPath": report_path,
}

Path(metadata_path).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

TAG=""
OUTPUT_ROOT="$PWD/.artifacts"
SEND_TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --output-root)
      OUTPUT_ROOT="${2:-}"
      if [[ -z "$OUTPUT_ROOT" ]]; then
        echo "error: --output-root requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --send-to)
      SEND_TO="${2:-}"
      if [[ -z "$SEND_TO" ]]; then
        echo "error: --send-to requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required" >&2
  usage >&2
  exit 1
fi

require_tool xcodebuild
require_tool python3
require_tool file
require_tool lipo
require_tool codesign
require_tool shasum
require_tool tar

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

"$REPO_ROOT/scripts/ensure-ghosttykit.sh"

TAG_ID="$(sanitize_bundle "$TAG")"
TAG_SLUG="$(sanitize_path "$TAG")"
ARTIFACT_SLUG="${TAG_SLUG}-intel-x86_64"
APP_NAME="cmux DEV ${TAG}"
BUNDLE_ID="com.cmuxterm.app.debug.${TAG_ID}"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}-intel-x86_64"
ARTIFACT_DIR="${OUTPUT_ROOT}/${ARTIFACT_SLUG}"
TAR_STAGING_DIR="${OUTPUT_ROOT}/${ARTIFACT_SLUG}-tar"
TARBALL_PATH="${OUTPUT_ROOT}/cmux-DEV-${ARTIFACT_SLUG}.tar.gz"
EXTERNAL_METADATA_PATH="${OUTPUT_ROOT}/cmux-DEV-${ARTIFACT_SLUG}.metadata.json"
XCODE_LOG="/tmp/cmux-xcodebuild-${ARTIFACT_SLUG}.log"
CLANG_WRAPPER="$REPO_ROOT/scripts/clang-xcodebuild-wrapper.sh"
XCODEBUILD_ENV=(env)
if [[ -x "$CLANG_WRAPPER" ]]; then
  XCODEBUILD_ENV+=(CC="$CLANG_WRAPPER" CXX="$CLANG_WRAPPER")
fi

rm -rf "$ARTIFACT_DIR" "$TAR_STAGING_DIR"
mkdir -p "$ARTIFACT_DIR" "$OUTPUT_ROOT"

set +e
"${XCODEBUILD_ENV[@]}" xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  build \
  2>&1 | tee "$XCODE_LOG" | grep -E '(warning:|error:|fatal:|BUILD FAILED|BUILD SUCCEEDED|\*\* BUILD)'
XCODE_PIPESTATUS=("${PIPESTATUS[@]}")
set -e
XCODE_EXIT="${XCODE_PIPESTATUS[0]}"
if [[ "$XCODE_EXIT" -ne 0 ]]; then
  echo "error: xcodebuild failed with exit code $XCODE_EXIT" >&2
  echo "Full build log: $XCODE_LOG" >&2
  exit "$XCODE_EXIT"
fi

SOURCE_APP_PATH="${DERIVED_DATA}/Build/Products/Debug/cmux DEV.app"
PACKAGED_APP_PATH="${ARTIFACT_DIR}/${APP_NAME}.app"
if [[ ! -d "$SOURCE_APP_PATH" ]]; then
  echo "error: built app not found at $SOURCE_APP_PATH" >&2
  exit 1
fi

cp -R "$SOURCE_APP_PATH" "$PACKAGED_APP_PATH"

INFO_PLIST="${PACKAGED_APP_PATH}/Contents/Info.plist"
plist_set_string "$INFO_PLIST" "CFBundleName" "$APP_NAME"
plist_set_string "$INFO_PLIST" "CFBundleDisplayName" "$APP_NAME"
plist_set_string "$INFO_PLIST" "CFBundleIdentifier" "$BUNDLE_ID"
plist_set_string "$INFO_PLIST" "CMUXBuildTag" "$TAG"
plist_set_string "$INFO_PLIST" "CMUXBuildTargetArch" "x86_64"
plist_set_or_create_dict_string "$INFO_PLIST" "LSEnvironment" "CMUX_TAG" "$TAG_SLUG"
plist_set_or_create_dict_string "$INFO_PLIST" "LSEnvironment" "CMUX_SOCKET_ENABLE" "1"
plist_set_or_create_dict_string "$INFO_PLIST" "LSEnvironment" "CMUX_SOCKET_MODE" "allowAll"
plist_set_or_create_dict_string "$INFO_PLIST" "LSEnvironment" "CMUX_SOCKET_PATH" "/tmp/cmux-debug-${TAG_SLUG}.sock"
plist_set_or_create_dict_string "$INFO_PLIST" "LSEnvironment" "CMUXD_UNIX_PATH" "/tmp/cmuxd-debug-${TAG_SLUG}.sock"
plist_set_or_create_dict_string "$INFO_PLIST" "LSEnvironment" "CMUX_DEBUG_LOG" "/tmp/cmux-debug-${TAG_SLUG}.log"

APP_BINARY="${PACKAGED_APP_PATH}/Contents/MacOS/cmux DEV"
HELPER_BINARY="${PACKAGED_APP_PATH}/Contents/Resources/bin/ghostty"
PLUGIN_BINARY="${PACKAGED_APP_PATH}/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin"

for required_path in "$APP_BINARY" "$HELPER_BINARY" "$PLUGIN_BINARY"; do
  if [[ ! -e "$required_path" ]]; then
    echo "error: required bundled binary missing: $required_path" >&2
    exit 1
  fi
done

APP_BINARY_ARCHS="$(main_binary_archs "$APP_BINARY")"
HELPER_ARCHS="$(main_binary_archs "$HELPER_BINARY")"
PLUGIN_ARCHS="$(main_binary_archs "$PLUGIN_BINARY")"

if [[ "$APP_BINARY_ARCHS" != "x86_64" ]]; then
  echo "error: app binary is not x86_64-only (${APP_BINARY_ARCHS})" >&2
  exit 1
fi
if [[ "$HELPER_ARCHS" != "x86_64" ]]; then
  echo "error: bundled ghostty helper is not x86_64-only (${HELPER_ARCHS})" >&2
  exit 1
fi
if [[ "$PLUGIN_ARCHS" != "x86_64" ]]; then
  echo "error: dock tile plugin is not x86_64-only (${PLUGIN_ARCHS})" >&2
  exit 1
fi

MACHO_REPORT_PATH="${ARTIFACT_DIR}/mach-o-architectures.txt"
validate_macho_architectures "$PACKAGED_APP_PATH" "$MACHO_REPORT_PATH" "x86_64"

cp "$XCODE_LOG" "${ARTIFACT_DIR}/xcodebuild.log"

REPO_STATUS_PATH="$(mktemp "${TMPDIR:-/tmp}/cmux-intel-repo-status.XXXXXX")"
BONSPLIT_STATUS_PATH="$(mktemp "${TMPDIR:-/tmp}/cmux-intel-bonsplit-status.XXXXXX")"
trap 'rm -f "$REPO_STATUS_PATH" "$BONSPLIT_STATUS_PATH"' EXIT
git status --short > "$REPO_STATUS_PATH"
git -C vendor/bonsplit status --short > "$BONSPLIT_STATUS_PATH"

REPO_HEAD="$(git rev-parse HEAD)"
BONSPLIT_HEAD="$(git -C vendor/bonsplit rev-parse HEAD)"
CMUX_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :CMUXCommit' "$INFO_PLIST" 2>/dev/null || true)"

METADATA_PATH="${ARTIFACT_DIR}/build-metadata.json"
write_metadata_json \
  "$METADATA_PATH" \
  "$REPO_STATUS_PATH" \
  "$BONSPLIT_STATUS_PATH" \
  "$ARTIFACT_DIR" \
  "$MACHO_REPORT_PATH" \
  "$TARBALL_PATH" \
  "$TAG" \
  "$TAG_SLUG" \
  "$BUNDLE_ID" \
  "$APP_NAME" \
  "$PACKAGED_APP_PATH" \
  "$DERIVED_DATA" \
  "$XCODE_LOG" \
  "$REPO_HEAD" \
  "$BONSPLIT_HEAD" \
  "$CMUX_COMMIT" \
  "$APP_BINARY_ARCHS" \
  "$HELPER_ARCHS" \
  "$PLUGIN_ARCHS" \
  ""

cp "$METADATA_PATH" "${PACKAGED_APP_PATH}/Contents/Resources/cmux-dev-build-metadata.json"
cp "$MACHO_REPORT_PATH" "${PACKAGED_APP_PATH}/Contents/Resources/cmux-dev-macho-architectures.txt"

/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$PACKAGED_APP_PATH" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$PACKAGED_APP_PATH" >/dev/null

mkdir -p "$TAR_STAGING_DIR"
cp -R "$ARTIFACT_DIR/." "$TAR_STAGING_DIR/"
COPYFILE_DISABLE=1 tar -C "$OUTPUT_ROOT" -czf "$TARBALL_PATH" "$(basename "$TAR_STAGING_DIR")"
TAR_SHA="$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')"

write_metadata_json \
  "$EXTERNAL_METADATA_PATH" \
  "$REPO_STATUS_PATH" \
  "$BONSPLIT_STATUS_PATH" \
  "$ARTIFACT_DIR" \
  "$MACHO_REPORT_PATH" \
  "$TARBALL_PATH" \
  "$TAG" \
  "$TAG_SLUG" \
  "$BUNDLE_ID" \
  "$APP_NAME" \
  "$PACKAGED_APP_PATH" \
  "$DERIVED_DATA" \
  "$XCODE_LOG" \
  "$REPO_HEAD" \
  "$BONSPLIT_HEAD" \
  "$CMUX_COMMIT" \
  "$APP_BINARY_ARCHS" \
  "$HELPER_ARCHS" \
  "$PLUGIN_ARCHS" \
  "$TAR_SHA"

if [[ -n "$SEND_TO" ]]; then
  require_tool tailscale
  tailscale file cp "$TARBALL_PATH" "$SEND_TO:"
  tailscale file cp "$EXTERNAL_METADATA_PATH" "$SEND_TO:"
fi

echo
echo "Artifact directory:"
echo "  $ARTIFACT_DIR"
echo
echo "App path:"
echo "  $PACKAGED_APP_PATH"
echo
echo "Tarball:"
echo "  $TARBALL_PATH"
echo
echo "Tarball SHA-256:"
echo "  $TAR_SHA"
echo
echo "Build metadata:"
echo "  $METADATA_PATH"
echo
echo "Transfer metadata:"
echo "  $EXTERNAL_METADATA_PATH"
