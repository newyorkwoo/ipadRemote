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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            pairingCard
            devicesCard
            permissionsCard
            networkCard
            standbyCard
            footer
        }
        .padding(16)
        .frame(width: 340)
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
            if let tailscale = agent.tailscaleIP {
                InfoRow(label: "Tailscale", value: tailscale)
            } else {
                HStack {
                    Text("Tailscale").foregroundStyle(.secondary)
                    Spacer()
                    Link("未安裝・從不同網路連線請安裝", destination: URL(string: "https://tailscale.com/download/mac")!)
                        .font(.caption)
                }
                .font(.callout)
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
