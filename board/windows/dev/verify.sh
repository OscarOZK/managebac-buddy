#!/bin/bash
# ======================================================================
# Windows 版渲染自检（开发期用，不参与打包）
#   在本机用 Electron 拉起渲染层，切到指定分区、截图、并导出布局实测数据。
#   关掉登录浮层：每次运行前把缓存时间戳刷成「刚刚」，这样引擎会直接给缓存。
#
#   用法：./dev/verify.sh <分区> [输出png] [滚动位置] [主题]
#         MB_SIZE=1366x768 ./dev/verify.sh todo        # 模拟小屏
#         ./dev/verify.sh todo /tmp/a.png
#         ./dev/verify.sh grades /tmp/b.png 600
# ======================================================================
set -e
cd "$(dirname "$0")/.."

SEC="${1:-todo}"
OUT="${2:-/tmp/mbwin_$SEC.png}"
SCROLL="${3:-0}"
THEME="${4:-}"

NODE_BIN_DIR="${MBBOARD_NODE_BIN_DIR:-$(dirname "$(command -v node)")}"
UD="$HOME/Library/Application Support/ManageBac-Buddy"
PROBE="/tmp/mbwin_probe_$SEC.json"

# 让引擎认为缓存是新鲜的；顺便把主题写进设置，方便验证深色模式
/usr/bin/python3 - "$UD" "$THEME" <<'PY'
import json, os, sys, time
ud, theme = sys.argv[1], sys.argv[2]
p = os.path.join(ud, 'cache.json')
if os.path.exists(p):
    d = json.load(open(p))
    d['__cachedAt'] = int(time.time() * 1000)
    json.dump(d, open(p, 'w'), ensure_ascii=False)
    print('cache refreshed:', p)
else:
    print('WARN 没有缓存文件，将显示登录浮层')

if theme:
    sp = os.path.join(ud, 'settings.json')
    s = {}
    if os.path.exists(sp):
        try: s = json.load(open(sp))
        except Exception: s = {}
    s['theme'] = theme
    json.dump(s, open(sp, 'w'), ensure_ascii=False)
    print('theme =', theme)
PY

env -u ELECTRON_RUN_AS_NODE \
    MB_CAPTURE="$OUT" \
    MB_PROBE="$PROBE" \
    MB_GOTO="$SEC" \
    MB_SCROLL="$SCROLL" \
    MB_CAPTURE_DELAY="${MB_DELAY:-6500}" \
    MB_SIZE="${MB_SIZE:-}" \
    ./node_modules/.bin/electron . 2>&1 | grep -E "CAPTURED|PROBED|CAPTURE_FAIL|GOTO" || true

echo "--- 溢出检查（超出窗口右边界 1px 以上的元素）---"
/usr/bin/python3 - "$PROBE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print('窗口宽', d['win']['innerW'], '| shell 宽', d['.shell']['w'], '| main 宽', d['.main']['w'])
o = d.get('overflowing') or []
if not o:
    print('✓ 无溢出')
else:
    print('⚠', len(o), '个元素越界：')
    for x in o[:20]:
        print('   ', x)
PY
echo "截图: $OUT"
