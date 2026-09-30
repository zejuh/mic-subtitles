#!/usr/bin/env bash
# 编译 Mic Subtitles（中文系统显示「麦克风字幕」）。只需要命令行工具（xcode-select --install），不需要 Xcode。
#   ./build.sh           编译到 build/
#   ./build.sh install   编译并装到「应用程序」
#   ./build.sh zip       编译并打包成 zip，用来发布
set -euo pipefail
cd "$(dirname "$0")"

NAME="Mic Subtitles"
APP="build/$NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -parse-as-library -O Sources/*.swift -o "$APP/Contents/MacOS/MicSubtitles"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Localization/*.lproj "$APP/Contents/Resources/"

if [[ ! -f AppIcon.icns ]]; then
  swift make_icon.swift .
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  rm -rf AppIcon.iconset
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"

case "${1:-}" in
  install)
    pkill -x MicSubtitles 2>/dev/null || true
    rm -rf "/Applications/$NAME.app"
    ditto "$APP" "/Applications/$NAME.app"
    echo "Installed to /Applications/$NAME.app"
    ;;
  zip)
    ZIP="build/Mic-Subtitles-$VERSION-macos-arm64.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP"
    shasum -a 256 "$ZIP"
    ;;
esac
