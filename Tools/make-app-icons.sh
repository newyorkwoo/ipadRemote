#!/bin/bash
# 重新產生兩個 App 的圖示並寫入各自的 Assets.xcassets
#   iPad：單一 1024 圖（Xcode 自動產生其他尺寸）
#   Mac ：16–1024 全部尺寸
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swift Tools/make-app-icons.swift "$TMP" > /dev/null

IPAD="iPadRemote/Assets.xcassets"
MAC="MacAgent/Assets.xcassets"
mkdir -p "$IPAD/AppIcon.appiconset" "$MAC/AppIcon.appiconset"
for dir in "$IPAD" "$MAC"; do
  echo '{ "info" : { "author" : "xcode", "version" : 1 } }' > "$dir/Contents.json"
done

cp "$TMP/ipad-1024.png" "$IPAD/AppIcon.appiconset/icon-1024.png"
cat > "$IPAD/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

images=""
for s in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((s * scale))
    name="icon-${s}@${scale}x.png"
    sips -z $px $px "$TMP/mac-1024.png" --out "$MAC/AppIcon.appiconset/$name" > /dev/null
    images+="    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${s}x${s}\" },"$'\n'
  done
done
cat > "$MAC/AppIcon.appiconset/Contents.json" <<JSON
{
  "images" : [
${images%,$'\n'}
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
rm -rf "$TMP"
echo "已更新 $IPAD 與 $MAC"
