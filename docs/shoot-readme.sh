#!/bin/bash
# ==========================================================================
#  渲染 README 用的全套截图
#
#  隐私前提（这首要）
#  ------------------
#  README 里的图一旦推到 GitHub 就删不干净了（fork、缓存、爬虫都留档）。
#  所以这里**每一张**都必须走 `--data` 指到虚构数据目录，让作业标题、
#  成绩、课表里的老师姓名、教室号全部来自 tools/make-demo-cache.py 造的假数据。
#
#  为什么不用真机截图
#  ------------------
#  真机截图会带出真实数据；而且 `--data` 只存在于离屏自检里，正式 App 没有这个开关，
#  没法「用假数据启动真 App」。离屏渲染走的是同一套 SwiftUI 视图代码，
#  除了窗口背板的系统级毛玻璃采样不到（离屏没有桌面可采样），
#  版式、配色、圆角、层次全都是真的。
#
#  为什么要一张一张来
#  ------------------
#  以前用 for 循环串跑，跑到一半被超时 SIGTERM 打断，而且**串图** ——
#  第 3 张深色渲染出来是浅色。所以这里一次只跑一张、跑完立刻落盘，
#  中途被打断也只丢后面那几张，不会有脏图。
#
#  用法：bash docs/shoot-readme.sh          # 全跑
#        bash docs/shoot-readme.sh todo     # 只跑名字里含 todo 的
# ==========================================================================
set -e

MBB="${MBB_HOME:-$HOME/.mbboard}"
SRC="$MBB/board/mac"
DATA="$MBB/docs/demo-data"
OUT="$MBB/docs/images"
TEAMS="$DATA/teams-mock.json"

# 固定的「今天」：周五 20:00 —— 月夜刚亮、且是正课日，
# 课表和倒计时那两块都会进入它们最完整的形态。
DAY="2026-09-25"
AT="20:00"

FILTER="${1:-}"

# 收尾瘦身那一步要 PIL。本机的 PIL 只装在托管 venv 里
# （系统 python3 里没有，直接用会 ImportError）。
PYBIN="${MBB_PYTHON:-$HOME/.workbuddy/binaries/python/envs/default/bin/python}"

mkdir -p "$OUT"

# 单张：名字 + 透传给 render.sh 的其余参数
shot() {
  local name="$1"; shift
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then return 0; fi
  printf '\n── %s ─────────────────────────────\n' "$name"
  bash "$SRC/render.sh" \
    --data "$DATA" \
    --date "$DAY" --at "$AT" \
    --out "$OUT/$name.png" \
    "$@" 2>&1 | grep -Ev 'warning:|note:|^\s*[0-9]+ \||^\s*\||^$|Sendable|@interface|API_AVAILABLE|preconcurrency|^\s+[0-9]+ \|'
}

# 上线提示是「档期内每次启动都会弹」的（它由 DashRoot 的内存态管着），
# 而自检本身就是一次启动 —— 所以**默认每张图都会被它挡个正着**。
# 除了专门拍它那一张（--moon），其余一律加 --nomoon 按掉。
NOMOON=(--nomoon)

# ── ① 待办：主视觉（亮 / 暗各一张）──────────────────────────────────────
shot todo-dark "${NOMOON[@]}" --section todo --dark --w 1260 --h 940
shot todo-light "${NOMOON[@]}" --section todo --light --w 1260 --h 940

# ── ② 那四个功能页 ────────────────────────────────────────────────────────
shot teams-dark "${NOMOON[@]}" --section teams --dark --w 1260 --h 1080 --teams-mock "$TEAMS"
shot classes-dark "${NOMOON[@]}" --section classes --dark --w 1260 --h 1020
shot grades-dark "${NOMOON[@]}" --section grades --dark --w 1260 --h 1020

# ── ③ 灵析 AI ────────────────────────────────────────────────────────────
shot ai-dark "${NOMOON[@]}" --section ai --dark --w 1260 --h 1000

# ── ④ 设置 ──────────────────────────────────────────────────────────────
#  甲：整页顶部（主题 + 账号管理），让人看到「设置里有什么」
shot settings-dark "${NOMOON[@]}" --section settings --dark --w 1260 --h 1240
#  乙：通知那一段。设置页整页有 7000pt 高、离屏一次只能量到一屏，
#      所以单独渲一次高画布再裁出来（裁剪交给最后的 Python 收尾步骤）。
shot settings-notify "${NOMOON[@]}" --section settings --dark --w 1260 --h 7000

# ── ⑤ 主题：同一页面换五套配色，横着比一眼就看出差别 ────────────────────
# 四套浅色用同一份浅色布局，月圆自带 forcesDark（选它就整个 App 深色）。
shot theme-classic "${NOMOON[@]}" --section todo --light --w 1260 --h 880
shot theme-emberglow "${NOMOON[@]}" --section todo --light --w 1260 --h 880 --palette emberglow
shot theme-verdant "${NOMOON[@]}" --section todo --light --w 1260 --h 880 --palette verdant
shot theme-xuanzhi "${NOMOON[@]}" --section todo --light --w 1260 --h 880 --palette xuanzhi
shot theme-moonfest "${NOMOON[@]}" --section todo --w 1260 --h 880 --palette moonfest

# ── ⑥ 中秋限定主题的上线提示（通知机制的实体样本）────────────────────────
shot moon-notice      --section todo --w 1260 --h 940 --palette moonfest --moon

# ── ⑦ 菜单栏小面板：就是那个「点一下弹出、不影响心流」的小看板 ──────────
shot panel-dark "${NOMOON[@]}" --panel --dark --w 480 --h 780
shot panel-light "${NOMOON[@]}" --panel --light --w 480 --h 780
shot panel-moonfest "${NOMOON[@]}" --panel --w 480 --h 780 --palette moonfest

# ── 收尾：瘦身 ──────────────────────────────────────────────────────────
# 上面每张都是 2 倍图（1260pt → 2520px），单张 1–4 MB，全套 24 MB 上下。
# README 里的显示宽度不会超过 900px，所以按 1680px 重采样、量化到 256 色，
# 一套下来约 5 MB —— 体积降到 1/5，肉眼几乎看不出差别
# （UI 截图是大片纯色 + 少量文字，正是量化最擅长的场景）。
# 这一步**不做** FILTER 过滤：单张调试时同样需要它。
# 否则那张图会以 2 倍原图留在磁盘上，和别的已瘦身图混在一起，
# 下次「只看一张」时就分不清是「图糊了」还是「根本没压缩」。
printf '\n── 瘦身 ─────────────────────────────\n'
"$PYBIN" - "$OUT" <<'PYEOF'
import glob, os, sys
from PIL import Image

out = sys.argv[1]
W, C = 1680, 256

# 少数几张「整页超长图」不能整张放进 README，要在收尾这一步裁出要用的那一段。
# 裁剪放这里而不是渲染时：离屏渲染量不到「内容到底有多高」，
# 只能先渲一张够高的整页（如 7000pt），再由像素坐标精确裁。
#   文件名 → (左, 上, 右, 下)，坐标基于 2 倍原图；右/下为 None 表示到边缘。
CROPS = {
    # 设置页：从「通知」标题上方一点，到「系统权限」结束
    "settings-notify.png": (380, 6250, None, 9300),
}

def shrink(im):
    if im.width > W:
        im = im.resize((W, round(im.height * W / im.width)), Image.LANCZOS)
    return im

b = a = 0
for p in sorted(glob.glob(os.path.join(out, "*.png"))):
    b += os.path.getsize(p)
    im = Image.open(p).convert("RGB")

    box = CROPS.get(os.path.basename(p))
    if box:
        l, t, r, bo = box
        im = im.crop((l, t, r or im.width, bo or im.height))

    im = shrink(im)
    im.quantize(colors=C, method=Image.MEDIANCUT, dither=Image.FLOYDSTEINBERG) \
      .save(p, optimize=True)
    a += os.path.getsize(p)

print(f"  {b/1048576:.1f} MB → {a/1048576:.1f} MB（省 {(1-a/b)*100:.0f}%）")
PYEOF

printf '\n全部完成 → %s\n' "$OUT"
ls -1 "$OUT"/*.png | sed 's|.*/|  |'
