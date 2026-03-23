#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/1960.
# Ensures cmux signs Sparkle inside-out without --deep and without app entitlements on Sparkle helpers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/codesign_app_bundle.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_PATH="$TMP_DIR/cmux.app"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
OTHER_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sentry.framework"
CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"
HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
ENTITLEMENTS="cmux.entitlements"

WORKFLOWS=(
  "$ROOT_DIR/.github/workflows/release.yml"
  "$ROOT_DIR/.github/workflows/nightly.yml"
  "$ROOT_DIR/scripts/build-sign-upload.sh"
)

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: missing signing helper at $SCRIPT"
  exit 1
fi

mkdir -p \
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION_DIR/Updater.app" \
  "$OTHER_FRAMEWORK" \
  "$(dirname "$CLI_PATH")"
ln -s B "$SPARKLE_FRAMEWORK/Versions/Current"
touch \
  "$SPARKLE_VERSION_DIR/Autoupdate" \
  "$CLI_PATH" \
  "$HELPER_PATH"

for workflow in "${WORKFLOWS[@]}"; do
  if ! grep -Fq './scripts/codesign_app_bundle.sh' "$workflow"; then
    echo "FAIL: $workflow must use scripts/codesign_app_bundle.sh"
    exit 1
  fi
done

OUTPUT="$(
  CMUX_CODESIGN_DRY_RUN=1 \
  "$SCRIPT" "$APP_PATH" "Developer ID Application: Example" "$ENTITLEMENTS"
)"

line_number_regex() {
  local pattern="$1"
  printf '%s\n' "$OUTPUT" | nl -ba | grep -E -- "$pattern" | awk 'NR==1 {print $1}'
}

installer_line="$(line_number_regex 'Installer\.xpc$')"
downloader_line="$(line_number_regex 'Downloader\.xpc$')"
autoupdate_line="$(line_number_regex '/Autoupdate$')"
updater_line="$(line_number_regex 'Updater\.app$')"
sparkle_line="$(line_number_regex 'Sparkle\.framework$')"
sentry_line="$(line_number_regex 'Sentry\.framework$')"
cli_line="$(line_number_regex '/Resources/bin/cmux$')"
helper_line="$(line_number_regex '/Resources/bin/ghostty$')"
app_line="$(line_number_regex '--entitlements cmux\.entitlements .*/cmux\.app$')"
verify_line="$(line_number_regex '--verify --deep --strict --verbose=2 .*/cmux\.app$')"

for value_name in installer_line downloader_line autoupdate_line updater_line sparkle_line sentry_line cli_line helper_line app_line verify_line; do
  if [ -z "${!value_name}" ]; then
    echo "FAIL: expected $value_name in signing plan"
    printf '%s\n' "$OUTPUT"
    exit 1
  fi
done

if [ "$installer_line" -ge "$sparkle_line" ] || [ "$downloader_line" -ge "$sparkle_line" ] || [ "$autoupdate_line" -ge "$sparkle_line" ] || [ "$updater_line" -ge "$sparkle_line" ]; then
  echo "FAIL: Sparkle nested components must be signed before Sparkle.framework"
  exit 1
fi

if [ "$sparkle_line" -ge "$sentry_line" ] || [ "$sentry_line" -ge "$cli_line" ] || [ "$helper_line" -ge "$app_line" ] || [ "$app_line" -ge "$verify_line" ]; then
  echo "FAIL: signing order is incorrect"
  exit 1
fi

for sparkle_component in Installer.xpc Downloader.xpc /Autoupdate Updater.app Sparkle.framework Sentry.framework; do
  if printf '%s\n' "$OUTPUT" | grep -F "$sparkle_component" | grep -Fq -- '--entitlements'; then
    echo "FAIL: $sparkle_component must not be signed with app entitlements"
    exit 1
  fi
done

for entitled_component in /Resources/bin/cmux /Resources/bin/ghostty /cmux.app; do
  if ! printf '%s\n' "$OUTPUT" | grep -F "$entitled_component" | grep -Fv -- '--verify' | grep -Fq -- "--entitlements $ENTITLEMENTS"; then
    echo "FAIL: $entitled_component must be signed with app entitlements"
    exit 1
  fi
done

if printf '%s\n' "$OUTPUT" | grep -F '/cmux.app' | grep -Fv -- '--verify' | grep -Fq -- '--deep'; then
  echo "FAIL: app signing must not use --deep"
  exit 1
fi

echo "PASS: app signing plan signs Sparkle inside-out without --deep"
