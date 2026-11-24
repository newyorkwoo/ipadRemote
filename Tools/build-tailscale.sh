#!/bin/bash
# 編譯內嵌 Tailscale（libtailscale / tsnet，使用者模式 WireGuard）成 Vendor/CTailscale.xcframework。
# 兩個 App 直接連結這個靜態函式庫：使用者不用另外安裝 Tailscale App、也不用開 VPN。
#
# 需求：Go（https://go.dev/dl/）與 Xcode。只需在第一次建置、或更新 LIBTAILSCALE_REV 後執行一次。
# 用法：Tools/build-tailscale.sh            （可用 GO=/path/to/go 指定 Go）
set -euo pipefail
cd "$(dirname "$0")/.."

LIBTAILSCALE_REV="${LIBTAILSCALE_REV:-dacde75057ff350e146505829beff446e6823966}"
MACOS_MIN=14.0
IOS_MIN=17.0
VENDOR="$PWD/Vendor"
SRC="$VENDOR/.build/libtailscale"
WORK="$VENDOR/.build/out"
OUT="$VENDOR/CTailscale.xcframework"

GO="${GO:-$(command -v go || true)}"
[ -x "$GO" ] || { echo "找不到 Go。請先安裝：https://go.dev/dl/ （或用 GO=/path/to/go 指定）"; exit 1; }
echo "Go：$("$GO" version)"

mkdir -p "$VENDOR/.build"
if [ ! -d "$SRC/.git" ]; then
  git clone -q https://github.com/tailscale/libtailscale "$SRC"
fi
git -C "$SRC" fetch -q origin "$LIBTAILSCALE_REV" 2>/dev/null || true
git -C "$SRC" checkout -q "$LIBTAILSCALE_REV"
echo "libtailscale @ $(git -C "$SRC" rev-parse --short HEAD)"

rm -rf "$WORK"; mkdir -p "$WORK/wrap"

# 產生 cgo 用的 clang 包裝（指定 SDK、架構、最低系統版本）
make_cc() {   # make_cc <名稱> <sdk> <arch> <版本旗標>
  local f="$WORK/wrap/$1"
  cat > "$f" <<EOF
#!/bin/sh
exec "$(xcrun --sdk "$2" --find clang)" -arch $3 -isysroot "$(xcrun --sdk "$2" --show-sdk-path)" $4 "\$@"
EOF
  chmod +x "$f"; echo "$f"
}

build() {   # build <輸出檔> <GOOS> <GOARCH> <CC> [tags]
  local out="$1" goos="$2" goarch="$3" cc="$4" tags="${5:-}"
  echo "▶︎ 編譯 $(basename "$out")"
  (cd "$SRC" && CGO_ENABLED=1 GOOS="$goos" GOARCH="$goarch" CC="$cc" \
     "$GO" build -trimpath -ldflags "-s -w" ${tags:+-tags "$tags"} -buildmode=c-archive -o "$out" .)
}

build "$WORK/mac-arm64.a"  darwin arm64 "$(make_cc mac-arm64 macosx arm64 -mmacos-version-min=$MACOS_MIN)"
build "$WORK/mac-x86_64.a" darwin amd64 "$(make_cc mac-x86_64 macosx x86_64 -mmacos-version-min=$MACOS_MIN)"
build "$WORK/ios-arm64.a"  ios    arm64 "$(make_cc ios-arm64 iphoneos arm64 -mios-version-min=$IOS_MIN)" ios
build "$WORK/sim-arm64.a"  ios    arm64 "$(make_cc sim-arm64 iphonesimulator arm64 -mios-simulator-version-min=$IOS_MIN)" ios
build "$WORK/sim-x86_64.a" ios    amd64 "$(make_cc sim-x86_64 iphonesimulator x86_64 -mios-simulator-version-min=$IOS_MIN)" ios

mkdir -p "$WORK/mac" "$WORK/ios" "$WORK/sim"
lipo -create -output "$WORK/mac/libtailscale.a" "$WORK/mac-arm64.a" "$WORK/mac-x86_64.a"
cp "$WORK/ios-arm64.a" "$WORK/ios/libtailscale.a"
lipo -create -output "$WORK/sim/libtailscale.a" "$WORK/sim-arm64.a" "$WORK/sim-x86_64.a"

# Swift 以 `import CTailscale` 使用 C API
mkdir -p "$WORK/include"
cp "$SRC/tailscale.h" "$WORK/include/"
cat > "$WORK/include/module.modulemap" <<'EOF'
module CTailscale {
    header "tailscale.h"
    link "resolv"
    link framework "CoreFoundation"
    link framework "Security"
    export *
}
EOF

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/mac/libtailscale.a" -headers "$WORK/include" \
  -library "$WORK/ios/libtailscale.a" -headers "$WORK/include" \
  -library "$WORK/sim/libtailscale.a" -headers "$WORK/include" \
  -output "$OUT" > /dev/null
cp "$SRC/LICENSE" "$VENDOR/LICENSE-libtailscale"
echo "✅ 完成：$OUT"
