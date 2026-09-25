#!/bin/zsh
# 小组件版式自检 —— 在 Mac 上把 12 个小组件按表盘尺寸离屏渲染成一张对照图
#
#   bash render/run.sh                     用真实数据渲染一张
#   bash render/run.sh --offline           模拟「电脑上的看板服务没开」
#   bash render/run.sh --at 09:45          把「现在」定在某个时刻（核对课间 / 深夜等）
#   bash render/run.sh --at 23:30 out.png  指定输出文件
#
# 注意：玻璃/材质在离屏渲染里画不出来（WatchCard 会自动降级成普通材质），
#       这里只核对版式、字号、配色与数据。
# 小组件用到的 4 类形态在 Mac 上通过 MBFamily 注入（见 ManageBacWatchWidgets/MBFamily.swift）。

set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

# 先同步共享源码，保证自检用的就是 App / 小组件正在跑的那份
/bin/bash "$HERE/sync-shared.sh"

/usr/bin/xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 -o /tmp/wrender \
  ManageBacWatchWidgets/MBFamily.swift \
  ManageBacWatchWidgets/MBWidgetData.swift \
  ManageBacWatchWidgets/MBWidgetViews.swift \
  ManageBacWatchWidgets/MBWidgetMix.swift \
  ManageBacWatchWidgets/SharedRules.swift \
  ManageBacWatchWidgets/SharedModel.swift \
  ManageBacWatchWidgets/SharedTheme.swift \
  ManageBacWatchWidgets/SharedDerive.swift \
  render/WidgetRender.swift

/tmp/wrender "$@"
