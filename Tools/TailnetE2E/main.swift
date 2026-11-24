// TailnetE2E — 內嵌 Tailscale 的端對端測試（不需要 Tailscale 帳號）
//
// 本機跑一個測試用控制伺服器 + DERP/STUN（control/main.go），再在同一個行程中建立兩個 tsnet 節點：
//   「Mac」節點：TailnetGateway 在 tailnet 上監聽，轉給本機的 FakeMac（真正的 TLS-PSK 與 H.264 串流）
//   「iPad」節點：在 tailnet 上找到 Mac（依節點名稱），經 TailnetDialer 撥號，以 NWConnection + TLS-PSK 配對、收畫面
// 另外驗證：Mac 不在線 / 埠沒開時撥號回報失敗（不會被當成 TLS 錯誤）、配對碼錯誤時 TLS 交握失敗。
//
// 用法：TailnetE2E <control URL> <FakeMac port> <pairing code>

import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count == 4, let fakePort = UInt16(args[2]) else {
    print("用法：TailnetE2E <control URL> <FakeMac port> <pairing code>"); exit(2)
}
let controlURL = args[1], code = args[3]
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ✅ \(what)" : "  ❌ \(what)")
    if !ok { failures += 1 }
}

func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return cond()
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tailnet-e2e-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmp) }
let hostID = UUID().uuidString

print("▶︎ 啟動兩個 tsnet 節點")
let macNode = try TailnetNode(hostName: TailnetNaming.macHostName(computerName: "E2E 測試 Mac", hostID: hostID),
                              dataDir: tmp.appendingPathComponent("mac"), controlURL: controlURL)
let iPadNode = try TailnetNode(hostName: TailnetNaming.iPadHostName(deviceName: "E2E iPad"),
                               dataDir: tmp.appendingPathComponent("ipad"), controlURL: controlURL)
check(waitUntil(30) { macNode.status()?.backendState == "Running" }, "Mac 節點上線")
check(waitUntil(30) { iPadNode.status()?.backendState == "Running" }, "iPad 節點上線")
let macIP = macNode.status()?.selfIPv4
check(macIP.map(NetworkAddress.isTailscale) ?? false, "Mac 取得 tailnet 位址 \(macIP ?? "-")")

let gateway = TailnetGateway(port: fakePort)
try gateway.start(on: macNode)

print("▶︎ iPad 依節點名稱在 tailnet 上找到 Mac")
var found: TailnetPeer?
_ = waitUntil(30) {
    found = iPadNode.status()?.peers.first { peer in
        guard let parsed = TailnetNaming.parseMac(peer.hostName) else { return false }
        return TailnetNaming.matches(hostID: hostID, idTag: parsed.idTag) && peer.ipv4 != nil
    }
    return found != nil
}
check(found?.ipv4 == macIP, "找到 \(found?.hostName ?? "-") → \(found?.ipv4 ?? "-")")
check(TailnetNaming.parseMac(found?.hostName ?? "")?.displayName == "e2e mac", "顯示名稱解析")

func dial(_ host: String, _ port: UInt16) -> NWEndpoint?? {
    var result: NWEndpoint??
    TailnetDialer.endpoint(via: iPadNode, host: host, port: port) { result = .some($0) }
    _ = waitUntil(15) { result != nil }
    return result
}

/// 經 tailnet 做一次完整的加密連線：配對 → hello → 收畫面
var issuedKey: (id: String, key: Data)?

func session(code: String, device: (id: String, key: Data)? = nil) -> (tls: Bool, hello: HostInfo?, frames: Int, bytes: Int, error: NWError?) {
    guard let ip = macIP, let endpoint = dial(ip, fakePort) ?? nil else {
        print("  （撥號失敗）"); return (false, nil, 0, 0, nil)
    }
    let psk = device.map { PSKCredential.device(id: $0.id, key: $0.key) } ?? .pairing(code)
    let connection = NWConnection(to: endpoint, using: SecureTransport.parameters(credentials: [psk]))
    let channel = MessageChannel(connection: connection)
    var ready = false, hello: HostInfo?, frames = 0, bytes = 0, failure: NWError?
    channel.onControl = { data in
        switch try? JSONDecoder().decode(ServerMessage.self, from: data) {
        case .hello(let info)?: hello = info
        case let .paired(id, key)?: issuedKey = (id, key)
        default: break
        }
    }
    channel.onVideo = { data in
        frames += 1; bytes += data.count
        channel.send(ClientMessage.videoAck(count: 1))
    }
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            ready = true
            channel.startReceiving()
            if let device, let proof = SecureTransport.deviceProof(key: device.key, connection: connection) {
                channel.send(ClientMessage.identify(deviceID: device.id, proof: proof))
            }
            channel.send(ClientMessage.hello(clientName: "E2E iPad", protocolVersion: RemoteConstants.protocolVersion,
                                             quality: .balanced, displayID: nil))
        case .failed(let e), .waiting(let e):
            failure = e
        default: break
        }
    }
    connection.start(queue: .main)
    var ended = false
    channel.onReceiveError = { e in ended = true; if failure == nil { failure = e } }
    _ = waitUntil(15) { (hello != nil && frames >= 10) || failure != nil || ended }
    if hello == nil { print("  （ready=\(ready) error=\(failure.map { "\($0)" } ?? "-") ended=\(ended)）") }
    connection.cancel()
    return (ready, hello, frames, bytes, failure)
}

print("▶︎ 經 tailnet 配對並串流（FakeMac，TLS-PSK）")
let start = Date()
let ok = session(code: code)
check(ok.tls, "TLS-PSK 交握成功")
check(ok.hello?.computerName.isEmpty == false, "收到 Mac 的 hello（\(ok.hello?.computerName ?? "-")）")
check(ok.frames >= 10, "收到 H.264 畫面 \(ok.frames) 幀・\(ok.bytes / 1024) KB・\(String(format: "%.1f", Date().timeIntervalSince(start))) 秒")

print("▶︎ 以 Mac 發的專屬裝置金鑰重新連線（已配對 iPad 的日常路徑）")
check(issuedKey != nil, "配對後取得裝置金鑰")
RunLoop.main.run(until: Date().addingTimeInterval(1))      // 等 FakeMac 換上新金鑰重新監聽
let again = session(code: code, device: issuedKey)
check(again.hello != nil && again.frames >= 10, "裝置金鑰連線成功・\(again.frames) 幀")

print("▶︎ 錯誤情境")
let wrong = session(code: PairingCode.generate())
check(wrong.hello == nil, "配對碼錯誤 → 無法建立連線（\(wrong.error.map { "\($0)" } ?? "無錯誤")）")
let closed = dial(macIP ?? "", 1)
check(closed != nil && closed! == nil, "Mac 上沒有開的埠 → 撥號回報失敗，不交出本機埠")
let t0 = Date()
let nowhere = dial("100.100.100.99", fakePort)
check(nowhere != nil && nowhere! == nil, "不存在的節點 → 撥號失敗（\(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒）")

gateway.stop()
macNode.close()
iPadNode.close()
print(failures == 0 ? "✅ 全部通過" : "❌ \(failures) 項失敗")
exit(failures == 0 ? 0 : 1)
