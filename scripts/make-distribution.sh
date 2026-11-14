#!/bin/bash
# Hummingbird 分发构建：Developer ID 签名 → 公证 → 装订 → DMG
# 用法：
#   NOTARY_KEY_ID / NOTARY_KEY_ISSUER / NOTARY_KEY_PATH（App Store Connect API 密钥，推荐）
#   或 NOTARY_APPLE_ID / NOTARY_APP_PASSWORD（appleid.apple.com 生成的 App 专用密码）
#   SIGN_IDENTITY 形如 "Developer ID Application: NAME (TEAMID)"（缺省自动探测）
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="Q9TF3XSQ3N"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ScreenRecorder/Info.plist 2>/dev/null || echo "1.0")
APP="build/Release/Hummingbird.app"
DMG="build/Hummingbird-${VERSION}.dmg"

echo "== 1. Release 构建 =="
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Hummingbird.xcodeproj -scheme Hummingbird \
  -configuration Release -derivedDataPath .build -destination 'platform=macOS' clean build
rm -rf build/Release && mkdir -p build/Release
cp -R .build/Build/Products/Release/Hummingbird.app "$APP"

echo "== 2. 探测 Developer ID 证书 =="
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | \
    grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
  [ -n "$SIGN_IDENTITY" ] || { echo "错误：钥匙串无 Developer ID Application 证书"; exit 1; }
fi
echo "签名身份：$SIGN_IDENTITY"

echo "== 3. Developer ID 签名（hardened runtime + 时间戳）=="
codesign --force --deep --sign "$SIGN_IDENTITY" \
  --options runtime --timestamp \
  --entitlements ScreenRecorder/Hummingbird.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "== 4. 公证（notarytool）=="
if [ -n "${NOTARY_KEY_ID:-}" ]; then
  EXTRA="--key-id $NOTARY_KEY_ID --issuer $NOTARY_KEY_ISSUER --key $NOTARY_KEY_PATH"
elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
  EXTRA="--apple-id $NOTARY_APPLE_ID --password $NOTARY_APP_PASSWORD --team-id $TEAM_ID"
else
  echo "错误：缺少公证凭据（NOTARY_KEY_* 或 NOTARY_APPLE_ID/NOTARY_APP_PASSWORD）"; exit 1
fi
xcrun notarytool submit "$APP" $EXTRA --wait

echo "== 5. 装订公证票据 =="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "== 6. 打 DMG =="
rm -rf /tmp/Hummingbird-dmg build/"$DMG"
mkdir -p /tmp/Hummingbird-dmg
cp -R "$APP" /tmp/Hummingbird-dmg/
ln -s /Applications /tmp/Hummingbird-dmg/Applications
# DMG 一并公证（Gatekeeper 对装订过的 dmg 直接放行）
hdiutil create -volname "蜂鸟录屏 Hummingbird" -srcfolder /tmp/Hummingbird-dmg \
  -ov -format UDZO "$DMG"
if [ -n "${NOTARY_KEY_ID:-}" ]; then
  xcrun notarytool submit "$DMG" $EXTRA --wait
else
  xcrun notarytool submit "$DMG" $EXTRA --wait
fi
xcrun stapler staple "$DMG"

echo "== 完成 =="
echo "安装包：$DMG（已签名 + 已公证，Gatekeeper 直接放行）"
