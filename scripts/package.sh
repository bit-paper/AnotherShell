#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/package.sh [options]

Options:
  --scheme <name>          Xcode scheme (default: AnotherShell)
  --configuration <name>   Build configuration (default: Release)
  --project <path>         Xcode project path (default: AnotherShell.xcodeproj)
  --version <x.y.z>        Override package version (default: MARKETING_VERSION)
  --no-dmg                 Skip DMG output
  --no-pkg                 Skip PKG output
  --clean                  Remove previous build/package artifacts first
  -h, --help               Show this help

Outputs:
  build/dist/<AppName>.app
  build/dist/<AppName>-Beta-<version>.dmg
  build/dist/<AppName>-Beta-<version>.pkg
EOF
}

SCHEME="AnotherShell"
CONFIGURATION="Release"
PROJECT="AnotherShell.xcodeproj"
VERSION_OVERRIDE=""
BUILD_ROOT="build"
DIST_DIR="${BUILD_ROOT}/dist"
MAKE_DMG=1
MAKE_PKG=1
DO_CLEAN=0

# Prefer full Xcode toolchain when available.
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT="${2:-}"
      shift 2
      ;;
    --version)
      VERSION_OVERRIDE="${2:-}"
      shift 2
      ;;
    --no-dmg)
      MAKE_DMG=0
      shift
      ;;
    --no-pkg)
      MAKE_PKG=0
      shift
      ;;
    --clean)
      DO_CLEAN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -d "$PROJECT" ]]; then
  echo "Project not found: $PROJECT" >&2
  exit 1
fi

if [[ "$DO_CLEAN" -eq 1 ]]; then
  rm -rf "${BUILD_ROOT}/archive" "${BUILD_ROOT}/dist" "${BUILD_ROOT}/dmg-staging" "${BUILD_ROOT}/derived" "${BUILD_ROOT}/spm" "${BUILD_ROOT}/package-home" "${BUILD_ROOT}/tmp"
fi

mkdir -p "$DIST_DIR"
mkdir -p "${BUILD_ROOT}/derived" "${BUILD_ROOT}/spm" "${BUILD_ROOT}/package-home" "${BUILD_ROOT}/tmp"

XCB_ENV=(
  "HOME=$(pwd)/${BUILD_ROOT}/package-home"
  "CFFIXED_USER_HOME=$(pwd)/${BUILD_ROOT}/package-home"
  "TMPDIR=$(pwd)/${BUILD_ROOT}/tmp"
)
XCB_COMMON_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$(pwd)/${BUILD_ROOT}/derived"
  -clonedSourcePackagesDirPath "$(pwd)/${BUILD_ROOT}/spm"
)

echo "Reading build settings..."
if ! BUILD_SETTINGS="$(env "${XCB_ENV[@]}" xcodebuild "${XCB_COMMON_ARGS[@]}" -showBuildSettings 2>&1)"; then
  echo "Failed to read build settings from Xcode." >&2
  echo "$BUILD_SETTINGS" >&2
  echo "Tip: install full Xcode and/or run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
APP_NAME="$(awk -F' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = / {print $2; exit}' <<<"$BUILD_SETTINGS")"
BUNDLE_ID="$(awk -F' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / {print $2; exit}' <<<"$BUILD_SETTINGS")"
MARKETING_VERSION="$(awk -F' = ' '/^[[:space:]]*MARKETING_VERSION = / {print $2; exit}' <<<"$BUILD_SETTINGS")"

if [[ -z "$APP_NAME" ]]; then
  APP_NAME="${SCHEME}.app"
fi
if [[ -z "$BUNDLE_ID" ]]; then
  BUNDLE_ID="com.example.${SCHEME}"
fi

VERSION="${VERSION_OVERRIDE:-$MARKETING_VERSION}"
if [[ -z "$VERSION" ]]; then
  VERSION="0.0.1"
fi

ARCHIVE_PATH="${BUILD_ROOT}/archive/${SCHEME}.xcarchive"
APP_PATH_IN_ARCHIVE="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}"
DIST_APP_PATH="${DIST_DIR}/${APP_NAME}"

echo "Archiving ${SCHEME} (${CONFIGURATION})..."
env "${XCB_ENV[@]}" xcodebuild \
  "${XCB_COMMON_ARGS[@]}" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH_IN_ARCHIVE" ]]; then
  echo "Archived app not found: $APP_PATH_IN_ARCHIVE" >&2
  exit 1
fi

echo "Copying app to ${DIST_APP_PATH}..."
rm -rf "$DIST_APP_PATH"
cp -R "$APP_PATH_IN_ARCHIVE" "$DIST_APP_PATH"

# Safety prune: ensure documentation screenshots are not shipped inside runtime artifacts.
prune_screenshot_assets() {
  local app_path="$1"
  local candidates=(
    "${app_path}/Contents/Resources/docs/screenshots"
    "${app_path}/Contents/Resources/screenshots"
  )
  for path in "${candidates[@]}"; do
    if [[ -e "$path" ]]; then
      echo "Pruning non-runtime screenshots from bundle: $path"
      rm -rf "$path"
    fi
  done
}

prune_screenshot_assets "$DIST_APP_PATH"

DMG_PATH="${DIST_DIR}/${SCHEME}-Beta-${VERSION}.dmg"
PKG_PATH="${DIST_DIR}/${SCHEME}-Beta-${VERSION}.pkg"

if [[ "$MAKE_DMG" -eq 1 ]]; then
  STAGING_DIR="${BUILD_ROOT}/dmg-staging"
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"
  cp -R "$DIST_APP_PATH" "$STAGING_DIR/"
  ln -sfn /Applications "${STAGING_DIR}/Applications"

  echo "Creating DMG: ${DMG_PATH}"
  rm -f "$DMG_PATH"
  hdiutil create \
    -volname "${SCHEME} Beta ${VERSION}" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
fi

if [[ "$MAKE_PKG" -eq 1 ]]; then
  echo "Creating PKG: ${PKG_PATH}"
  rm -f "$PKG_PATH"
  pkgbuild \
    --component "$DIST_APP_PATH" \
    --install-location /Applications \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    "$PKG_PATH" >/dev/null
fi

echo
echo "Done."
echo "App: ${DIST_APP_PATH}"
[[ "$MAKE_DMG" -eq 1 ]] && echo "DMG: ${DMG_PATH}"
[[ "$MAKE_PKG" -eq 1 ]] && echo "PKG: ${PKG_PATH}"
