#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly EXPECTED_BACKGROUND_WIDTH=660
readonly EXPECTED_BACKGROUND_HEIGHT=430
readonly BUNDLE_README_LINE="Local ad-hoc signed Native SDK macOS app bundle; not Developer ID signed or notarized."

SOURCE_APP="$REPO_ROOT/zig-out/package/focus-tracker.app"
EXPECTED_APP_NAME="Focus Tracker.app"
EXPECTED_VOLUME_NAME="Focus Tracker"
EXPECT_BACKGROUND=0
EXPECT_VOLUME_ICON=0
VERIFY_CHECKSUM=1
CHECKSUM_ONLY=0
DMG_PATH=""

WORK_DIR=""
MOUNT_POINT=""
IMAGE_ATTACHED=0

usage() {
  cat <<'EOF'
Verify the Focus Tracker DMG, its app, presentation assets, and checksum.

Usage:
  scripts/verify-dmg.sh [options] PATH.dmg

Options:
  --source-app PATH       Compare metadata and architectures with this .app.
  --volume-name NAME      Expected mounted volume name (default: Focus Tracker).
  --expect-background    Require the 660x430 pt Finder background and .DS_Store.
  --expect-volume-icon   Require a hidden .VolumeIcon.icns.
  --skip-checksum        Do not require PATH.dmg.sha256.
  --checksum-only        Verify only the published SHA-256 sidecar.
  -h, --help             Show this help.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '  [pass] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_existing_path() {
  local requested="$1"

  [[ -e "$requested" ]] || die "path does not exist: $requested"
  realpath "$requested"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if [[ "$IMAGE_ATTACHED" -eq 1 && -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi

  if [[ -n "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      "${TMPDIR:-/tmp}"/focus-tracker-dmg-verify.*) /bin/rm -rf -- "$WORK_DIR" ;;
      *) printf 'warning: refusing cleanup outside verification workspace: %s\n' "$WORK_DIR" >&2 ;;
    esac
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-app)
      [[ $# -ge 2 ]] || die "--source-app requires a path"
      SOURCE_APP="$2"
      shift 2
      ;;
    --expect-background)
      EXPECT_BACKGROUND=1
      shift
      ;;
    --volume-name)
      [[ $# -ge 2 ]] || die "--volume-name requires a value"
      EXPECTED_VOLUME_NAME="$2"
      shift 2
      ;;
    --expect-volume-icon)
      EXPECT_VOLUME_ICON=1
      shift
      ;;
    --skip-checksum)
      VERIFY_CHECKSUM=0
      shift
      ;;
    --checksum-only)
      CHECKSUM_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$DMG_PATH" ]] || die "only one DMG path may be provided"
      DMG_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$DMG_PATH" ]] || die "a DMG path is required"

for tool in hdiutil diskutil plutil codesign lipo shasum awk grep file sips readlink GetFileInfo realpath; do
  require_command "$tool"
done
[[ -x "$PLIST_BUDDY" ]] || die "required command not found: $PLIST_BUDDY"

DMG_PATH="$(resolve_existing_path "$DMG_PATH")"
[[ -f "$DMG_PATH" ]] || die "DMG is not a regular file: $DMG_PATH"
[[ "$DMG_PATH" == *.dmg ]] || die "image filename must end in .dmg"

verify_checksum() {
  local checksum_path="$DMG_PATH.sha256"
  local expected_hash
  local listed_name
  local actual_hash

  [[ -f "$checksum_path" ]] || die "checksum sidecar is missing: $checksum_path"
  IFS=' ' read -r expected_hash listed_name < "$checksum_path"
  listed_name="${listed_name#\*}"
  [[ "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]] || die "checksum sidecar does not start with a valid SHA-256 digest"
  [[ "$listed_name" == "$(basename -- "$DMG_PATH")" ]] || die "checksum sidecar names '$listed_name', expected '$(basename -- "$DMG_PATH")'"

  actual_hash="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || die "checksum mismatch: expected $expected_hash, found $actual_hash"
  pass "SHA-256 matches $expected_hash"
}

printf 'Verifying %s\n' "$DMG_PATH"

if [[ "$VERIFY_CHECKSUM" -eq 1 ]]; then
  verify_checksum
fi
if [[ "$CHECKSUM_ONLY" -eq 1 ]]; then
  printf 'Verification complete\n'
  exit 0
fi

SOURCE_APP="$(resolve_existing_path "$SOURCE_APP")"
[[ -d "$SOURCE_APP" ]] || die "source app is not a directory: $SOURCE_APP"

printf '  [check] UDIF structure\n'
hdiutil verify "$DMG_PATH" >/dev/null
pass "hdiutil verified every partition"

IMAGE_INFO="$(hdiutil imageinfo "$DMG_PATH")"
printf '%s\n' "$IMAGE_INFO" | grep -Eq 'Format:[[:space:]]+UDZO' || die "image is not compressed UDZO"
pass "image format is UDZO (zlib-compressed, read-only)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/focus-tracker-dmg-verify.XXXXXX")"
MOUNT_POINT="$WORK_DIR/mount"
mkdir -p -- "$MOUNT_POINT"

hdiutil attach \
  -readonly \
  -noverify \
  -noautoopen \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$DMG_PATH" >/dev/null
IMAGE_ATTACHED=1
pass "image mounts read-only"

MOUNTED_VOLUME_NAME="$(diskutil info -plist "$MOUNT_POINT" | plutil -extract VolumeName raw -)"
[[ "$MOUNTED_VOLUME_NAME" == "$EXPECTED_VOLUME_NAME" ]] || die "mounted volume is named '$MOUNTED_VOLUME_NAME', expected '$EXPECTED_VOLUME_NAME'"
pass "mounted volume name is $MOUNTED_VOLUME_NAME"

MOUNTED_APP="$MOUNT_POINT/$EXPECTED_APP_NAME"
[[ -d "$MOUNTED_APP" ]] || die "mounted image is missing $EXPECTED_APP_NAME"
MOUNTED_BUNDLE_README="$MOUNTED_APP/Contents/Resources/README.txt"
[[ -f "$MOUNTED_BUNDLE_README" ]] || die "mounted app is missing Contents/Resources/README.txt"
grep -Fqx "$BUNDLE_README_LINE" "$MOUNTED_BUNDLE_README" || \
  die "mounted app README does not describe its ad-hoc signing state accurately"
pass "mounted app accurately discloses local ad-hoc signing"
[[ -L "$MOUNT_POINT/Applications" ]] || die "mounted image is missing the Applications symlink"
APPLICATIONS_TARGET="$(readlink "$MOUNT_POINT/Applications")"
[[ "$APPLICATIONS_TARGET" == "/Applications" ]] || die "Applications symlink targets '$APPLICATIONS_TARGET', expected '/Applications'"
pass "mounted contents include $EXPECTED_APP_NAME and Applications -> /Applications"

APP_COUNT="$(find "$MOUNT_POINT" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[[ "$APP_COUNT" == "1" ]] || die "mounted image must contain exactly one top-level app (found $APP_COUNT)"

UNEXPECTED_VISIBLE="$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 ! -name '.*' ! -name "$EXPECTED_APP_NAME" ! -name 'Applications' -print)"
[[ -z "$UNEXPECTED_VISIBLE" ]] || die "mounted image has unexpected visible top-level payload: $UNEXPECTED_VISIBLE"
pass "no unexpected visible top-level payload is present"

UNEXPECTED_HIDDEN="$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -name '.*' \
  ! -name '.background' \
  ! -name '.DS_Store' \
  ! -name '.VolumeIcon.icns' \
  -print)"
if [[ -n "$UNEXPECTED_HIDDEN" ]]; then
  printf 'Unexpected hidden root payload:\n%s\n' "$UNEXPECTED_HIDDEN" >&2
  ls -laO@ "$MOUNT_POINT" >&2 || true
  die "mounted image contains hidden root payload outside the release whitelist"
fi
[[ ! -e "$MOUNT_POINT/.background" || -d "$MOUNT_POINT/.background" ]] || die ".background is not a directory"
[[ ! -e "$MOUNT_POINT/.VolumeIcon.icns" || -f "$MOUNT_POINT/.VolumeIcon.icns" ]] || die ".VolumeIcon.icns is not a regular file"
pass "hidden root payload is restricted to .background, .DS_Store, and .VolumeIcon.icns"

[[ -f "$MOUNT_POINT/.DS_Store" ]] || die "mounted image is missing Finder .DS_Store layout metadata"
pass "Finder layout metadata is present"

if [[ "$EXPECT_BACKGROUND" -eq 1 ]]; then
  MOUNTED_BACKGROUND="$MOUNT_POINT/.background/dmg-background.png"
  [[ -f "$MOUNTED_BACKGROUND" ]] || die "mounted image is missing .background/dmg-background.png"
  BACKGROUND_FORMAT="$(sips -g format "$MOUNTED_BACKGROUND" 2>/dev/null | awk '/format:/ {print $2}')"
  BACKGROUND_WIDTH="$(sips -g pixelWidth "$MOUNTED_BACKGROUND" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
  BACKGROUND_HEIGHT="$(sips -g pixelHeight "$MOUNTED_BACKGROUND" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
  BACKGROUND_DPI_WIDTH="$(sips -g dpiWidth "$MOUNTED_BACKGROUND" 2>/dev/null | awk '/dpiWidth:/ {print $2}')"
  BACKGROUND_DPI_HEIGHT="$(sips -g dpiHeight "$MOUNTED_BACKGROUND" 2>/dev/null | awk '/dpiHeight:/ {print $2}')"
  BACKGROUND_POINT_WIDTH="$(awk -v pixels="$BACKGROUND_WIDTH" -v dpi="$BACKGROUND_DPI_WIDTH" 'BEGIN { printf "%.0f", pixels * 72 / dpi }')"
  BACKGROUND_POINT_HEIGHT="$(awk -v pixels="$BACKGROUND_HEIGHT" -v dpi="$BACKGROUND_DPI_HEIGHT" 'BEGIN { printf "%.0f", pixels * 72 / dpi }')"
  [[ "$BACKGROUND_FORMAT" == "png" ]] || die "mounted Finder background is not a PNG"
  [[ "$BACKGROUND_POINT_WIDTH" == "$EXPECTED_BACKGROUND_WIDTH" && "$BACKGROUND_POINT_HEIGHT" == "$EXPECTED_BACKGROUND_HEIGHT" ]] || \
    die "mounted Finder background is ${BACKGROUND_POINT_WIDTH}x${BACKGROUND_POINT_HEIGHT}pt, expected ${EXPECTED_BACKGROUND_WIDTH}x${EXPECTED_BACKGROUND_HEIGHT}pt"
  pass "Finder background is ${EXPECTED_BACKGROUND_WIDTH}x${EXPECTED_BACKGROUND_HEIGHT}pt (${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}px at ${BACKGROUND_DPI_WIDTH}x${BACKGROUND_DPI_HEIGHT} DPI)"
fi

if [[ "$EXPECT_VOLUME_ICON" -eq 1 ]]; then
  MOUNTED_VOLUME_ICON="$MOUNT_POINT/.VolumeIcon.icns"
  if [[ ! -f "$MOUNTED_VOLUME_ICON" ]]; then
    printf 'Mounted compressed-image contents:\n' >&2
    ls -laO@ "$MOUNT_POINT" >&2 || true
    die "mounted image is missing .VolumeIcon.icns"
  fi
  VOLUME_ICON_FORMAT="$(sips -g format "$MOUNTED_VOLUME_ICON" 2>/dev/null | awk '/format:/ {print $2}')"
  [[ "$VOLUME_ICON_FORMAT" == "icns" ]] || die "mounted volume icon is not an ICNS file"
  VOLUME_ATTRIBUTES="$(GetFileInfo -a "$MOUNT_POINT")"
  VOLUME_ICON_ATTRIBUTES="$(GetFileInfo -a "$MOUNTED_VOLUME_ICON")"
  [[ "$VOLUME_ATTRIBUTES" == *C* ]] || die "mounted volume is missing the custom-icon Finder flag"
  [[ "$VOLUME_ICON_ATTRIBUTES" == *V* ]] || die ".VolumeIcon.icns is not marked invisible"
  pass "custom ICNS volume icon is present, active, and hidden"
fi

SOURCE_PLIST="$SOURCE_APP/Contents/Info.plist"
MOUNTED_PLIST="$MOUNTED_APP/Contents/Info.plist"
[[ -f "$SOURCE_PLIST" && -f "$MOUNTED_PLIST" ]] || die "source or mounted Info.plist is missing"

MOUNTED_RESOURCE_DIR="$MOUNTED_APP/Contents/Resources"
[[ -d "$MOUNTED_RESOURCE_DIR" ]] || die "mounted app has no Contents/Resources directory"
PACKAGING_RESOURCE_LEAKS="$(find "$MOUNTED_RESOURCE_DIR" \
  \( -type f -name 'dmg-*' -o -path '*/packaging' -o -path '*/packaging/*' \) \
  -print)"
if [[ -n "$PACKAGING_RESOURCE_LEAKS" ]]; then
  printf 'Packaging-only files leaked into mounted app Resources:\n%s\n' "$PACKAGING_RESOURCE_LEAKS" >&2
  die "mounted app contains packaging-only DMG resources"
fi
pass "mounted app Resources exclude packaging-only and dmg-* payload"

for key in CFBundleIdentifier CFBundleDisplayName CFBundleShortVersionString CFBundleVersion CFBundleExecutable LSMinimumSystemVersion; do
  SOURCE_VALUE="$($PLIST_BUDDY -c "Print :$key" "$SOURCE_PLIST")"
  MOUNTED_VALUE="$($PLIST_BUDDY -c "Print :$key" "$MOUNTED_PLIST")"
  [[ "$MOUNTED_VALUE" == "$SOURCE_VALUE" ]] || die "$key mismatch: expected '$SOURCE_VALUE', found '$MOUNTED_VALUE'"
done
pass "bundle identity, version, executable, and minimum macOS match the ReleaseFast app"

APP_EXECUTABLE="$($PLIST_BUDDY -c 'Print :CFBundleExecutable' "$MOUNTED_PLIST")"
SOURCE_BINARY="$SOURCE_APP/Contents/MacOS/$APP_EXECUTABLE"
MOUNTED_BINARY="$MOUNTED_APP/Contents/MacOS/$APP_EXECUTABLE"
[[ -f "$MOUNTED_BINARY" && -x "$MOUNTED_BINARY" ]] || die "mounted executable is missing or not executable"

SOURCE_ARCHS="$(lipo -archs "$SOURCE_BINARY")"
MOUNTED_ARCHS="$(lipo -archs "$MOUNTED_BINARY")"
[[ "$MOUNTED_ARCHS" == "$SOURCE_ARCHS" ]] || die "architecture mismatch: expected '$SOURCE_ARCHS', found '$MOUNTED_ARCHS'"
file "$MOUNTED_BINARY" | grep -q 'Mach-O' || die "mounted executable is not Mach-O"
pass "Mach-O architecture matches source: $MOUNTED_ARCHS"

SOURCE_BINARY_HASH="$(shasum -a 256 "$SOURCE_BINARY" | awk '{print $1}')"
MOUNTED_BINARY_HASH="$(shasum -a 256 "$MOUNTED_BINARY" | awk '{print $1}')"
[[ "$MOUNTED_BINARY_HASH" == "$SOURCE_BINARY_HASH" ]] || die "mounted executable SHA-256 differs from the ReleaseFast source"
pass "mounted executable SHA-256 matches source: $MOUNTED_BINARY_HASH"

SOURCE_CDHASH="$(codesign -dvvv "$SOURCE_APP" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
MOUNTED_CDHASH="$(codesign -dvvv "$MOUNTED_APP" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
[[ -n "$SOURCE_CDHASH" && -n "$MOUNTED_CDHASH" ]] || die "could not read the outer app CDHash"
[[ "$MOUNTED_CDHASH" == "$SOURCE_CDHASH" ]] || die "outer app CDHash mismatch: expected '$SOURCE_CDHASH', found '$MOUNTED_CDHASH'"
pass "outer app CDHash matches source: $MOUNTED_CDHASH"

codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP"
SOURCE_SIGNING_INFO="$(codesign -dvvv "$SOURCE_APP" 2>&1)"
MOUNTED_SIGNING_INFO="$(codesign -dvvv "$MOUNTED_APP" 2>&1)"
printf '%s\n' "$SOURCE_SIGNING_INFO" | grep -q '^Signature=adhoc$' || \
  die "source app is not ad-hoc signed despite the local-release disclosure"
printf '%s\n' "$MOUNTED_SIGNING_INFO" | grep -q '^Signature=adhoc$' || \
  die "mounted app is not ad-hoc signed despite the local-release disclosure"
pass "code signature is structurally valid and ad-hoc (local build; not notarized)"

hdiutil detach "$MOUNT_POINT" >/dev/null
IMAGE_ATTACHED=0
pass "image detaches cleanly"

printf 'Verification complete\n'
