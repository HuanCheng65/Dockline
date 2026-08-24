#!/bin/bash
# 把 Dockline.app 打成带版面的 .dmg。
#
# 为什么不用 create-dmg：它本质上也是 hdiutil + AppleScript 驱动访达，
# 换不来任何东西，却让仓库多一个 Homebrew 依赖。这里直接写这两步。
#
# 窗口版面（图标坐标、窗口尺寸）与 Scripts/dmg-background.swift 里的常量一一对应，
# 改任何一个都要两边一起改——背景图不会被访达缩放，错位就是错位。
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Dockline.app"
VOLNAME="Dockline"
MOUNT="/Volumes/$VOLNAME"
WORK="$ROOT/.build/dmg"
STAGE="$WORK/stage"

# ⚠️ 与 dmg-background.swift 的 W/H/iconY/appIconX/dstIconX/iconSide 保持同步
WIN_W=620
WIN_H=372          # 内容区高度，不含标题栏
TITLEBAR=28        # 访达 bounds 含标题栏，背景图只覆盖内容区
ICON_SIZE=128
ICON_Y=180
APP_X=170
DST_X=450

if [ -d "$MOUNT" ]; then
    echo "❌ /Volumes/$VOLNAME 已挂载（多半是上次失败留下的）。" >&2
    echo "   先 hdiutil detach \"$MOUNT\" 再重来。" >&2
    exit 1
fi

"$ROOT/Scripts/build-app.sh" "$CONFIG"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/.build/Dockline-$VERSION.dmg"
RW_DMG="$WORK/rw.dmg"

# ── 组装挂载后要看到的目录树 ────────────────────────────────────────
rm -rf "$WORK"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/Dockline.app"
ln -s /Applications "$STAGE/Applications"

swift "$ROOT/Scripts/dmg-background.swift" "$STAGE/.background" "$VERSION"
# .tiff 里同时塞 @1x 与 @2x，Retina 屏才不会拿 1x 图放大
tiffutil -cathidpicheck "$STAGE/.background/background.png" \
                        "$STAGE/.background/background@2x.png" \
         -out "$STAGE/.background/background.tiff" >/dev/null
rm "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png"

# 挂载后磁盘本身也用 App 的图标
cp "$APP/Contents/Resources/Dockline.icns" "$STAGE/.VolumeIcon.icns"

# ── 先做一张可写盘，摆好版面再压成只读盘 ──────────────────────────
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))   # 留出 .DS_Store 与 HFS 元数据的余量
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" "$RW_DMG" >/dev/null

DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" \
       | grep '^/dev/' | head -1 | awk '{print $1}')"
if [ -z "$DEV" ]; then
    echo "❌ 挂载 $RW_DMG 失败" >&2
    exit 1
fi

echo "摆放窗口版面（首次运行会弹窗请求「终端控制访达」的自动化权限）…"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {180, 140, $((180 + WIN_W)), $((140 + WIN_H + TITLEBAR))}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 12
        set background picture of opts to file ".background:background.tiff"
        set position of item "Dockline.app" of container window to {$APP_X, $ICON_Y}
        set position of item "Applications" of container window to {$DST_X, $ICON_Y}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

# 让磁盘自己用 .VolumeIcon.icns：这要求卷的 FinderInfo 打上 custom-icon 位。
# SetFile 属于已废弃的 Xcode 命令行工具，不一定在；缺席时直接写那 32 字节。
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT"
else
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
fi

# 访达把版面写进 .DS_Store 是异步的；不等它落盘就 detach，位置会随机丢失
sync
sleep 2

detached=false
for _ in 1 2 3 4 5; do
    if hdiutil detach "$DEV" >/dev/null 2>&1; then
        detached=true
        break
    fi
    sleep 2
done
if [ "$detached" != true ]; then
    echo "❌ 卸载 $DEV 失败（有进程还占着卷）。" >&2
    exit 1
fi

rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$WORK"

echo "✅ $DMG  ($(du -h "$DMG" | cut -f1))"
echo "ℹ️  当前钥匙串里只有 Apple Development 身份，无法公证。"
echo "   拿到别的 Mac 上首次打开会被 Gatekeeper 拦，需要 xattr -dr com.apple.quarantine 或右键「打开」。"
