#!/bin/bash
# 组装 Dockline.app 并签名。
#
# 为什么不用 Xcode 工程：手写 pbxproj 难以维护，XcodeGen 是本任务不需要的依赖。
# swift build + 本脚本可让整个仓库保持纯文本、可 diff。
#
# 为什么必须用稳定签名身份：TCC（辅助功能 / 屏幕录制）的授权锚定在
# 「代码签名身份 + bundle ID」上。ad-hoc 签名锚定 cdhash，每次重新编译都会变，
# 导致两项权限每次构建后都要重新授权——日常迭代无法忍受。
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Dockline.app"
BUNDLE_ID="dev.starrydream.Dockline"   # ⚠️ 永不更改：TCC 授权与用户偏好的永久键

# 签名身份：可用 MOOR_SIGN_IDENTITY 覆盖；缺省取钥匙串里第一个可用的。
IDENTITY="${MOOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)}"

swift build -c "$CONFIG" --product Dockline
swift build -c "$CONFIG" --product dockctl

# 图标是 Icon Composer 的分层源文件（Resources/Dockline.icon），由 actool 编译。
# 产物有两份：Assets.car 供 macOS 26 取分层与材质效果，.icns 是取不到时的退路。
BIN="$ROOT/.build/$CONFIG/Dockline"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun actool "$ROOT/Resources/Dockline.icon" \
    --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon Dockline --output-partial-info-plist "$ROOT/.build/icon.plist" >/dev/null
cp "$BIN" "$APP/Contents/MacOS/Dockline"
# 活动状态的上报入口。放进 bundle，用户自行 ln -s 到 PATH 上。
cp "$ROOT/.build/$CONFIG/dockctl" "$APP/Contents/MacOS/dockctl"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Dockline</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Dockline</string>
    <!-- IconFile 指 .icns，IconName 指 Assets.car 里那份；两个都要，缺 IconName 的话
         macOS 26 取不到分层效果，图标会退成一张平图 -->
    <key>CFBundleIconFile</key><string>Dockline</string>
    <key>CFBundleIconName</key><string>Dockline</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 没有这一项，向访达发 Apple Event 会直接被拒且不弹授权询问 -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Dockline 需要控制「访达」来清倒废纸篓。</string>
    <!-- 无 Dock 图标、无菜单栏：Dockline 自身就是一根 bar，不占常驻空间 -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [ -z "$IDENTITY" ]; then
    echo "⚠️  钥匙串里没有可用的代码签名身份，退回 ad-hoc 签名。" >&2
    echo "    后果：每次重新编译后辅助功能与屏幕录制权限都会失效，需重新授权。" >&2
    codesign --force --sign - "$APP"
else
    echo "签名身份: $IDENTITY"
    codesign --force --sign "$IDENTITY" "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo "✅ $APP"
