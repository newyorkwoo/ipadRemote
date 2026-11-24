#!/bin/bash
# 內嵌 Tailscale 端對端測試：本機控制伺服器 + 兩個 tsnet 節點 + FakeMac。不需要 Tailscale 帳號。
# 需求：先執行 Tools/build-tailscale.sh；Go（可用 GO=/path/to/go 指定）。
set -euo pipefail
cd "$(dirname "$0")/../.."
GO="${GO:-$(command -v go || true)}"
[ -x "$GO" ] || { echo "找不到 Go"; exit 1; }
LIB="Vendor/CTailscale.xcframework/macos-arm64_x86_64"
[ -d "$LIB" ] || { echo "請先執行 Tools/build-tailscale.sh"; exit 1; }
WORK="$(mktemp -d)"; CODE="TESTA-BCDEF-GHJKM-NPQRS"; PORT=$((53000 + RANDOM % 2000))
cleanup() { [ -n "${FAKE:-}" ] && kill "$FAKE" 2>/dev/null; [ -n "${CTRL:-}" ] && kill "$CTRL" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

echo "▶︎ 編譯"
(cd Tools/TailnetE2E/control && "$GO" build -o "$WORK/control" .)
swiftc -O -o "$WORK/FakeMac" Tools/FakeMac/main.swift Shared/*.swift MacAgent/H264Encoder.swift
swiftc -O -o "$WORK/e2e" -I "$LIB/Headers" -L "$LIB" -ltailscale \
  Tools/TailnetE2E/main.swift Shared/*.swift Tailnet/TailnetNode.swift \
  MacAgent/TailnetGateway.swift iPadRemote/Networking/TailnetDialer.swift

mkfifo "$WORK/ctl.in"
"$WORK/control" < "$WORK/ctl.in" > "$WORK/ctl.out" 2> "$WORK/ctl.err" & CTRL=$!
exec 3> "$WORK/ctl.in"          # 保持 stdin 開著，控制伺服器才會持續執行
for _ in $(seq 50); do [ -s "$WORK/ctl.out" ] && break; sleep 0.2; done
URL="$(head -1 "$WORK/ctl.out")"; echo "控制伺服器：$URL"
"$WORK/FakeMac" --code "$CODE" --port "$PORT" --wake-port 0 > "$WORK/fakemac.log" 2>&1 & FAKE=$!
sleep 1
"$WORK/e2e" "$URL" "$PORT" "$CODE" 2> "$WORK/e2e.err" || { echo "--- FakeMac ---"; tail -20 "$WORK/fakemac.log"; exit 1; }
echo "--- FakeMac ---"; grep -v "^$" "$WORK/fakemac.log" | tail -8
