#!/bin/bash
# 编译 + 组装 + 签名「ManageBac菜单栏.app」到桌面，并重启它。
# 改完 Main.swift 直接跑这个脚本即可。
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 输出位置可用环境变量覆盖，默认放到桌面：MBB_APP_OUT=/somewhere bash build.sh
APP="${MBB_APP_OUT:-$HOME/Desktop/ManageBac菜单栏.app}"
BIN="$SRC/build/MBMenuBar"
ICNS="$SRC/build/AppIcon.icns"

echo "== 1/6 编译主程序 =="
mkdir -p "$SRC/build"
/usr/bin/xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 -o "$BIN" "$SRC/Main.swift"

echo "== 2/6 图标（缺失或改了生成器才重做） =="
if [ ! -f "$ICNS" ] || [ "$SRC/makeicon.swift" -nt "$ICNS" ]; then
  /usr/bin/xcrun swiftc -O -o "$SRC/build/makeicon" "$SRC/makeicon.swift"
  /bin/rm -rf "$SRC/build/AppIcon.iconset"
  "$SRC/build/makeicon" "$SRC/build/AppIcon.iconset"
  /usr/bin/iconutil -c icns "$SRC/build/AppIcon.iconset" -o "$ICNS"
  echo "   已重新生成 AppIcon.icns"
else
  echo "   沿用已有 AppIcon.icns"
fi

echo "== 3/6 关闭运行中的旧实例 =="
/usr/bin/pkill -f "MacOS/MBMenuBar" 2>/dev/null || true
sleep 1

echo "== 4/6 组装 .app =="
/bin/rm -rf "$APP"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f "$BIN" "$APP/Contents/MacOS/MBMenuBar"
/bin/chmod +x "$APP/Contents/MacOS/MBMenuBar"
/bin/cp -f "$SRC/Info.plist" "$APP/Contents/Info.plist"
/bin/cp -f "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== 5/6 签名 =="
# 关键：swiftc 产出的二进制自带 ad-hoc 签名，直接签整个包会在封条里留下
# .cstemp 临时文件引用导致校验失败。先摘掉预置签名再签。
/usr/bin/codesign --remove-signature "$APP/Contents/MacOS/MBMenuBar" 2>/dev/null || true
/usr/bin/codesign --force --sign - --identifier com.oscar.mbmenubar "$APP"
/usr/bin/codesign --verify --verbose=1 "$APP"

echo "== 6/6 启动 =="
/usr/bin/open "$APP"
sleep 2
/usr/bin/pgrep -fl "MacOS/MBMenuBar" && echo "已启动 ✓" || echo "启动失败 ✗"
