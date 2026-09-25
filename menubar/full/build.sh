#!/bin/bash
# 完整版菜单栏 App 构建：编译 → 图标 → 组包 → 签名 → 启动
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 输出位置可用环境变量覆盖，默认放到桌面：MBB_APP_OUT=/somewhere bash build.sh
APP="${MBB_APP_OUT:-$HOME/Desktop/ManageBac菜单栏.app}"
BUILD="$SRC/build"
TARGET="arm64-apple-macos26.0"

mkdir -p "$BUILD"
cd "$SRC"

echo "① 编译主程序…"
/usr/bin/xcrun swiftc -O -parse-as-library -target "$TARGET" \
  -o "$BUILD/MBMenuBar" \
  Theme.swift Rules.swift Model.swift StatusBadge.swift Store.swift Panel.swift App.swift
echo "   ✔ 编译通过"

echo "② 图标…"
if [ ! -f "$BUILD/AppIcon.icns" ]; then
  /usr/bin/xcrun swiftc -O -o "$BUILD/makeicon" makeicon.swift
  /bin/rm -rf "$BUILD/AppIcon.iconset"
  "$BUILD/makeicon" "$BUILD/AppIcon.iconset" >/dev/null
  /usr/bin/iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
echo "   ✔ $(/usr/bin/du -h "$BUILD/AppIcon.icns" | /usr/bin/cut -f1)"

echo "③ 组包…"
/usr/bin/pkill -f "MacOS/MBMenuBar" 2>/dev/null || true
sleep 0.6
/bin/rm -rf "$APP"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f "$BUILD/MBMenuBar"          "$APP/Contents/MacOS/MBMenuBar"
/bin/cp -f "$BUILD/AppIcon.icns"       "$APP/Contents/Resources/AppIcon.icns"
/bin/cp -f "$SRC/Info.plist"           "$APP/Contents/Info.plist"
/usr/bin/printf 'APPL????'           > "$APP/Contents/PkgInfo"
/bin/chmod +x "$APP/Contents/MacOS/MBMenuBar"

echo "④ 签名…"
# swiftc 产出的二进制自带预置签名，直接签整包会在封条里留下临时文件引用 → 先摘掉再签
/usr/bin/codesign --remove-signature "$APP/Contents/MacOS/MBMenuBar" 2>/dev/null || true
/usr/bin/codesign --force --sign - --identifier com.oscar.mbmenubar "$APP"
/usr/bin/codesign --verify --verbose=1 "$APP" && echo "   ✔ 签名有效"

echo "⑤ 启动…"
/usr/bin/open "$APP"
sleep 2
/usr/bin/pgrep -fl "MacOS/MBMenuBar" | /usr/bin/head -1
echo "完成。菜单栏应出现 📂"
