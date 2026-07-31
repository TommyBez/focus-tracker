#!/bin/bash

set -euo pipefail
IFS=$'\n\t'
umask 022

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly BUNDLE_README_LINE="Beta build: ad-hoc signed; not Developer ID signed or notarized."
readonly LAYOUT_TEMPLATE="$REPO_ROOT/packaging/macos/dmg-layout.DS_Store"
readonly BACKGROUND_WIDTH=660
readonly BACKGROUND_HEIGHT=430

APP_SOURCE="$REPO_ROOT/zig-out/package/focus-tracker.app"
OUTPUT_DMG=""
OUTPUT_EXPLICIT=0
BACKGROUND_IMAGE="$REPO_ROOT/packaging/macos/dmg-background.png"
VOLUME_ICON="$REPO_ROOT/packaging/macos/dmg-volume.icns"
VOLUME_NAME="Focus Tracker"
BACKGROUND_EXPLICIT=0
VOLUME_ICON_EXPLICIT=0

WORK_DIR=""
OUTPUT_TRANSACTION_DIR=""
MOUNT_POINT=""
IMAGE_ATTACHED=0
PUBLICATION_STARTED=0
PUBLICATION_COMMITTED=0
NEW_DMG_PUBLICATION_STARTED=0
NEW_CHECKSUM_PUBLICATION_STARTED=0
BACKUP_DMG=""
BACKUP_CHECKSUM=""

usage() {
  cat <<'EOF'
Build the polished Focus Tracker beta installer image.

Usage:
  scripts/build-dmg.sh [options]

Options:
  --app PATH              Source .app bundle.
  --output PATH           Final .dmg path (must stay inside this repository).
  --background PATH       660x430 pt PNG Finder background (@1x or @2x).
  --no-background         Build without a background image.
  --volume-icon PATH      Optional .icns volume icon.
  --no-volume-icon        Build without a custom volume icon.
  --volume-name NAME      Must match the layout template: Focus Tracker.
  -h, --help              Show this help.

The default source is zig-out/package/focus-tracker.app. If present,
packaging/macos/dmg-background.png and packaging/macos/dmg-volume.icns are used automatically.
The version-controlled packaging/macos/dmg-layout.DS_Store supplies the Finder
window, icon positions, and background reference without launching Finder.
The output defaults to zig-out/release/Focus-Tracker-<version>-macOS-<arch>.dmg.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_existing_path() {
  local requested="$1"

  [[ -e "$requested" ]] || die "path does not exist: $requested"
  realpath "$requested"
}

assert_exact_hidden_root_payload() {
  local root="$1"
  local phase="$2"
  local unexpected

  [[ -d "$root" ]] || die "$phase mount is unavailable: $root"
  unexpected="$(find "$root" -mindepth 1 -maxdepth 1 -name '.*' \
    ! -name '.background' \
    ! -name '.DS_Store' \
    ! -name '.VolumeIcon.icns' \
    -print)"
  if [[ -n "$unexpected" ]]; then
    printf '%s hidden-root payload:\n%s\n' "$phase" "$unexpected" >&2
    ls -laO@ "$root" >&2 || true
    die "$phase image contains unexpected hidden root payload"
  fi

  [[ -f "$root/.DS_Store" ]] || die "$phase image is missing .DS_Store"
  cmp -s "$LAYOUT_TEMPLATE" "$root/.DS_Store" || \
    die "$phase image .DS_Store differs from the version-controlled layout template"
  if [[ "$INCLUDE_BACKGROUND" -eq 1 ]]; then
    [[ -d "$root/.background" ]] || die "$phase image is missing .background"
  else
    [[ ! -e "$root/.background" && ! -L "$root/.background" ]] || die "$phase image unexpectedly contains .background"
  fi
  if [[ "$INCLUDE_VOLUME_ICON" -eq 1 ]]; then
    [[ -f "$root/.VolumeIcon.icns" ]] || die "$phase image is missing .VolumeIcon.icns"
  else
    [[ ! -e "$root/.VolumeIcon.icns" && ! -L "$root/.VolumeIcon.icns" ]] || die "$phase image unexpectedly contains .VolumeIcon.icns"
  fi
}

remove_mount_generated_metadata() {
  local root="$1"
  local generated

  [[ -n "$WORK_DIR" && "$root" == "$WORK_DIR/writable-mount" ]] || \
    die "refusing metadata cleanup outside the generated writable mount: $root"
  for generated in \
    .fseventsd \
    .Spotlight-V100 \
    .Trashes \
    .TemporaryItems \
    .DocumentRevisions-V100 \
    .metadata_never_index \
    .com.apple.timemachine.donotpresent; do
    if [[ -e "$root/$generated" || -L "$root/$generated" ]]; then
      /bin/rm -rf -- "$root/$generated"
    fi
  done
}

safe_remove_tree() {
  local target="$1"
  [[ -n "$target" ]] || return 0

  case "$target" in
    "${TMPDIR:-/tmp}"/focus-tracker-dmg.*)
      /bin/rm -rf -- "$target"
      ;;
    *)
      if [[ "$target" == "$REPO_ROOT"/* && "$(basename -- "$target")" == .focus-tracker-dmg.* ]]; then
        /bin/rm -rf -- "$target"
      else
        printf 'warning: refusing cleanup outside a generated DMG workspace: %s\n' "$target" >&2
      fi
      ;;
  esac
}

rollback_publication() {
  local rollback_failed=0

  [[ "$PUBLICATION_STARTED" -eq 1 && "$PUBLICATION_COMMITTED" -eq 0 ]] || return 0
  printf 'warning: DMG publication did not commit; restoring the previous release pair\n' >&2

  if [[ "$NEW_CHECKSUM_PUBLICATION_STARTED" -eq 1 ]]; then
    /bin/rm -f -- "$OUTPUT_DMG.sha256" || rollback_failed=1
  fi
  if [[ "$NEW_DMG_PUBLICATION_STARTED" -eq 1 ]]; then
    /bin/rm -f -- "$OUTPUT_DMG" || rollback_failed=1
  fi
  if [[ -n "$BACKUP_DMG" && -e "$BACKUP_DMG" ]]; then
    mv -f -- "$BACKUP_DMG" "$OUTPUT_DMG" || rollback_failed=1
  fi
  if [[ -n "$BACKUP_CHECKSUM" && -e "$BACKUP_CHECKSUM" ]]; then
    mv -f -- "$BACKUP_CHECKSUM" "$OUTPUT_DMG.sha256" || rollback_failed=1
  fi

  if [[ "$rollback_failed" -ne 0 ]]; then
    printf 'error: automatic publication rollback was incomplete; inspect %s and %s\n' "$OUTPUT_DMG" "$OUTPUT_TRANSACTION_DIR" >&2
    return 1
  fi
  return 0
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if [[ "$IMAGE_ATTACHED" -eq 1 && -n "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi

  if ! rollback_publication; then
    status=1
  fi

  safe_remove_tree "$WORK_DIR"
  safe_remove_tree "$OUTPUT_TRANSACTION_DIR"
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || die "--app requires a path"
      APP_SOURCE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a path"
      OUTPUT_DMG="$2"
      OUTPUT_EXPLICIT=1
      shift 2
      ;;
    --background)
      [[ $# -ge 2 ]] || die "--background requires a path"
      BACKGROUND_IMAGE="$2"
      BACKGROUND_EXPLICIT=1
      shift 2
      ;;
    --no-background)
      BACKGROUND_IMAGE=""
      BACKGROUND_EXPLICIT=1
      shift
      ;;
    --volume-icon)
      [[ $# -ge 2 ]] || die "--volume-icon requires a path"
      VOLUME_ICON="$2"
      VOLUME_ICON_EXPLICIT=1
      shift 2
      ;;
    --no-volume-icon)
      VOLUME_ICON=""
      VOLUME_ICON_EXPLICIT=1
      shift
      ;;
    --volume-name)
      [[ $# -ge 2 ]] || die "--volume-name requires a value"
      VOLUME_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

for tool in awk cmp codesign ditto du file find GetFileInfo grep hdiutil lipo realpath SetFile shasum sips stat strings sync touch tr; do
  require_command "$tool"
done
[[ -x "$PLIST_BUDDY" ]] || die "required command not found: $PLIST_BUDDY"

[[ -f "$LAYOUT_TEMPLATE" && ! -L "$LAYOUT_TEMPLATE" ]] || \
  die "version-controlled Finder layout template is missing or invalid: $LAYOUT_TEMPLATE"
file "$LAYOUT_TEMPLATE" | grep -q 'Apple Desktop Services Store' || \
  die "Finder layout template is not a valid .DS_Store file"
LAYOUT_STRINGS="$(strings "$LAYOUT_TEMPLATE")"
for marker in 'Focus Tracker' '.background' 'dmg-background.png'; do
  grep -Fqx "$marker" <<< "$LAYOUT_STRINGS" || \
    die "Finder layout template is missing expected marker: $marker"
done

APP_SOURCE="$(resolve_existing_path "$APP_SOURCE")"
[[ -d "$APP_SOURCE" ]] || die "source app is not a directory: $APP_SOURCE"
[[ "$APP_SOURCE" == *.app ]] || die "source must be an .app bundle: $APP_SOURCE"
[[ "$APP_SOURCE" == "$REPO_ROOT"/* ]] || die "source app must stay inside the repository"

SOURCE_PLIST="$APP_SOURCE/Contents/Info.plist"
[[ -f "$SOURCE_PLIST" ]] || die "source app has no Contents/Info.plist"

APP_VERSION="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$SOURCE_PLIST")"
APP_EXECUTABLE="$($PLIST_BUDDY -c 'Print :CFBundleExecutable' "$SOURCE_PLIST")"
APP_BINARY="$APP_SOURCE/Contents/MacOS/$APP_EXECUTABLE"
[[ -f "$APP_BINARY" && -x "$APP_BINARY" ]] || die "source app executable is missing or not executable: $APP_BINARY"

SOURCE_RESOURCE_DIR="$APP_SOURCE/Contents/Resources"
[[ -d "$SOURCE_RESOURCE_DIR" ]] || die "source app has no Contents/Resources directory"
SOURCE_BUNDLE_README="$SOURCE_RESOURCE_DIR/README.txt"
[[ -f "$SOURCE_BUNDLE_README" ]] || die "source app has no Contents/Resources/README.txt"
grep -Fqx "$BUNDLE_README_LINE" "$SOURCE_BUNDLE_README" || \
  die "source app README does not describe its ad-hoc signing state accurately"
SOURCE_PACKAGING_LEAKS="$(find "$SOURCE_RESOURCE_DIR" \
  \( -type f -name 'dmg-*' -o -path '*/packaging' -o -path '*/packaging/*' \) \
  -print)"
if [[ -n "$SOURCE_PACKAGING_LEAKS" ]]; then
  printf 'Packaging-only resources found in source app:\n%s\n' "$SOURCE_PACKAGING_LEAKS" >&2
  die "source app contains packaging-only resources; rebuild it with scripts/package-app.sh"
fi

APP_ARCHS="$(lipo -archs "$APP_BINARY")"
case "$APP_ARCHS" in
  "arm64 x86_64"|"x86_64 arm64") APP_ARCH_LABEL="universal2" ;;
  *) APP_ARCH_LABEL="$(printf '%s' "$APP_ARCHS" | tr ' ' '-')" ;;
esac

if [[ "$OUTPUT_EXPLICIT" -eq 0 ]]; then
  mkdir -p -- "$REPO_ROOT/zig-out/release"
  OUTPUT_DMG="$REPO_ROOT/zig-out/release/Focus-Tracker-$APP_VERSION-macOS-$APP_ARCH_LABEL.dmg"
fi

OUTPUT_PARENT_REQUESTED="$(dirname -- "$OUTPUT_DMG")"
[[ -d "$OUTPUT_PARENT_REQUESTED" ]] || die "output directory must already exist: $OUTPUT_PARENT_REQUESTED"
OUTPUT_PARENT="$(CDPATH= cd -- "$OUTPUT_PARENT_REQUESTED" && pwd -P)"
OUTPUT_DMG="$OUTPUT_PARENT/$(basename -- "$OUTPUT_DMG")"

[[ "$OUTPUT_DMG" == *.dmg ]] || die "output filename must end in .dmg"
[[ "$OUTPUT_DMG" == "$REPO_ROOT"/* ]] || die "output DMG must stay inside the repository"
[[ ! -L "$OUTPUT_DMG" ]] || die "refusing to replace a symlink: $OUTPUT_DMG"
[[ ! -L "$OUTPUT_DMG.sha256" ]] || die "refusing to replace a symlink: $OUTPUT_DMG.sha256"
[[ ! -e "$OUTPUT_DMG" || -f "$OUTPUT_DMG" ]] || die "existing output is not a regular file: $OUTPUT_DMG"
[[ ! -e "$OUTPUT_DMG.sha256" || -f "$OUTPUT_DMG.sha256" ]] || die "existing checksum is not a regular file: $OUTPUT_DMG.sha256"
[[ -n "$VOLUME_NAME" ]] || die "volume name cannot be empty"
[[ "$VOLUME_NAME" != */* ]] || die "volume name cannot contain a slash"
[[ ${#VOLUME_NAME} -le 27 ]] || die "volume name must be 27 characters or fewer for HFS+ compatibility"
[[ "$VOLUME_NAME" == "Focus Tracker" ]] || \
  die "the version-controlled Finder layout template requires volume name 'Focus Tracker'"

INCLUDE_BACKGROUND=0
if [[ -n "$BACKGROUND_IMAGE" ]]; then
  if [[ -e "$BACKGROUND_IMAGE" ]]; then
    BACKGROUND_IMAGE="$(resolve_existing_path "$BACKGROUND_IMAGE")"
    [[ -f "$BACKGROUND_IMAGE" ]] || die "background is not a regular file: $BACKGROUND_IMAGE"
    BACKGROUND_FORMAT="$(sips -g format "$BACKGROUND_IMAGE" 2>/dev/null | awk '/format:/ {print $2}')"
    BACKGROUND_ACTUAL_WIDTH="$(sips -g pixelWidth "$BACKGROUND_IMAGE" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
    BACKGROUND_ACTUAL_HEIGHT="$(sips -g pixelHeight "$BACKGROUND_IMAGE" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
    BACKGROUND_DPI_WIDTH="$(sips -g dpiWidth "$BACKGROUND_IMAGE" 2>/dev/null | awk '/dpiWidth:/ {print $2}')"
    BACKGROUND_DPI_HEIGHT="$(sips -g dpiHeight "$BACKGROUND_IMAGE" 2>/dev/null | awk '/dpiHeight:/ {print $2}')"
    BACKGROUND_POINT_WIDTH="$(awk -v pixels="$BACKGROUND_ACTUAL_WIDTH" -v dpi="$BACKGROUND_DPI_WIDTH" 'BEGIN { printf "%.0f", pixels * 72 / dpi }')"
    BACKGROUND_POINT_HEIGHT="$(awk -v pixels="$BACKGROUND_ACTUAL_HEIGHT" -v dpi="$BACKGROUND_DPI_HEIGHT" 'BEGIN { printf "%.0f", pixels * 72 / dpi }')"
    [[ "$BACKGROUND_FORMAT" == "png" ]] || die "Finder background must be a PNG"
    [[ "$BACKGROUND_POINT_WIDTH" == "$BACKGROUND_WIDTH" && "$BACKGROUND_POINT_HEIGHT" == "$BACKGROUND_HEIGHT" ]] || \
      die "Finder background must be ${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}pt (found ${BACKGROUND_POINT_WIDTH}x${BACKGROUND_POINT_HEIGHT}pt from ${BACKGROUND_ACTUAL_WIDTH}x${BACKGROUND_ACTUAL_HEIGHT}px at ${BACKGROUND_DPI_WIDTH}x${BACKGROUND_DPI_HEIGHT} DPI)"
    INCLUDE_BACKGROUND=1
  elif [[ "$BACKGROUND_EXPLICIT" -eq 1 ]]; then
    die "background does not exist: $BACKGROUND_IMAGE"
  else
    BACKGROUND_IMAGE=""
  fi
fi

INCLUDE_VOLUME_ICON=0
if [[ -n "$VOLUME_ICON" ]]; then
  if [[ -e "$VOLUME_ICON" ]]; then
    VOLUME_ICON="$(resolve_existing_path "$VOLUME_ICON")"
    [[ -f "$VOLUME_ICON" ]] || die "volume icon is not a regular file: $VOLUME_ICON"
    VOLUME_ICON_FORMAT="$(sips -g format "$VOLUME_ICON" 2>/dev/null | awk '/format:/ {print $2}')"
    [[ "$VOLUME_ICON_FORMAT" == "icns" ]] || die "volume icon must be an .icns file"
    INCLUDE_VOLUME_ICON=1
  elif [[ "$VOLUME_ICON_EXPLICIT" -eq 1 ]]; then
    die "volume icon does not exist: $VOLUME_ICON"
  else
    VOLUME_ICON=""
  fi
fi

note "Verifying source application signature"
codesign --verify --deep --strict --verbose=2 "$APP_SOURCE"
SOURCE_SIGNING_INFO="$(codesign -dvvv "$APP_SOURCE" 2>&1)"
printf '%s\n' "$SOURCE_SIGNING_INFO" | grep -q '^Signature=adhoc$' || \
  die "source app is not ad-hoc signed; this beta DMG cannot describe it truthfully"
note "Source app has the required beta ad-hoc signature"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/focus-tracker-dmg.XXXXXX")"
OUTPUT_TRANSACTION_DIR="$(mktemp -d "$OUTPUT_PARENT/.focus-tracker-dmg.XXXXXX")"
STAGE_DIR="$WORK_DIR/stage"
MOUNT_POINT="$WORK_DIR/writable-mount"
READ_WRITE_DMG="$WORK_DIR/Focus-Tracker-read-write.dmg"
APP_BUNDLE_NAME="Focus Tracker.app"
STAGED_APP="$STAGE_DIR/$APP_BUNDLE_NAME"
TEMP_FINAL_DMG="$OUTPUT_TRANSACTION_DIR/$(basename -- "$OUTPUT_DMG")"
TEMP_CHECKSUM="$OUTPUT_TRANSACTION_DIR/$(basename -- "$OUTPUT_DMG").sha256"

mkdir -p -- "$STAGE_DIR" "$MOUNT_POINT"

note "Staging $APP_BUNDLE_NAME with resource forks and extended attributes"
ditto --rsrc --extattr "$APP_SOURCE" "$STAGED_APP"
ln -s /Applications "$STAGE_DIR/Applications"

if [[ "$INCLUDE_BACKGROUND" -eq 1 ]]; then
  mkdir -p -- "$STAGE_DIR/.background"
  ditto "$BACKGROUND_IMAGE" "$STAGE_DIR/.background/dmg-background.png"
fi

STAGE_SIZE_KB="$(du -sk "$STAGE_DIR" | awk '{print $1}')"
IMAGE_SIZE_KB=$((STAGE_SIZE_KB + 32768))
if [[ "$IMAGE_SIZE_KB" -lt 65536 ]]; then
  IMAGE_SIZE_KB=65536
fi

note "Creating writable HFS+ image (${IMAGE_SIZE_KB} KiB)"
hdiutil create \
  -quiet \
  -ov \
  -size "${IMAGE_SIZE_KB}k" \
  -fs HFS+ \
  -format UDRW \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  "$READ_WRITE_DMG"

note "Mounting image headlessly for deterministic presentation metadata"
hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$READ_WRITE_DMG" >/dev/null
IMAGE_ATTACHED=1
[[ -d "$MOUNT_POINT" ]] || die "writable image mount is unavailable: $MOUNT_POINT"

# Prevent Spotlight and FSEvents from populating release-only metadata while
# the image is mounted. These sentinels are removed before detach and the
# subsequent read-only remount proves that none persisted.
mkdir -p -- "$MOUNT_POINT/.fseventsd"
touch "$MOUNT_POINT/.fseventsd/no_log" "$MOUNT_POINT/.metadata_never_index"

note "Installing version-controlled Finder layout without a GUI session"
ditto --norsrc --noextattr --noqtn --noacl \
  "$LAYOUT_TEMPLATE" \
  "$MOUNT_POINT/.DS_Store"
cmp -s "$LAYOUT_TEMPLATE" "$MOUNT_POINT/.DS_Store" || \
  die "mounted Finder layout does not match the version-controlled template"

if [[ -d "$MOUNT_POINT/.background" ]]; then
  SetFile -a V "$MOUNT_POINT/.background"
fi
if [[ "$INCLUDE_VOLUME_ICON" -eq 1 ]]; then
  # Copy onto the mounted filesystem. hdiutil may treat a pre-staged
  # .VolumeIcon.icns as source-folder metadata instead of payload.
  ditto --norsrc --noextattr --noqtn --noacl "$VOLUME_ICON" "$MOUNT_POINT/.VolumeIcon.icns"
  SetFile -c icnC "$MOUNT_POINT/.VolumeIcon.icns"
  [[ -f "$MOUNT_POINT/.VolumeIcon.icns" ]] || die "custom volume icon was not written to the mounted image"
fi
if [[ "$INCLUDE_VOLUME_ICON" -eq 1 ]]; then
  # Apply the HFS FinderInfo flags directly; no Finder process is involved.
  SetFile -a V "$MOUNT_POINT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT_POINT"
  VOLUME_ATTRIBUTES="$(GetFileInfo -a "$MOUNT_POINT")"
  VOLUME_ICON_ATTRIBUTES="$(GetFileInfo -a "$MOUNT_POINT/.VolumeIcon.icns")"
  [[ "$VOLUME_ATTRIBUTES" == *C* ]] || die "custom-icon flag was not set on the writable volume"
  [[ "$VOLUME_ICON_ATTRIBUTES" == *V* ]] || die ".VolumeIcon.icns was not marked invisible"
fi

sync
note "Removing mount-generated metadata"
remove_mount_generated_metadata "$MOUNT_POINT"
assert_exact_hidden_root_payload "$MOUNT_POINT" "Writable"

note "Detaching writable image"
hdiutil detach "$MOUNT_POINT" >/dev/null
IMAGE_ATTACHED=0

PERSISTENCE_MOUNT_POINT="$WORK_DIR/persistence-mount"
mkdir -p -- "$PERSISTENCE_MOUNT_POINT"
note "Checking exact root payload before compression"
hdiutil attach \
  -readonly \
  -noverify \
  -noautoopen \
  -nobrowse \
  -mountpoint "$PERSISTENCE_MOUNT_POINT" \
  "$READ_WRITE_DMG" >/dev/null
MOUNT_POINT="$PERSISTENCE_MOUNT_POINT"
IMAGE_ATTACHED=1
assert_exact_hidden_root_payload "$MOUNT_POINT" "Read-only persistence"
if [[ "$INCLUDE_VOLUME_ICON" -eq 1 ]]; then
  pass_icon_attributes="$(GetFileInfo -a "$MOUNT_POINT/.VolumeIcon.icns")"
  [[ "$pass_icon_attributes" == *V* ]] || die ".VolumeIcon.icns lost its invisible Finder flag before compression"
fi
hdiutil detach "$MOUNT_POINT" >/dev/null
IMAGE_ATTACHED=0

note "Compressing final image as UDZO (zlib level 9)"
hdiutil convert \
  -quiet \
  "$READ_WRITE_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$TEMP_FINAL_DMG"

note "Running independent pre-publication verification"
VERIFY_ARGS=(--source-app "$APP_SOURCE" --volume-name "$VOLUME_NAME" --skip-checksum)
if [[ "$INCLUDE_BACKGROUND" -eq 1 ]]; then
  VERIFY_ARGS+=(--expect-background)
fi
if [[ "$INCLUDE_VOLUME_ICON" -eq 1 ]]; then
  VERIFY_ARGS+=(--expect-volume-icon)
fi
"$SCRIPT_DIR/verify-dmg.sh" "${VERIFY_ARGS[@]}" "$TEMP_FINAL_DMG"

DMG_SHA256="$(shasum -a 256 "$TEMP_FINAL_DMG" | awk '{print $1}')"
printf '%s  %s\n' "$DMG_SHA256" "$(basename -- "$OUTPUT_DMG")" > "$TEMP_CHECKSUM"

note "Preverifying DMG and checksum pair"
"$SCRIPT_DIR/verify-dmg.sh" --checksum-only "$TEMP_FINAL_DMG"

# A DMG and its checksum are two directory entries and cannot be replaced as
# one atomic filesystem operation. Keep the previous pair in this same-volume
# transaction directory until both replacements and the published checksum
# check succeed; the EXIT/signal trap restores them after any ordinary error.
BACKUP_DMG="$OUTPUT_TRANSACTION_DIR/previous-$(basename -- "$OUTPUT_DMG")"
BACKUP_CHECKSUM="$OUTPUT_TRANSACTION_DIR/previous-$(basename -- "$OUTPUT_DMG").sha256"
PUBLICATION_STARTED=1

if [[ -e "$OUTPUT_DMG" ]]; then
  mv -- "$OUTPUT_DMG" "$BACKUP_DMG"
fi
if [[ -e "$OUTPUT_DMG.sha256" ]]; then
  mv -- "$OUTPUT_DMG.sha256" "$BACKUP_CHECKSUM"
fi

NEW_DMG_PUBLICATION_STARTED=1
mv -- "$TEMP_FINAL_DMG" "$OUTPUT_DMG"
NEW_CHECKSUM_PUBLICATION_STARTED=1
mv -- "$TEMP_CHECKSUM" "$OUTPUT_DMG.sha256"

note "Verifying published checksum"
"$SCRIPT_DIR/verify-dmg.sh" --checksum-only "$OUTPUT_DMG"
PUBLICATION_COMMITTED=1

DMG_SIZE_BYTES="$(stat -f '%z' "$OUTPUT_DMG")"
printf '\nDMG ready\n'
printf '  Image:  %s\n' "$OUTPUT_DMG"
printf '  Bytes:  %s\n' "$DMG_SIZE_BYTES"
printf '  SHA256: %s\n' "$DMG_SHA256"
printf '  Signing: %s\n' "$BUNDLE_README_LINE"
