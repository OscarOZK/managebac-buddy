#!/bin/bash
# 离屏渲染自检：编译 Dashboard/RenderCheck.swift 并跑一次
# 用法：./render.sh --section settings --group panel --h 1000 --out /tmp/x.png
#        ./render.sh --panel --quick --h 900 --out /tmp/panel.png
#        ./render.sh --section grades --chart chem --h 1000 --out /tmp/chart.png
#      额外开关：--quick（展开面板的快速设置） --nofollow（小看板用自己的主题）
#               --chart <学科key>（直接展开该学科的柱状图；真机要点一下才出来，
#                                 离屏没法点，只能开后门）
#               --cache <文件>（换一份 cache.json 渲染，做压力测试，不碰真缓存）
# 注意：自检过程里 BoardSettings.readOnly = true，不会写 settings.json。
#       --force 强制重编译（默认会按源码时间戳跳过，见下）
set -e
SRC="${MBBOARD_SRC:-$HOME/.mbboard/board/mac}"
BIN="$SRC/build/render"
mkdir -p "$SRC/build"

FORCE=0
ARGS=()
for a in "$@"; do
  if [ "$a" = "--force" ]; then FORCE=1; else ARGS+=("$a"); fi
done

# ── 编译缓存 ─────────────────────────────────────────────────────────────
# 一整轮自检要跑几十张图（分区 × 宽度 × 亮暗 × 主题）。以前每次调用都全量
# 重编译一遍，一次约 30 秒 —— 跑十张图就是五分钟，中途还容易被超时打断，
# 于是「只看了一半」变成常态。源码没动就没必要重编译：
#   build/render 比所有 .swift 都新 → 直接用现成的。
NEED=1
if [ "$FORCE" -eq 0 ] && [ -x "$BIN" ]; then
  if [ -z "$(find "$SRC" -name '*.swift' -newer "$BIN" -print -quit)" ]; then
    NEED=0
  fi
fi

if [ "$NEED" -eq 1 ]; then
  /usr/bin/xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 -o "$BIN" \
    "$SRC/Shared/AppEnv.swift" \
    "$SRC/Shared/Theme.swift" "$SRC/Shared/Settings.swift" "$SRC/Shared/Rules.swift" \
    "$SRC/Shared/Model.swift" "$SRC/Shared/DataStore.swift" "$SRC/Shared/Components.swift" \
    "$SRC/Shared/Search.swift" "$SRC/Shared/Appearance.swift" "$SRC/Shared/StatusBadge.swift" \
    "$SRC/Shared/Links.swift" "$SRC/Shared/Notifier.swift" "$SRC/Shared/NotifyIcon.swift" \
    "$SRC/Shared/ThemeAssets.swift" \
    "$SRC/Shared/Bridge.swift" "$SRC/Shared/Shortcuts.swift" "$SRC/Shared/TaskDetail.swift" \
    "$SRC/Shared/Deleted.swift" \
    "$SRC/Shared/FloatingChrome.swift" "$SRC/Shared/MidAutumn.swift" \
    "$SRC/Dashboard/DashRoot.swift" "$SRC/Dashboard/DashTodo.swift" \
    "$SRC/Dashboard/DashClasses.swift" "$SRC/Dashboard/DashGrades.swift" \
    "$SRC/Dashboard/DashTeams.swift" "$SRC/Dashboard/SettingsSection.swift" \
    "$SRC/Dashboard/SettingsAccounts.swift" "$SRC/Dashboard/DashAI.swift" \
    "$SRC/Dashboard/Onboarding.swift" "$SRC/Dashboard/FirstRun.swift" "$SRC/Dashboard/MainWindow.swift" "$SRC/Dashboard/RenderCheck.swift" \
    "$SRC/MenuBar/Panel.swift"
fi

"$BIN" "${ARGS[@]}"
