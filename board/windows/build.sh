#!/bin/bash
# ======================================================================
# ManageBac-Buddy · Windows 版打包
# 在 macOS 上直接产出可在 Windows 上双击运行的原生应用
# （Electron 预编译二进制，win32-x64；64 位 Win10/11 均可，含 ARM 机型仿真运行）
#
# 产物结构（桌面文件夹「ManageBac-Buddy For Windows」）：
#   ├── ManageBac-Buddy.exe     ← 双击即用
#   ├── （运行所需的 dll / locales / resources …）
#   └── 使用说明.html
# ======================================================================
set -e

SRC="${MBBOARD_SRC:-$HOME/.mbboard/board/windows}"
OUT="${MBBOARD_OUT:-$HOME/Desktop/ManageBac-Buddy For Windows}"
APPNAME="ManageBac-Buddy"
NODE="${MBBOARD_NODE:-$(command -v node)}"
NPM="${MBBOARD_NPM:-$(command -v npm)}"
PACKAGER="$SRC/node_modules/@electron/packager/bin/electron-packager.js"

export ELECTRON_MIRROR="https://registry.npmmirror.com/-/binary/electron/"
export ELECTRON_CUSTOM_DIR="{{ version }}"

cd "$SRC"

echo "① 依赖…"
if [ ! -d node_modules/electron ]; then
  "$NPM" install --no-audit --no-fund
fi
echo "   ✔ electron $("$NODE" -p "require('./node_modules/electron/package.json').version" 2>/dev/null || echo '?')"

echo "② 图标…"
if [ ! -f assets/icon.ico ]; then
  mkdir -p assets/iconset
  "$HOME/.mbboard/board/mac/build/makeicon" "$SRC/assets/iconset" "📊" "#4aa3ff" "#0a5fd0" >/dev/null
  /usr/bin/python3 makeico.py assets/icon.ico \
    assets/iconset/icon_16x16.png assets/iconset/icon_32x32.png \
    assets/iconset/icon_32x32@2x.png assets/iconset/icon_128x128.png \
    assets/iconset/icon_256x256.png
fi
echo "   ✔ assets/icon.ico"

echo "③ 打包 win32-x64…"
rm -rf "$SRC/dist"
"$NODE" "$PACKAGER" . "MBBoard" \
  --platform=win32 --arch=x64 --out=dist --overwrite \
  --asar --prune=true \
  --icon=assets/icon.ico \
  --app-version=3.0.0 \
  --app-copyright="ManageBac Board" \
  --win32metadata.CompanyName="ManageBac Board" \
  --win32metadata.ProductName="$APPNAME" \
  --win32metadata.FileDescription="ManageBac-Buddy · 作业与成绩桌面看板" \
  --ignore="^/dist" --ignore="^/dev" --ignore="^/build\.sh$" --ignore="^/makeico\.py$" \
  --ignore="^/assets/iconset" --ignore="^/package-lock\.json$" --ignore="^/使用说明"

PKG="$SRC/dist/MBBoard-win32-x64"
[ -d "$PKG" ] || { echo "打包失败：找不到 $PKG"; exit 1; }

echo "④ 组装到桌面文件夹…"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$PKG/." "$OUT/"

# 把主程序改成中文名：双击这个就开
mv "$OUT/MBBoard.exe" "$OUT/${APPNAME}.exe"

# 使用说明
cp "$SRC/使用说明.html" "$OUT/使用说明.html" 2>/dev/null || true

echo "⑤ 完成 → $OUT"
/usr/bin/du -sh "$OUT" 2>/dev/null
/usr/bin/ls -1 "$OUT" | head -20
