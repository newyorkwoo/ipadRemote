import SwiftUI

@main
struct MacAgentApp: App {
    @StateObject private var agent = AgentController()

    var body: some Scene {
        MenuBarExtra {
            AgentMenuView()
                .environmentObject(agent)
        } label: {
            Image(systemName: agent.connectedClient == nil ? "ipad.landscape" : "ipad.and.arrow.forward")
        }
        .menuBarExtraStyle(.window)
    }
}

struct AgentMenuView: View {
    @EnvironmentObject private var agent: AgentController
    @State private var copied = false
    @State private var confirmRegenerate = false
    @State private var showCode = false
    @State private var removing: PairedDevice?
    @State private var contentHeight: CGFloat = 600

    /// 選單面板最高只到螢幕可用高度（扣掉選單列與邊距），超過時捲動
    private var maxPanelHeight: CGFloat {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        return max(300, visible - 40)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                header
                pairingCard
                devicesCard
                permissionsCard
                TailnetCard(tailnet: agent.tailnet)
                networkCard
                standbyCard
                footer
            }
            .padding(16)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            })
        }
        .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
        .scrollIndicators(contentHeight > maxPanelHeight ? .visible : .hidden)
        .frame(width: 340, height: min(contentHeight, maxPanelHeight))
        .onAppear { agent.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "ipad.landscape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("iPad Remote").font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(agent.connectedClient != nil ? .green : (agent.statusOK ? .blue : .orange))
                        .frame(width: 7, height: 7)
                    Text(agent.connectedClient.map { "\($0) 正在控制" } ?? agent.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if agent.connectedClient != nil {
                Button("中斷連線", role: .destructive) { agent.disconnectClient() }
                    .controlSize(.small)
            }
        }
    }

    private var pairingCard: some View {
        Card(title: "配對碼", systemImage: "key.fill") {
            // 預設隱藏：避免在螢幕分享、遠端畫面或旁人視線中外洩
            Text(showCode ? agent.pairingCode : "•••••-•••••-•••••-•••••")
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            HStack {
                Button {
                    showCode.toggle()
                } label: {
                    Label(showCode ? "隱藏" : "顯示", systemImage: showCode ? "eye.slash" : "eye")
                }
                Button {
                    agent.copyPairingCode()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已拷貝" : "拷貝", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
                Button("重新產生…") { confirmRegenerate = true }
            }
            .controlSize(.small)
            Text("在 iPad 上輸入此配對碼。配對碼只能使用一次，配對成功後自動更換；拷貝後 60 秒自動從剪貼簿清除。連線全程加密並具前向保密。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("重新產生配對碼？", isPresented: $confirmRegenerate) {
            Button("重新產生", role: .destructive) { agent.regeneratePairingCode() }
        } message: {
            Text("目前的配對碼會立即失效。已配對的 iPad 不受影響。")
        }
    }

    private var devicesCard: some View {
        Card(title: "已配對的 iPad", systemImage: "ipad.landscape") {
            if agent.pairedDevices.isEmpty {
                Text("尚未配對任何 iPad。").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(agent.pairedDevices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).font(.callout)
                            Text("最後連線：" + (device.lastSeen ?? device.pairedAt)
                                    .formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移除", role: .destructive) { removing = device }
                            .controlSize(.small)
                    }
                }
            }
        }
        .confirmationDialog("移除「\(removing?.name ?? "")」？", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除", role: .destructive) {
                if let removing { agent.removeDevice(removing) }
                removing = nil
            }
        } message: {
            Text("這台 iPad 會立即中斷，之後必須用新的配對碼重新配對。其他 iPad 不受影響。")
        }
    }

    private var permissionsCard: some View {
        Card(title: "權限", systemImage: "lock.shield.fill") {
            PermissionRow(title: "螢幕錄製", granted: agent.hasScreenPermission,
                          action: agent.requestScreenPermission)
            PermissionRow(title: "輔助使用（控制滑鼠鍵盤）", granted: agent.hasAccessibilityPermission,
                          action: agent.requestAccessibilityPermission)
        }
    }

    private var networkCard: some View {
        Card(title: "網路與喚醒", systemImage: "network") {
            InfoRow(label: "區網 IP", value: agent.network?.ipv4 ?? "—")
            // 另外安裝的 Tailscale App（選用；內嵌的「跨網路連線」已足夠）
            if let tailscale = agent.tailscaleIP, tailscale != agent.tailnet.selfIPv4 {
                InfoRow(label: "Tailscale App", value: tailscale)
            }
            InfoRow(label: "MAC 位址", value: agent.network?.mac ?? "—")
            InfoRow(label: "連接埠", value: "\(agent.port) (TCP)")
        }
    }

    private var standbyCard: some View {
        Card(title: "遠端待命", systemImage: "moon.zzz.fill") {
            Toggle(isOn: $agent.standbyMode) {
                Text("接電源時保持可連線").font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(agent.standbyMode
                 ? (agent.onACPower
                    ? "螢幕可以關閉，但系統不會睡眠；iPad 從任何網路連入時會自動點亮螢幕。請保持上蓋打開或接外接螢幕。"
                    : "⚠️ 目前使用電池，macOS 會忽略此設定。請接上電源。")
                 : "關閉時 Mac 睡眠後，只有同一個區網的 iPad 能用 Wake‑on‑LAN 喚醒。")
                .font(.caption2)
                .foregroundStyle(agent.standbyMode && !agent.onACPower ? .orange : .secondary)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("登入時啟動", isOn: $agent.launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            Button("結束") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }
}

/// 內嵌 Tailscale：一鍵啟用、在瀏覽器登入一次，之後 iPad 從任何網路都能連入
private struct TailnetCard: View {
    @ObservedObject var tailnet: TailnetController
    @State private var confirmLogout = false

    var body: some View {
        Card(title: "跨網路連線", systemImage: "globe") {
            switch tailnet.phase {
            case .off:
                Text("啟用後，iPad 在外面（其他 Wi‑Fi、4G/5G）也能直接連回這台 Mac，不必設定路由器，也不用另外安裝 Tailscale。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button {
                    tailnet.enable()
                } label: {
                    Label("啟用並登入…", systemImage: "person.crop.circle.badge.checkmark")
                }
                .controlSize(.small)
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("連線中…").font(.callout).foregroundStyle(.secondary)
                }
            case .needsLogin(let url):
                Text(url == nil
                     ? "等待登入網址…（若你的 tailnet 需要核准新裝置，請到 Tailscale 管理頁核准）"
                     : "請在瀏覽器用 Google、Apple、Microsoft 或 GitHub 帳號登入。iPad 上請登入同一個帳號。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("打開登入頁") { tailnet.openLogin() }
                        .disabled(url == nil)
                    Spacer()
                    Button("取消") { tailnet.disable() }
                }
                .controlSize(.small)
            case .running:
                InfoRow(label: "狀態", value: "已啟用")
                if let ip = tailnet.selfIPv4 { InfoRow(label: "位址", value: ip) }
                if let account = tailnet.account { InfoRow(label: "帳號", value: account) }
                Text("在 iPad 的「遠端 Mac」App 登入同一個帳號，這台 Mac 就會出現在清單中。連線內容仍由配對金鑰端對端加密。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("暫停") { tailnet.disable() }
                    Spacer()
                    Button("登出…", role: .destructive) { confirmLogout = true }
                }
                .controlSize(.small)
            case .failed(let message):
                Text("無法啟用：\(message)").font(.caption).foregroundStyle(.orange)
                Button("重試") { tailnet.enable() }.controlSize(.small)
            }
        }
        .confirmationDialog("登出跨網路連線？", isPresented: $confirmLogout) {
            Button("登出", role: .destructive) { tailnet.logout() }
        } message: {
            Text("iPad 將無法再從其他網路連入，直到你重新登入。同一個區網內的連線不受影響。")
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title).font(.callout)
            Spacer()
            if !granted {
                Button("授權", action: action).controlSize(.small)
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
