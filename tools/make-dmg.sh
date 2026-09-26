#!/bin/bash
# ManageBac-Buddy · Mac 版 → DMG 安装包
#
# 为什么不用 create-dmg：本机没装（brew 也没有）。hdiutil + ditto 是系统自带的，
# 完全够用 —— DMG 只是「一个可挂载的文件夹」，把 .app 和 /Applications 的软链
# 放进去，用户拖一下就装好了。
#
# 布局刻意保持极简（App + Applications 软链），不做背景图：
#   带背景的 DMG 需要在卷里放 .DS_Store，而这份 .DS_Store 必须由 Finder 在
#   真实挂载的卷上生成 —— 脚本没法凭空造一个可靠的出来。折腾出来的常常是
#   图标位置乱掉、窗口大小不对，反而比干净的默认视图更难看。
#   默认视图就是「App 在左、应用程序在右」，用户一眼就知道往哪拖。
#
# 用法：bash make-dmg.sh [版本号]     （默认 3.0）
set -e

VERSION="${1:-3.0}"
APPNAME="ManageBac-Buddy"
SRC="${MBBOARD_SRC:-$HOME/Desktop/$APPNAME}"
APP="$SRC/$APPNAME.app"
OUTDIR="${MBBOARD_DMG_OUT:-$HOME/Desktop}"
DMG="$OUTDIR/${APPNAME}-${VERSION}.dmg"
VOLNAME="$APPNAME"

if [ ! -d "$APP" ]; then
  echo "✘ 找不到 $APP" >&2
  echo "  先跑：cd ~/.mbboard/board/mac && bash build.sh" >&2
  exit 1
fi

STAGE="$(mktemp -d /tmp/mbdmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

echo "① 铺内容…"
# ditto 而不是 cp -R：它会保留扩展属性与资源分叉，
# 而 Info.plist / AppIcon.icns 之外的很多 App 元数据就在那儿。
/usr/bin/ditto "$APP" "$STAGE/$APPNAME.app"
# 拖拽安装的落点。少了这个软链，用户打开 DMG 只看到一个孤零零的 App，
# 不少人会直接就在 DMG 里双击运行 —— 那样 App 是从只读卷启动的，
# 数据目录、更新、图标缓存都会出现莫名其妙的问题。
ln -s /Applications "$STAGE/Applications"
# 使用说明跟着走一份。很多人挂载 DMG 的时候并不会去看 GitHub 的 README。
[ -f "$SRC/使用说明.html" ] && cp -f "$SRC/使用说明.html" "$STAGE/使用说明.html"
echo "   $(du -sh "$STAGE" | cut -f1) → $(ls "$STAGE" | tr '\n' ' ')"

echo "② 压制 DMG（UDZO / zlib）…"
rm -f "$DMG"
/usr/bin/hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO -fs HFS+ \
  -quiet "$DMG"

echo "③ 校验…"
/usr/bin/hdiutil verify "$DMG" >/dev/null 2>&1 && echo "   ✔ 映像完整"
# 挂载一次，确认里面的 App 真的签得住、软链没断。
# 只验证「文件在不在」是不够的 —— 之前踩过 ditto 漏掉可执行位的情况，
# 那时 DMG 本身完全是好的，用户装上去才发现打不开。
MNT="$(mktemp -d /tmp/mbdmgmnt.XXXXXX)"
/usr/bin/hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -quiet
if [ -x "$MNT/$APPNAME.app/Contents/MacOS/MBDashboard" ]; then
  echo "   ✔ 可执行位正常"
else
  echo "   ✘ 可执行位丢失！" >&2
fi
if /usr/bin/codesign --verify "$MNT/$APPNAME.app" 2>/dev/null; then
  echo "   ✔ 挂载后签名仍有效"
else
  echo "   ✘ 签名校验失败！" >&2
fi
[ -L "$MNT/Applications" ] && echo "   ✔ 应用程序软链在" || echo "   ✘ 缺 Applications 软链" >&2
/usr/bin/hdiutil detach "$MNT" -quiet
rmdir "$MNT" 2>/dev/null || true

echo "④ 完成"
ls -lh "$DMG" | awk '{print "   "$9"  "$5}'
SIZE=$(stat -f%z "$DMG")
echo "   $(echo "scale=1; $SIZE/1048576" | bc) MB"
