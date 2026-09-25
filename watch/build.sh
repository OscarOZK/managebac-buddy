#!/bin/zsh
# ManageBac Watch App —— 编译 → 装进 Apple Watch 模拟器 → 启动
#
#   bash build.sh                 编译并部署到手表模拟器
#   bash build.sh --open          顺便打开模拟器窗口（需要图形界面）
#   bash build.sh --console       前台附着控制台（Ctrl-C 退出，能看到自检输出）
#
# 可选环境变量：
#   MBW_DEVICE=<udid>   指定模拟器；默认自动挑一台可用的 Apple Watch
#   MBW_DUMP=1          启动后打印数据自检
#   MBW_AT=09:45        把「现在」定在指定时刻
#   MBW_SCROLL=latest   启动后自动滚到某个分区（timer/todo/class/latest/gpa/footer）

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DD=/tmp/mbwatch-dd
BUNDLE_ID=cn.oscar.ManageBacWatch
APP="$DD/Build/Products/Debug-watchsimulator/ManageBacWatch.app"

# 1) 图标（改了 makeicon-watch.swift 才会重画）
if [ ! -f "$HERE/ManageBacWatch/Assets.xcassets/AppIcon.appiconset/icon-1024.png" ]; then
  /usr/bin/xcrun swiftc -O -o /tmp/mkicon-watch "$HERE/makeicon-watch.swift"
  /tmp/mkicon-watch "$HERE/ManageBacWatch/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
fi

# 2) 把「App 与小组件共用」的源码同步过去（单一来源：只改 ManageBacWatch/ 里那份）
#    小组件是独立进程，不能共享对象，但可以共享源码 —— 这样两端口径永远一致。
/bin/bash "$HERE/sync-shared.sh"

# 3) 选一台 Apple Watch 模拟器
DEV="${MBW_DEVICE:-}"
if [ -z "$DEV" ]; then
  DEV=$(/usr/bin/xcrun simctl list devices available \
        | /usr/bin/grep -m1 "Apple Watch" \
        | /usr/bin/sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
fi
if [ -z "$DEV" ]; then echo "找不到 Apple Watch 模拟器，先在 Xcode 里装一个 watchOS 运行时"; exit 1; fi
echo "→ 设备 $DEV"

# 4) 编译（会连同小组件扩展一起编，因为 App 依赖它）
/usr/bin/xcodebuild build \
  -project "$HERE/ManageBacWatch.xcodeproj" \
  -scheme ManageBacWatch \
  -destination "platform=watchOS Simulator,id=$DEV" \
  -derivedDataPath "$DD" 2>&1 | /usr/bin/grep -E "error:|warning:|BUILD" | /usr/bin/sort -u

# 5) 确认小组件扩展真的被嵌进 App（嵌入失败的话手表上根本看不到小组件）
if [ -d "$APP/PlugIns/ManageBacWatchWidgets.appex" ]; then
  PT=$(/usr/bin/plutil -extract NSExtension.NSExtensionPointIdentifier raw \
        "$APP/PlugIns/ManageBacWatchWidgets.appex/Info.plist" 2>/dev/null)
  echo "→ 小组件扩展已嵌入（$PT）"
else
  echo "⚠️ 没找到嵌入式小组件扩展，App 会在手表上装不上"
  exit 1
fi

# 6) 启动模拟器 + 装 + 跑
/usr/bin/xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1 || /usr/bin/xcrun simctl boot "$DEV" >/dev/null 2>&1
/usr/bin/xcrun simctl install "$DEV" "$APP"

export SIMCTL_CHILD_MBWATCH_DUMP="${MBW_DUMP:-0}"
[ -n "$MBW_AT" ]     && export SIMCTL_CHILD_MBWATCH_DUMP_AT="$MBW_AT"
[ -n "$MBW_SCROLL" ] && export SIMCTL_CHILD_MBWATCH_SCROLL_TO="$MBW_SCROLL"
[ "$MBW_GPA" = "1" ] && export SIMCTL_CHILD_MBWATCH_GPA=1

if [ "$1" = "--console" ]; then
  /usr/bin/xcrun simctl launch --terminate-running-process --console-pty "$DEV" "$BUNDLE_ID"
else
  /usr/bin/xcrun simctl launch --terminate-running-process "$DEV" "$BUNDLE_ID"
  if [ "$1" = "--open" ]; then open -a Simulator; fi
fi
echo "→ 已在手表模拟器上运行（$BUNDLE_ID）"
