#!/bin/bash
# 一鍵執行所有自動化模擬測試：
#   1. Mac 端單元測試（加密、協定、H.264、輸入注入、輸入法、MAC 位址）
#   2. iPad 端單元測試（自動重連、睡眠自動喚醒、心跳、配對碼、Wake-on-LAN、解碼）
#   3. 端對端 UI 測試（真正的 iPad App ↔ 模擬 Mac FakeMac），並匯出截圖
#
# 用法：Tools/run-simulation-tests.sh            （可用 SIM_ID=<UDID> 指定 iPad 模擬器）
set -uo pipefail
cd "$(dirname "$0")/.."

OUT="TestResults"
WORK="$(mktemp -d)"
CODE="TESTA-BCDEF-GHJKM-NPQRS"   # 僅供測試
PORT=52890
SIM_ID="${SIM_ID:-$(xcrun simctl list devices available | grep -m1 'iPad Pro' | grep -oE '[0-9A-F-]{36}')}"
DEST="platform=iOS Simulator,id=$SIM_ID"
rm -rf "$OUT"; mkdir -p "$OUT"
declare -a RESULTS

run_step() {   # run_step <名稱> <log 檔> <指令…>
  local name="$1" log="$2"; shift 2
  printf "▶︎ %-28s" "$name"
  if "$@" > "$OUT/$log" 2>&1; then
    local summary; summary=$(grep -E "Executed [0-9]+ tests?" "$OUT/$log" | tail -1 | sed -E 's/^[[:space:]]*//; s/ in .*//')
    echo "✅ ${summary:-完成}"; RESULTS+=("✅ $name — ${summary:-完成}")
  else
    echo "❌ 失敗（詳見 ${OUT}/${log}）"; RESULTS+=("❌ $name — 見 ${OUT}/${log}")
    grep -E "error:|failed" "$OUT/$log" | grep -v boringssl | head -10 | sed 's/^/     /'
  fi
}

echo "iPad 模擬器：$SIM_ID"
xcodegen generate > /dev/null || { echo "需要 xcodegen：brew install xcodegen"; exit 1; }

# 產生 H.264 測試素材與 FakeMac（都使用 Mac 端真正的 H264Encoder）
mkdir -p "$WORK/fx"; cp Tools/make-h264-fixtures.swift "$WORK/fx/main.swift"
swiftc -O -o "$WORK/fixtures" "$WORK/fx/main.swift" Shared/VideoPacket.swift MacAgent/H264Encoder.swift \
  && "$WORK/fixtures" Tests/iPadRemoteTests/Fixtures > /dev/null
swiftc -O -o "$WORK/FakeMac" Tools/FakeMac/main.swift Shared/*.swift MacAgent/H264Encoder.swift || exit 1

run_step "Mac 端單元測試" mac-tests.log \
  xcodebuild test -project iPadRemote.xcodeproj -scheme MacCoreTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

run_step "iPad 端單元測試" ipad-tests.log \
  xcodebuild test -project iPadRemote.xcodeproj -scheme iPadRemote -destination "$DEST" \
  -only-testing:iPadRemoteTests CODE_SIGN_IDENTITY=-

pkill -f "$WORK/FakeMac" 2>/dev/null; pkill -x FakeMac 2>/dev/null; sleep 0.5
"$WORK/FakeMac" --code "$CODE" --port "$PORT" > "$OUT/fakemac.log" 2>&1 &
FAKE_PID=$!
sleep 1
run_step "端對端 UI 測試（FakeMac）" ui-tests.log \
  env TEST_RUNNER_FAKE_MAC_CODE="$CODE" TEST_RUNNER_FAKE_MAC_PORT="$PORT" \
  xcodebuild test -project iPadRemote.xcodeproj -scheme iPadRemote -destination "$DEST" \
  -only-testing:iPadRemoteUITests CODE_SIGN_IDENTITY=- -resultBundlePath "$WORK/ui.xcresult"
kill "$FAKE_PID" 2>/dev/null

# 匯出 UI 測試截圖
if [ -d "$WORK/ui.xcresult" ]; then
  xcrun xcresulttool export attachments --path "$WORK/ui.xcresult" --output-path "$WORK/att" > /dev/null 2>&1
  mkdir -p "$OUT/screenshots"
  if [ -f "$WORK/att/manifest.json" ]; then
    /usr/bin/python3 - "$WORK/att" "$OUT/screenshots" <<'PY'
import json, shutil, sys, os
src, dst = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(src, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        label = name.split("_0_")[0] if "_0_" in name else os.path.splitext(name)[0]
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, label + ".png"))
PY
  fi
fi

echo
echo "══════════ 測試摘要 ══════════"
printf '%s\n' "${RESULTS[@]}"
echo "截圖：$OUT/screenshots/    FakeMac 紀錄：$OUT/fakemac.log"
rm -rf "$WORK"
[[ "${RESULTS[*]}" != *"❌"* ]]
