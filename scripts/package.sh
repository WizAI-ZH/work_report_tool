#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-all}"
PROJECT_NAME="work_report_generator"

ensure_flutter_project() {
  local platforms="$1"
  IFS=',' read -ra items <<< "$platforms"
  for platform in "${items[@]}"; do
    if [[ -n "$platform" && ! -d "$platform" ]]; then
      flutter create --project-name "$PROJECT_NAME" --platforms="$platform" .
    fi
  done
  ensure_platform_permissions
  flutter pub get
}

ensure_platform_permissions() {
  local android_manifest="android/app/src/main/AndroidManifest.xml"
  if [[ -f "$android_manifest" ]] && ! grep -q "android.permission.INTERNET" "$android_manifest"; then
    perl -0pi -e 's/<manifest([^>]*)>/<manifest$1>\n    <uses-permission android:name="android.permission.INTERNET" \/>/' "$android_manifest"
  fi

  for entitlement in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
    if [[ -f "$entitlement" ]] && ! grep -q "com.apple.security.network.client" "$entitlement"; then
      perl -0pi -e 's#</dict>#    <key>com.apple.security.network.client</key>\n    <true/>\n</dict>#' "$entitlement"
    fi
  done
}

ensure_for_target() {
  case "$TARGET" in
    all)
      ensure_flutter_project "android"
      case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ensure_flutter_project "windows" ;;
        Darwin*) ensure_flutter_project "macos" ;;
      esac
      ;;
    *) ensure_flutter_project "$TARGET" ;;
  esac
}

build_windows() {
  flutter build windows --release
  flutter pub run msix:create
}

build_android() {
  flutter build apk --release
}

build_macos() {
  flutter build macos --release
}

ensure_for_target
flutter analyze
flutter test

case "$TARGET" in
  windows) build_windows ;;
  android) build_android ;;
  macos) build_macos ;;
  all)
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) build_windows ;;
      Darwin*) build_macos ;;
    esac
    build_android
    ;;
  *)
    echo "Usage: scripts/package.sh [windows|android|macos|all]" >&2
    exit 2
    ;;
esac
