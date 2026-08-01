#!/bin/bash

set -euo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DESKTOP_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
REPO_ROOT="$(CDPATH= cd -- "$DESKTOP_ROOT/../.." && pwd -P)"
readonly SCRIPT_DIR DESKTOP_ROOT REPO_ROOT
readonly APP_ICON="$DESKTOP_ROOT/assets/icon.png"
readonly TRAY_SOURCE="$DESKTOP_ROOT/assets/tray-template.svg"
readonly TRAY_PNG="$DESKTOP_ROOT/assets/tray-template.png"
readonly WEB_ICON="$REPO_ROOT/apps/web/public/focus-tracker-icon.png"
readonly DMG_SOURCE="$DESKTOP_ROOT/packaging/macos/dmg-background.svg"
readonly DMG_PNG="$DESKTOP_ROOT/packaging/macos/dmg-background.png"
readonly VOLUME_ICON="$DESKTOP_ROOT/packaging/macos/dmg-volume.icns"
readonly SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

for tool in awk cmp cp file find iconutil native rsvg-convert sips tr wc; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'error: required command not found: %s\n' "$tool" >&2
    exit 1
  }
done

[[ -f "$APP_ICON" ]] || {
  printf 'error: app icon not found: %s\n' "$APP_ICON" >&2
  exit 1
}
[[ -f "$SRGB_PROFILE" ]] || {
  printf 'error: required color profile not found: %s\n' "$SRGB_PROFILE" >&2
  exit 1
}

width="$(sips -g pixelWidth "$APP_ICON" | awk '/pixelWidth/ {print $2}')"
height="$(sips -g pixelHeight "$APP_ICON" | awk '/pixelHeight/ {print $2}')"
alpha="$(sips -g hasAlpha "$APP_ICON" | awk '/hasAlpha/ {print $2}')"
profile="$(sips -g profile "$APP_ICON" | awk -F': ' '/profile:/ {print $2}')"
[[ "$width" == 1024 && "$height" == 1024 && "$alpha" == yes && "$profile" == sRGB* ]] || {
  printf 'error: app icon must be a 1024x1024 sRGB PNG with alpha\n' >&2
  exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/focus-tracker-brand.XXXXXX")"
web_stage="$work_dir/focus-tracker-icon.png"
tray_stage="$work_dir/tray-template.png"
dmg_stage="$work_dir/dmg-background.png"
volume_stage="$work_dir/dmg-volume.icns"

cleanup() {
  case "$work_dir" in
    "${TMPDIR:-/tmp}"/focus-tracker-brand.*) /bin/rm -rf -- "$work_dir" ;;
    *) printf 'warning: refusing cleanup outside generated brand workspace: %s\n' "$work_dir" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

cp "$APP_ICON" "$web_stage"
rsvg-convert -w 36 -h 36 -o "$tray_stage" "$TRAY_SOURCE"
rsvg-convert -w 1320 -h 860 -o "$dmg_stage" "$DMG_SOURCE"
sips -s dpiWidth 144 -s dpiHeight 144 "$dmg_stage" >/dev/null
sips -e "$SRGB_PROFILE" "$tray_stage" "$dmg_stage" >/dev/null

(
  cd "$DESKTOP_ROOT"
  native package \
    --target macos \
    --output "$work_dir/IconProbe.app" \
    --binary /usr/bin/true \
    --assets assets \
    --signing none
)
cp "$work_dir/IconProbe.app/Contents/Resources/AppIcon.icns" "$volume_stage"

tray_width="$(sips -g pixelWidth "$tray_stage" | awk '/pixelWidth/ {print $2}')"
tray_height="$(sips -g pixelHeight "$tray_stage" | awk '/pixelHeight/ {print $2}')"
tray_alpha="$(sips -g hasAlpha "$tray_stage" | awk '/hasAlpha/ {print $2}')"
tray_profile="$(sips -g profile "$tray_stage" | awk -F': ' '/profile:/ {print $2}')"
[[ "$tray_width" == 36 && "$tray_height" == 36 && "$tray_alpha" == yes && "$tray_profile" == sRGB* ]] || {
  printf 'error: generated tray icon must be a 36x36 sRGB PNG with alpha\n' >&2
  exit 1
}

dmg_width="$(sips -g pixelWidth "$dmg_stage" | awk '/pixelWidth/ {print $2}')"
dmg_height="$(sips -g pixelHeight "$dmg_stage" | awk '/pixelHeight/ {print $2}')"
dmg_dpi_width="$(sips -g dpiWidth "$dmg_stage" | awk '/dpiWidth/ {print $2}')"
dmg_dpi_height="$(sips -g dpiHeight "$dmg_stage" | awk '/dpiHeight/ {print $2}')"
[[ "$dmg_width" == 1320 && "$dmg_height" == 860 && "$dmg_dpi_width" == 144.000 && "$dmg_dpi_height" == 144.000 ]] || {
  printf 'error: generated DMG background must be 1320x860 at 144 DPI\n' >&2
  exit 1
}

[[ "$(file -b "$volume_stage")" == "Mac OS X icon"* ]] || {
  printf 'error: generated DMG volume icon is not a valid ICNS container\n' >&2
  exit 1
}
iconutil -c iconset -o "$work_dir/Volume.iconset" "$volume_stage"
slot_count="$(find "$work_dir/Volume.iconset" -maxdepth 1 -type f -name '*.png' -print | wc -l | tr -d ' ')"
[[ "$slot_count" == 10 ]] || {
  printf 'error: generated DMG volume icon has %s slots, expected 10\n' "$slot_count" >&2
  exit 1
}
cmp -s "$APP_ICON" "$web_stage" || {
  printf 'error: staged web icon differs from the app icon master\n' >&2
  exit 1
}

cp "$web_stage" "$WEB_ICON"
cp "$tray_stage" "$TRAY_PNG"
cp "$dmg_stage" "$DMG_PNG"
cp "$volume_stage" "$VOLUME_ICON"

printf 'Generated web, tray, DMG background, and DMG volume icon assets.\n'
