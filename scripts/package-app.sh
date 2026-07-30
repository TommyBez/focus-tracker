#!/bin/bash

set -euo pipefail
IFS=$'\n\t'
umask 022

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly PACKAGE_PARENT="$REPO_ROOT/zig-out/package"
readonly CANONICAL_APP="$PACKAGE_PARENT/focus-tracker.app"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"

TRANSACTION_DIR=""
TEMP_APP=""
BACKUP_APP=""
REPLACEMENT_STARTED=0
REPLACEMENT_COMMITTED=0
NEW_APP_PUBLICATION_STARTED=0

usage() {
  cat <<'EOF'
Build and safely publish a fresh ReleaseFast Focus Tracker.app.

Usage:
  scripts/package-app.sh

The Native SDK package is always written to a new same-filesystem temporary
bundle, validated, and only then replaces zig-out/package/focus-tracker.app.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

pass() {
  printf '  [pass] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

safe_remove_transaction() {
  [[ -n "$TRANSACTION_DIR" ]] || return 0
  if [[ "$TRANSACTION_DIR" == "$PACKAGE_PARENT"/.focus-tracker-package.* ]]; then
    /bin/rm -rf -- "$TRANSACTION_DIR"
  else
    printf 'warning: refusing cleanup outside the package transaction area: %s\n' "$TRANSACTION_DIR" >&2
  fi
}

rollback_replacement() {
  local rollback_failed=0

  [[ "$REPLACEMENT_STARTED" -eq 1 && "$REPLACEMENT_COMMITTED" -eq 0 ]] || return 0
  printf 'warning: app replacement did not commit; restoring the previous bundle\n' >&2

  if [[ "$NEW_APP_PUBLICATION_STARTED" -eq 1 && -e "$CANONICAL_APP" ]]; then
    [[ "$CANONICAL_APP" == "$REPO_ROOT/zig-out/package/focus-tracker.app" ]] || return 1
    /bin/rm -rf -- "$CANONICAL_APP" || rollback_failed=1
  fi
  if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]]; then
    mv -- "$BACKUP_APP" "$CANONICAL_APP" || rollback_failed=1
  fi

  if [[ "$rollback_failed" -ne 0 ]]; then
    printf 'error: automatic app rollback was incomplete; inspect %s and %s\n' "$CANONICAL_APP" "$TRANSACTION_DIR" >&2
    return 1
  fi
  return 0
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if ! rollback_replacement; then
    status=1
  fi
  safe_remove_transaction
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      [[ $# -eq 1 ]] || die "--help does not accept additional arguments"
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
fi

for tool in native codesign find awk grep file; do
  require_command "$tool"
done
[[ -x "$PLIST_BUDDY" ]] || die "required command not found: $PLIST_BUDDY"

validate_app() {
  local app="$1"
  local phase="$2"
  local plist="$app/Contents/Info.plist"
  local resources="$app/Contents/Resources"
  local manifest="$resources/package-manifest.zon"
  local executable_name
  local executable
  local packaging_leaks
  local optimize
  local signing
  local signing_info
  local cdhash

  [[ -d "$app" && ! -L "$app" ]] || die "$phase app is not a regular bundle directory: $app"
  [[ -f "$plist" ]] || die "$phase app is missing Contents/Info.plist"
  [[ -d "$resources" ]] || die "$phase app is missing Contents/Resources"
  [[ -f "$manifest" ]] || die "$phase app is missing package-manifest.zon"

  executable_name="$($PLIST_BUDDY -c 'Print :CFBundleExecutable' "$plist")"
  executable="$app/Contents/MacOS/$executable_name"
  [[ -f "$executable" && -x "$executable" ]] || die "$phase app executable is missing or not executable"
  file "$executable" | grep -q 'Mach-O' || die "$phase app executable is not Mach-O"

  packaging_leaks="$(find "$resources" \
    \( -type f -name 'dmg-*' -o -path '*/packaging' -o -path '*/packaging/*' \) \
    -print)"
  if [[ -n "$packaging_leaks" ]]; then
    printf '%s app contains packaging-only resources:\n%s\n' "$phase" "$packaging_leaks" >&2
    die "$phase app leaked DMG packaging assets"
  fi

  optimize="$(awk -F'"' '/^[[:space:]]*\.optimize[[:space:]]*=/ {print $2; exit}' "$manifest")"
  [[ "$optimize" == "ReleaseFast" ]] || die "$phase package manifest optimize is '$optimize', expected 'ReleaseFast'"
  signing="$(awk -F'"' '/^[[:space:]]*\.signing[[:space:]]*=/ {print $2; exit}' "$manifest")"
  [[ "$signing" == "adhoc" ]] || die "$phase package manifest signing is '$signing', expected 'adhoc'"

  codesign --verify --deep --strict --verbose=2 "$app"
  signing_info="$(codesign -dvvv "$app" 2>&1)"
  printf '%s\n' "$signing_info" | grep -q '^Signature=adhoc$' || die "$phase app is not ad-hoc signed"
  cdhash="$(printf '%s\n' "$signing_info" | awk -F= '/^CDHash=/ {print $2; exit}')"
  [[ -n "$cdhash" ]] || die "$phase app has no readable outer CDHash"

  pass "$phase app is fresh, ReleaseFast, ad-hoc signed, and free of DMG resources"
  pass "$phase outer app CDHash: $cdhash"
}

mkdir -p -- "$PACKAGE_PARENT"
[[ ! -L "$CANONICAL_APP" ]] || die "refusing to replace a symlink: $CANONICAL_APP"
[[ ! -e "$CANONICAL_APP" || -d "$CANONICAL_APP" ]] || die "canonical app path is not a directory: $CANONICAL_APP"

TRANSACTION_DIR="$(mktemp -d "$PACKAGE_PARENT/.focus-tracker-package.XXXXXX")"
TEMP_APP="$TRANSACTION_DIR/focus-tracker.app"
BACKUP_APP="$TRANSACTION_DIR/previous-focus-tracker.app"

note "Building ReleaseFast binary"
native build -Doptimize=ReleaseFast

note "Packaging into a fresh app bundle"
native package \
  --target macos \
  --signing adhoc \
  --optimize ReleaseFast \
  --output "$TEMP_APP"

note "Validating fresh package before replacement"
validate_app "$TEMP_APP" "Temporary"

REPLACEMENT_STARTED=1
if [[ -d "$CANONICAL_APP" ]]; then
  mv -- "$CANONICAL_APP" "$BACKUP_APP"
fi
NEW_APP_PUBLICATION_STARTED=1
mv -- "$TEMP_APP" "$CANONICAL_APP"

note "Validating canonical package after replacement"
validate_app "$CANONICAL_APP" "Canonical"
REPLACEMENT_COMMITTED=1

printf '\nApp package ready\n'
printf '  Bundle: %s\n' "$CANONICAL_APP"
printf '  Build:  ReleaseFast\n'
printf '  Signing: local ad-hoc app signature (not Developer ID or notarized)\n'
