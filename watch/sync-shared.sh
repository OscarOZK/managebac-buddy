#!/bin/zsh
# ManageBac Watch —— 把「App 与小组件共用」的源码同步到小组件目录
#
# 小组件是独立进程，拿不到 App 里的对象，但可以共享**源码**。
# 单一来源：只改 ManageBacWatch/Watch{Rules,Model,Theme,Derive}.swift，
# 这份脚本把它们复制成 ManageBacWatchWidgets/Shared*.swift。
# build.sh 和 render/run.sh 都会先跑它，保证 App / 小组件 / 自检工具三端口径一致。

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

for f in Rules Model Theme Derive; do
  {
    echo "//  本文件由 sync-shared.sh 从 ManageBacWatch/Watch$f.swift 自动同步，请勿手改。"
    echo ""
    /bin/cat "$HERE/ManageBacWatch/Watch$f.swift"
  } > "$HERE/ManageBacWatchWidgets/Shared$f.swift"
done

echo "→ 已同步 Shared{Rules,Model,Theme,Derive}.swift"
