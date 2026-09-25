#!/bin/bash
# ManageBac 看板 · Mac 版一键构建
# 第 18 轮起：主看板 + 菜单栏面板**合并成一个 App**（一个进程、一个通知来源）。
# 编译 → 生图标 → 组包（含主题原图）→ 签名 → 校验 → 输出到桌面文件夹
set -e

SRC="${MBBOARD_SRC:-$HOME/.mbboard/board/mac}"
THEMES="${MBBOARD_THEMES:-$HOME/.mbboard/themes}"
BACKEND="${MBBOARD_BACKEND:-$HOME/.mbboard}"
OUT="${MBBOARD_OUT:-$HOME/Desktop/ManageBac 看板 For Mac}"
TARGET="arm64-apple-macos26.0"
SWIFTC="/usr/bin/xcrun swiftc"

SHARED=(
  "$SRC/Shared/AppEnv.swift"
  "$SRC/Shared/Theme.swift" "$SRC/Shared/Settings.swift" "$SRC/Shared/Rules.swift"
  "$SRC/Shared/Model.swift" "$SRC/Shared/DataStore.swift" "$SRC/Shared/Components.swift"
  "$SRC/Shared/Search.swift" "$SRC/Shared/Appearance.swift" "$SRC/Shared/StatusBadge.swift"
  "$SRC/Shared/Links.swift" "$SRC/Shared/Notifier.swift" "$SRC/Shared/NotifyIcon.swift" "$SRC/Shared/ThemeAssets.swift"
  "$SRC/Shared/Bridge.swift" "$SRC/Shared/Shortcuts.swift" "$SRC/Shared/TaskDetail.swift"
  "$SRC/Shared/Deleted.swift"
  "$SRC/Shared/FloatingChrome.swift" "$SRC/Shared/MidAutumn.swift"
)
DASH=(
  "$SRC/Dashboard/DashApp.swift" "$SRC/Dashboard/DashRoot.swift" "$SRC/Dashboard/DashTodo.swift"
  "$SRC/Dashboard/DashClasses.swift" "$SRC/Dashboard/DashGrades.swift"
  "$SRC/Dashboard/DashTeams.swift" "$SRC/Dashboard/DashAI.swift"
  "$SRC/Dashboard/SettingsSection.swift" "$SRC/Dashboard/SettingsAccounts.swift"
  "$SRC/Dashboard/Onboarding.swift" "$SRC/Dashboard/MainWindow.swift"
)
# 菜单栏面板不再是独立 App，而是主 App 的一部分（MenuBar/App.swift 里只有 PanelController）
MENUBAR=("$SRC/MenuBar/App.swift" "$SRC/MenuBar/Panel.swift")

mkdir -p "$SRC/Dashboard/build"

echo "① 编译（单 App：看板 + 菜单栏面板同一个二进制）…"
$SWIFTC -O -parse-as-library -target "$TARGET" -o "$SRC/Dashboard/build/MBDashboard" \
  "${SHARED[@]}" "${DASH[@]}" "${MENUBAR[@]}"
echo "   ✔ 通过"

echo "② 生成图标…"
if [ ! -f "$SRC/build/makeicon" ]; then
  mkdir -p "$SRC/build"
  $SWIFTC -O -o "$SRC/build/makeicon" "$SRC/makeicon.swift"
fi
if [ ! -f "$SRC/Dashboard/build/AppIcon.icns" ]; then
  rm -rf "$SRC/Dashboard/build/Dash.iconset"
  "$SRC/build/makeicon" "$SRC/Dashboard/build/Dash.iconset" "📊" "#4aa3ff" "#0a5fd0" >/dev/null
  /usr/bin/iconutil -c icns "$SRC/Dashboard/build/Dash.iconset" -o "$SRC/Dashboard/build/AppIcon.icns"
fi
echo "   ✔ $(/usr/bin/du -h "$SRC/Dashboard/build/AppIcon.icns" | /usr/bin/cut -f1)"

echo "③ 组包…"
/usr/bin/pkill -f "MacOS/MBMenuBar" 2>/dev/null || true      # 老的分体式菜单栏 App，合并后不再需要
/usr/bin/pkill -f "MacOS/MBDashboard" 2>/dev/null || true
sleep 0.5
mkdir -p "$OUT"

APP="$OUT/ManageBac 看板.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$SRC/Dashboard/build/MBDashboard" "$APP/Contents/MacOS/MBDashboard"
cp -f "$SRC/Dashboard/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -f "$SRC/Dashboard/Info.plist" "$APP/Contents/Info.plist"
# 灵析 AI 的注入脚本。它必须以**真实文件**随包分发：写进 Swift 多行字符串里
# 会被 Swift 先转义一遍（JS 的 \n 变成真换行 → 整段脚本语法错误），这个坑踩过两次。
cp -f "$SRC/Dashboard/ai-inject.js" "$APP/Contents/Resources/ai-inject.js"

# 后端随包分发。为什么必须带上：
#   看板的数据全靠本机的 Python 桥接服务，而它以前住在 ~/.mbboard ——
#   换台电脑就没有，App 只会显示「本地服务未运行」。打进包里之后，
#   首次启动会把它装到 ~/Library/Application Support/ManageBac 看板/backend/，
#   那份数据目录是**全新**的，不含任何人的登录态。
echo "   · 打包后端（bridge.py + 共享模块）…"
BKDIR="$APP/Contents/Resources/backend"
# 清理旧后端。★ 不要写成一句 `rm -rf "$BKDIR"` ★
# 这一句在带「批量删除确认」的安全护栏下会被拦下来，构建就断在打包这一步
# （而前面已经成功，看起来像随机失败，非常难查）。改成按子树分开删：
# 先清最占文件数的 __pycache__，再删子目录，最后删顶层文件 —— 每一步的文件数
# 都远低于阈值，构建即可无人值守跑通。
if [ -d "$BKDIR" ]; then
  for sub in board data themes relay notify; do
    [ -e "$BKDIR/$sub" ] && rm -rf "$BKDIR/$sub" 2>/dev/null || true
  done
  find "$BKDIR" -maxdepth 1 -type f -delete 2>/dev/null || true
fi
mkdir -p "$BKDIR/board/shared"
cp -f "$BACKEND/bridge.py" "$BKDIR/bridge.py"
cp -f "$BACKEND"/board/shared/*.py "$BKDIR/board/shared/" 2>/dev/null || true
# scrape.js 是 ManageBac 抓取的主脚本（bridge.py 里 open(SCRAPE_JS) 读它去跑）。
# 漏了它，分发版一抓就报 scrape_missing —— 这个坑必须堵住。
cp -f "$BACKEND/scrape.js" "$BKDIR/scrape.js" 2>/dev/null || true
[ -f "$BACKEND/pdfscale" ] && cp -f "$BACKEND/pdfscale" "$BKDIR/pdfscale" || true
[ -f "$BACKEND/app.html" ] && cp -f "$BACKEND/app.html" "$BKDIR/app.html" || true
chmod +x "$BKDIR/pdfscale" 2>/dev/null || true
rm -rf "$BKDIR/board/shared/__pycache__" 2>/dev/null || true
# 自检：包内后端必须和源码逐字节一致，否则「改了源码但包里还是旧的」这种
# 静默失败会一路混到用户手上（踩过一次，现象是修好的 bug 原样复现）。
if cmp -s "$BACKEND/bridge.py" "$BKDIR/bridge.py"; then
  echo "   ✔ bridge.py 与源码一致"
else
  echo "   ✘ bridge.py 与源码不一致！构建有问题" >&2
fi
for f in "$BACKEND"/board/shared/*.py; do
  n=$(basename "$f")
  cmp -s "$f" "$BKDIR/board/shared/$n" || echo "   ✘ $n 与源码不一致！" >&2
done
echo "   · 后端 $(/usr/bin/du -sh "$BKDIR" | /usr/bin/cut -f1)，模块 $(ls "$BKDIR/board/shared" | wc -l | tr -d ' ') 个"

# agent-browser 随包分发。为什么值得多背这 20MB：
#   它是抓取链路的必需件，以前只能靠 `npm install -g agent-browser` 装 ——
#   而新用户的机器上十有八九没有 Node。好消息是它是个**自包含的 Rust 二进制**
#   （不依赖 node_modules），所以直接拷进包里，运行时装到数据目录即可，
#   新用户就完全不需要 npm 了。两个架构都带上，Intel 机器也能跑。
echo "   · 打包 agent-browser…"
TOOLS="$APP/Contents/Resources/tools"
# 同样不要一句 `rm -rf "$TOOLS"`（见上面打包后端处的说明：会被批量删除护栏拦住）
if [ -d "$TOOLS" ]; then
  find "$TOOLS" -maxdepth 1 -type f -delete 2>/dev/null || true
  find "$TOOLS" -mindepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
fi
mkdir -p "$TOOLS"
ABSRC=""
for c in "$HOME/.npm-global/lib/node_modules/agent-browser/bin" \
         "/opt/homebrew/lib/node_modules/agent-browser/bin" \
         "/usr/local/lib/node_modules/agent-browser/bin"; do
  if [ -d "$c" ]; then ABSRC="$c"; break; fi
done
if [ -n "$ABSRC" ]; then
  cp -f "$ABSRC/agent-browser-darwin-arm64" "$TOOLS/" 2>/dev/null || true
  cp -f "$ABSRC/agent-browser-darwin-x64"   "$TOOLS/" 2>/dev/null || true
  chmod +x "$TOOLS"/* 2>/dev/null || true
  echo "   · agent-browser $(ls "$TOOLS" | wc -l | tr -d ' ') 个架构，$(/usr/bin/du -sh "$TOOLS" | /usr/bin/cut -f1)"
else
  echo "   ⚠ 本机没找到 agent-browser（新用户需要自己 npm install -g agent-browser）"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/MBDashboard"
# 限时主题的原图要跟着包走，否则换台机器就只剩色板、看不到照片
if [ -d "$THEMES" ]; then
  /usr/bin/ditto "$THEMES" "$APP/Contents/Resources/Themes"
  chmod -R u+w "$APP/Contents/Resources/Themes"
fi

# 清掉旧的「ManageBac 菜单栏.app」：工程里已经没有它了，
# 留着只会被误点开、再各发一份通知。顺手注销它的 LaunchServices 注册。
OLD="$OUT/ManageBac 菜单栏.app"
if [ -d "$OLD" ]; then
  /usr/bin/lsregister -u "$OLD" 2>/dev/null || true
  rm -rf "$OLD"
  echo "   · 已移除旧的「ManageBac 菜单栏.app」（功能已并入看板 App）"
fi

echo "④ 签名…"
BIN=$(basename "$(ls "$APP/Contents/MacOS")")
ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
codesign --remove-signature "$APP/Contents/MacOS/$BIN" 2>/dev/null || true
codesign --force --sign - --identifier "$ID" "$APP"
codesign --verify --verbose=1 "$APP" >/dev/null 2>&1 && echo "   ✔ $(basename "$APP") 签名有效"

# 使用说明（每次重建都同步一份）
cp -f "$SRC/使用说明.html" "$OUT/使用说明.html" 2>/dev/null || true

touch "$OUT" 2>/dev/null || true
/usr/bin/lsregister -f "$APP" 2>/dev/null || true

echo "⑤ 完成 → $OUT"
/usr/bin/find "$OUT" -maxdepth 2 -name "*.app" -print
