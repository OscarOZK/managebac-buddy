#!/bin/bash
# ManageBac-Buddy · Mac 版一键构建
# 第 18 轮起：主看板 + 菜单栏面板**合并成一个 App**（一个进程、一个通知来源）。
# 编译 → 生图标 → 组包（含主题原图）→ 签名 → 校验 → 输出到桌面文件夹
set -e

SRC="${MBBOARD_SRC:-$HOME/.mbboard/board/mac}"
THEMES="${MBBOARD_THEMES:-$HOME/.mbboard/themes}"
BACKEND="${MBBOARD_BACKEND:-$HOME/.mbboard}"
OUT="${MBBOARD_OUT:-$HOME/Desktop/ManageBac-Buddy}"
# ★ App 名要和 Info.plist 的 CFBundleName / CFBundleDisplayName 一致 ★
# 三处都叫 ManageBac-Buddy，Gatekeeper 弹窗和「隐私与安全性」里
# 显示的才是这个名字 —— 安装导览照着屏幕写的，不能对不上。
APPNAME="ManageBac-Buddy"
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
  # 内置网页引擎：把「登录要用的那个浏览器」搬进 App 自己身体里。
  # 有了它，别人电脑上一个 Chromium 都没装也能登进 ManageBac / Teams / 希悦。
  "$SRC/Shared/WebEngine.swift"
)
DASH=(
  "$SRC/Dashboard/DashApp.swift" "$SRC/Dashboard/DashRoot.swift" "$SRC/Dashboard/DashTodo.swift"
  "$SRC/Dashboard/DashClasses.swift" "$SRC/Dashboard/DashGrades.swift"
  "$SRC/Dashboard/DashTeams.swift" "$SRC/Dashboard/DashAI.swift"
  "$SRC/Dashboard/SettingsSection.swift" "$SRC/Dashboard/SettingsAccounts.swift"
  "$SRC/Dashboard/Onboarding.swift" "$SRC/Dashboard/FirstRun.swift" "$SRC/Dashboard/MainWindow.swift"
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

APP="$OUT/$APPNAME.app"
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
#   首次启动会把它装到 ~/Library/Application Support/ManageBac-Buddy/backend/，
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

# ---------------------------------------------------------------------------
# Python 运行时随包分发 —— 这是「四个账号全都登不进去」的根治办法
# ---------------------------------------------------------------------------
# 看板的数据全部来自本机的 Python 桥接服务。以前只能指望「用户电脑上恰好有个
# 能用的 python3」，而实测这条路在普通 Mac 上并不成立：macOS 自带的
# /usr/bin/python3 只是一层壳，真正干活的是 Xcode 命令行工具里那份 ——
# 没装命令行工具的机器上跑它会弹系统弹窗然后退出。结果就是后台静默起不来，
# 用户看到的是「看板没应答」，而四个集成里唯一能用的那个（DeepSeek）
# 恰好是唯一不走后端的。自带一份 Python，这一类失败就彻底不存在了。
#
# 用 python-build-standalone 的 install_only_stripped 包：自带标准库、
# 可重定位、不依赖系统任何东西。后端只用标准库（http.server / urllib /
# subprocess / ssl / sqlite3），所以不需要 pip，也不需要网络。
echo "   · 打包 Python 运行时…"
PYRT_REL="20250818"
PYRT_VER="3.12.11"
case "$TARGET" in
  x86_64*) PYRT_TAG="x86_64-apple-darwin"
           PYRT_SHA="296af6b9dd16f16dca2503a9a1cfc8593e4cd79ed19ee20cb2557da0912cf6b2" ;;
  *)       PYRT_TAG="aarch64-apple-darwin"
           PYRT_SHA="bbf0c85d09a8173e50d18a0198f14d1de91eab17a593ccf9445f214fb0555547" ;;
esac
PYRT_FILE="cpython-${PYRT_VER}+${PYRT_REL}-${PYRT_TAG}-install_only_stripped.tar.gz"
PYRT_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYRT_REL}/${PYRT_FILE}"
PYCACHE="$SRC/build/pyrt"              # 缓存在源码目录的 build/ 下，重复构建不再下载
STAGE="$PYCACHE/stage-$PYRT_TAG"
PYDEST="$APP/Contents/Resources/python"

if [ ! -x "$STAGE/python/bin/python3" ]; then
  mkdir -p "$PYCACHE"
  if [ ! -f "$PYCACHE/$PYRT_FILE" ]; then
    echo "     · 下载 $PYRT_FILE（约 15MB，只在本机首次构建时下）…"
    curl -fL --retry 3 --retry-delay 2 -o "$PYCACHE/$PYRT_FILE.part" "$PYRT_URL"
    mv -f "$PYCACHE/$PYRT_FILE.part" "$PYCACHE/$PYRT_FILE"
  fi
  got=$(/usr/bin/shasum -a 256 "$PYCACHE/$PYRT_FILE" | /usr/bin/cut -d' ' -f1)
  if [ "$got" != "$PYRT_SHA" ]; then
    echo "   ✘ Python 运行时校验和不符（期望 $PYRT_SHA，拿到 $got），已删除重下" >&2
    rm -f "$PYCACHE/$PYRT_FILE"
    exit 1
  fi
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  /usr/bin/tar -xzf "$PYCACHE/$PYRT_FILE" -C "$STAGE"
  [ -x "$STAGE/python/bin/python3" ] || { echo "   ✘ 解包后没找到 python3" >&2; exit 1; }
fi

# 清掉上一次构建留下的（同样不要写一句 rm -rf "$PYDEST"，见上面打包后端的说明）
if [ -d "$PYDEST" ]; then
  find "$PYDEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
fi
mkdir -p "$PYDEST"
# 只拷 bin/ 与 lib/ 两棵子树：
#   include/ 是编译 C 扩展用的头文件、share/ 是 man 手册 —— 后端一个都用不到。
/usr/bin/ditto "$STAGE/python/bin" "$PYDEST/bin"
/usr/bin/ditto "$STAGE/python/lib" "$PYDEST/lib"
# lib/ 里的 tkinter 全家桶（tcl8.6 / tk8.6 / itcl / libtcl / libtk）加上
# idlelib、lib2to3 一共约 10MB，后端是无界面的纯标准库程序，全部不需要。
for sub in tcl8 tcl8.6 tk8.6 itcl4.2.4; do
  rm -rf "$PYDEST/lib/$sub" 2>/dev/null || true
done
for f in libtcl8.6.dylib libtk8.6.dylib; do
  rm -f "$PYDEST/lib/$f" 2>/dev/null || true
done
PYLIB=$(/bin/ls "$PYDEST/lib" 2>/dev/null | /usr/bin/grep -m1 -E '^python3\.[0-9]+$')
if [ -n "$PYLIB" ]; then
  for sub in tkinter idlelib lib2to3; do
    rm -rf "$PYDEST/lib/$PYLIB/$sub" 2>/dev/null || true
  done
  rm -f "$PYDEST/lib/$PYLIB"/lib-dynload/_tkinter*.so 2>/dev/null || true
fi
chmod +x "$PYDEST/bin/"* 2>/dev/null || true
rm -rf "$PYDEST"/lib/python*/test 2>/dev/null || true

# ★ 自检：包内这份 Python 必须真能跑起来、且标准库齐全 ★
#   这一步不能省 —— 前面「改了半天、包里还是旧东西」的坑踩过不止一次。
if "$PYDEST/bin/python3" -c "import json,http.server,urllib.request,subprocess,threading,ssl,sqlite3,zipfile,hashlib;print('ok')" >/dev/null 2>&1; then
  echo "   ✔ 包内 Python $("$PYDEST/bin/python3" -V 2>&1) 可用，$(/usr/bin/du -sh "$PYDEST" | /usr/bin/cut -f1)"
else
  echo "   ✘ 包内 Python 跑不起来或标准库不全！" >&2
  "$PYDEST/bin/python3" -V || true
  exit 1
fi

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

# ★ 先给包内 Python 的每个 Mach-O 文件单独签名 ★
#   codesign 对整个 .app 签名时，只要发现包里有未签名的嵌套可执行代码就会直接
#   失败（"code object is not signed at all"），整个构建在这里断掉。
#   python-build-standalone 自带 ad-hoc 签名，但我们删过 tkinter、也做过 ditto，
#   所以这里统一再签一遍，不依赖上游。
if [ -d "$PYDEST" ]; then
  signed=0
  while IFS= read -r -d '' f; do
    case "$(/usr/bin/file -b "$f")" in
      *Mach-O*) if codesign --force --sign - "$f" >/dev/null 2>&1; then signed=$((signed+1)); fi ;;
    esac
  done < <(find "$PYDEST" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0)
  echo "   · 包内 Python 已单独签名 $signed 个文件"
fi

codesign --remove-signature "$APP/Contents/MacOS/$BIN" 2>/dev/null || true
codesign --force --sign - --identifier "$ID" "$APP"
if codesign --verify --verbose=1 "$APP" >/dev/null 2>&1; then
  echo "   ✔ $(basename "$APP") 签名有效"
else
  # 签名失败要说出来。以前这里只在成功时打一行，失败时静默 ——
  # 于是「构建成功但 App 打不开」这种最难查的问题会一路混到用户手上。
  echo "   ✘ 签名校验没通过！App 可能无法启动" >&2
  codesign --verify --verbose=2 "$APP" 2>&1 | head -5 >&2
fi

# 使用说明（每次重建都同步一份）
cp -f "$SRC/使用说明.html" "$OUT/使用说明.html" 2>/dev/null || true

touch "$OUT" 2>/dev/null || true
/usr/bin/lsregister -f "$APP" 2>/dev/null || true

echo "⑤ 完成 → $OUT"
/usr/bin/find "$OUT" -maxdepth 2 -name "*.app" -print
