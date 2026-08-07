#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="$project_dir/.build"
output_dir="${1:-$project_dir/dist}"
app_dir="$output_dir/Пикми.app"

mkdir -p "$build_dir/module-cache" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
clang \
  -fobjc-arc \
  -fblocks \
  -fmodules \
  -fmodules-cache-path="$build_dir/module-cache" \
  -mmacosx-version-min=13.0 \
  -arch arm64 \
  -arch x86_64 \
  -O2 \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework ApplicationServices \
  -framework AVFoundation \
  "$project_dir/Sources/MagicCursor/main.m" \
  -o "$app_dir/Contents/MacOS/MagicCursor"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/Sources/MagicCursor/Resources/cursor.png" "$app_dir/Contents/Resources/cursor.png"
cp "$project_dir/Sources/MagicCursor/Resources/paw.png" "$app_dir/Contents/Resources/paw.png"
cp "$project_dir/Sources/MagicCursor/Resources/finger.png" "$app_dir/Contents/Resources/finger.png"
cp "$project_dir/Sources/MagicCursor/Resources/fuck.png" "$app_dir/Contents/Resources/fuck.png"
cp "$project_dir/Sources/MagicCursor/Resources/fist.png" "$app_dir/Contents/Resources/fist.png"
cp "$project_dir/Sources/MagicCursor/Resources/paw-new.png" "$app_dir/Contents/Resources/paw-new.png"
cp "$project_dir/Sources/MagicCursor/Resources/lego.png" "$app_dir/Contents/Resources/lego.png"
cp "$project_dir/Sources/MagicCursor/Resources/nail.png" "$app_dir/Contents/Resources/nail.png"
cp "$project_dir/Sources/MagicCursor/Resources/finger-new.png" "$app_dir/Contents/Resources/finger-new.png"
cp "$project_dir/Sources/MagicCursor/Resources/fuck-new.png" "$app_dir/Contents/Resources/fuck-new.png"
cp "$project_dir/Sources/MagicCursor/Resources/quiet-banging.mp3" "$app_dir/Contents/Resources/quiet-banging.mp3"
cp "$project_dir/Sources/MagicCursor/Resources/Flash Burst.png" "$app_dir/Contents/Resources/Flash Burst.png"
cp "$project_dir/Sources/MagicCursor/Resources/Finger.png" "$app_dir/Contents/Resources/Finger.png"
cp "$project_dir/Sources/MagicCursor/Resources/MagicCursor.icns" "$app_dir/Contents/Resources/MagicCursor.icns"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$project_dir/AppInfo.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
