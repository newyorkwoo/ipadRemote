import SwiftUI

struct EditorTarget: Identifiable {
    var device: SavedMac
    var pairingCode: String
    var isNew: Bool
    var id: UUID { device.id }
}

struct DeviceListView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var browser: BonjourBrowser
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var tailnet: TailnetController
    @State private var editing: EditorTarget?
    @State private var session: SavedMac?
    @State private var toast: String?
    @State private var deleting: SavedMac?

    private var newlyDiscovered: [DiscoveredMac] {
        browser.discovered.filter { found in
            !store.devices.contains { $0.hostID != nil && $0.hostID == found.hostID }
        }
    }

    /// tailnet 上找到、但還沒加入的 Mac（區網已經找到的不重複列出）
    private var tailnetDiscovered: [TailnetMac] {
        guard tailnet.isRunning else { return [] }
        return tailnet.peers.compactMap { peer -> TailnetMac? in
            guard let ip = peer.ipv4, let parsed = TailnetNaming.parseMac(peer.hostName) else { return nil }
            let known = store.devices.contains {
                TailnetNaming.matches(hostID: $0.hostID, idTag: parsed.idTag) || ($0.knownAddresses ?? []).contains(ip)
            }
            let onLAN = newlyDiscovered.contains { TailnetNaming.matches(hostID: $0.hostID, idTag: parsed.idTag) }
            guard !known, !onLAN else { return nil }
            return TailnetMac(name: parsed.displayName, ipv4: ip, online: peer.online)
        }
    }

    /// 這台 Mac 目前在 tailnet 上是否在線
    private func onlineViaTailnet(_ device: SavedMac) -> Bool {
        guard tailnet.isRunning else { return false }
        return tailnet.peers.contains { peer in
            guard peer.online else { return false }
            if let parsed = TailnetNaming.parseMac(peer.hostName),
               TailnetNaming.matches(hostID: device.hostID, idTag: parsed.idTag) { return true }
            return peer.ipv4.map { (device.knownAddresses ?? []).contains($0) } ?? false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.devices.isEmpty {
                        ContentUnavailableView {
                            Label("尚未加入 Mac", systemImage: "macbook.and.ipad")
                        } description: {
                            Text("在 Mac 上執行 iPad Remote Agent，從選單列取得配對碼，再點右上角的 ＋ 加入。")
                        }
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)],
                                  spacing: 20) {
                            ForEach(store.devices) { device in
                                DeviceCard(device: device,
                                           isOnline: browser.isOnline(device),
                                           isOnlineViaTailnet: onlineViaTailnet(device),
                                           onConnect: { session = device },
                                           onWake: { wake(device) },
                                           onEdit: {
                                               editing = EditorTarget(device: device,
                                                                      pairingCode: device.pairingCode,
                                                                      isNew: false)
                                           },
                                           onDelete: { deleting = device })
                            }
                        }
                    }

                    if !newlyDiscovered.isEmpty || !tailnetDiscovered.isEmpty {
                        discoveredSection
                    }

                    TailnetSection(tailnet: tailnet)
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("我的 Mac")
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Toggle("開啟 App 時需要 \(AppLock.biometryName)", isOn: $lock.enabled)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = EditorTarget(device: SavedMac(name: ""), pairingCode: "", isNew: true)
                    } label: {
                        Label("加入 Mac", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { target in
                DeviceEditorView(target: target)
            }
            .fullScreenCover(item: $session) { device in
                SessionContainer(device: device)
                    .appLockOverlay()
                    .environmentObject(lock)
            }
            .confirmationDialog("刪除「\(deleting?.name ?? "")」？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let deleting { store.delete(deleting) }
                }
            } message: {
                Text("配對碼也會從這台 iPad 移除。")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Toast(text: toast, systemImage: "bolt.fill").padding(.bottom, 30)
                }
            }
            .animation(.spring(duration: 0.35), value: toast)
        }
    }

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("附近的 Mac")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(newlyDiscovered) { found in
                    Button {
                        editing = EditorTarget(device: SavedMac(name: found.name, hostID: found.hostID),
                                               pairingCode: "", isNew: true)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(found.name).foregroundStyle(.primary)
                                Text("點一下以配對").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if found.id != newlyDiscovered.last?.id || !tailnetDiscovered.isEmpty {
                        Divider().padding(.leading, 62)
                    }
                }
                ForEach(tailnetDiscovered) { found in
                    Button {
                        var device = SavedMac(name: found.name)
                        device.knownAddresses = [found.ipv4]
                        editing = EditorTarget(device: device, pairingCode: "", isNew: true)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "globe")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(found.name).foregroundStyle(.primary)
                                Text(found.online ? "跨網路・點一下以配對" : "跨網路・目前離線")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if found.id != tailnetDiscovered.last?.id {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func wake(_ device: SavedMac) {
        guard !device.macAddress.isEmpty else {
            show("尚未取得 MAC 位址，請先在 Mac 醒著時連線一次")
            return
        }
        WakeOnLAN.wake(device) { count in
            show(count > 0 ? "已送出喚醒封包到「\(device.name)」" : "喚醒封包送出失敗")
        }
    }

    private func show(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast == message { toast = nil }
        }
    }
}

private struct TailnetMac: Identifiable, Hashable {
    var id: String { ipv4 }
    var name: String
    var ipv4: String
    var online: Bool
}

/// 內嵌 Tailscale：登入一次，之後 iPad 在任何網路都能連回 Mac（不用安裝 Tailscale App、不用 VPN）
private struct TailnetSection: View {
    @ObservedObject var tailnet: TailnetController
    @State private var confirmLogout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("跨網路連線")
                .font(.title3.weight(.semibold))
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tailnet.isRunning ? .green : .blue)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    actions.padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .confirmationDialog("登出跨網路連線？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("登出", role: .destructive) { tailnet.logout() }
        } message: {
            Text("登出後只能在同一個 Wi‑Fi 下連線，直到重新登入。")
        }
    }

    private var icon: String {
        switch tailnet.phase {
        case .running: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "globe"
        }
    }

    private var title: String {
        switch tailnet.phase {
        case .off: return "在外面也能連回家裡的 Mac"
        case .starting: return "連線中…"
        case .needsLogin: return "請完成登入"
        case .running: return "已啟用" + (tailnet.account.map { "・\($0)" } ?? "")
        case .failed(let message): return "無法啟用：\(message)"
        }
    }

    private var detail: String {
        switch tailnet.phase {
        case .off:
            return "在 Mac 選單列的「跨網路連線」與這裡登入同一個帳號（Google、Apple、Microsoft 或 GitHub），iPad 在其他 Wi‑Fi 或行動網路時也能直接連線，不必設定路由器。"
        case .starting:
            return "正在連上 Tailscale 網路。"
        case .needsLogin(let url):
            return url == nil ? "等待登入網址…若你的網路需要核准新裝置，請到 Tailscale 管理頁核准。"
                              : "請在 Safari 登入與 Mac 相同的帳號，完成後回到這個 App。"
        case .running:
            return "已登入同一帳號的 Mac 會自動出現在「附近的 Mac」。連線內容仍由配對金鑰端對端加密。"
        case .failed:
            return "請確認網路正常後再試一次。"
        }
    }

    @ViewBuilder private var actions: some View {
        switch tailnet.phase {
        case .off, .failed:
            Button("啟用並登入") { tailnet.enable() }
                .buttonStyle(.borderedProminent)
        case .starting:
            ProgressView()
        case .needsLogin(let url):
            HStack {
                Button("打開登入頁") { tailnet.openLogin() }
                    .buttonStyle(.borderedProminent)
                    .disabled(url == nil)
                Button("取消") { tailnet.disable() }
                    .buttonStyle(.bordered)
            }
        case .running:
            HStack {
                Button("暫停") { tailnet.disable() }
                    .buttonStyle(.bordered)
                Button("登出", role: .destructive) { confirmLogout = true }
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct DeviceCard: View {
    let device: SavedMac
    let isOnline: Bool
    let isOnlineViaTailnet: Bool
    let onConnect: () -> Void
    let onWake: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 1.0), .indigo],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: device.isLaptop ? "laptopcomputer" : "desktopcomputer")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 60, height: 60)

                Spacer()

                Menu {
                    Button("編輯", systemImage: "pencil", action: onEdit)
                    Button("刪除", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(isOnline || isOnlineViaTailnet ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                Button(action: onConnect) {
                    Label("連線", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onWake) {
                    Label("喚醒", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .disabled(device.macAddress.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contextMenu {
            Button("編輯", systemImage: "pencil", action: onEdit)
            Button("喚醒", systemImage: "power", action: onWake)
            Button("刪除", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var statusText: String {
        if isOnline { return "在線・區域網路" }
        if isOnlineViaTailnet { return "在線・跨網路連線" }
        if !device.host.isEmpty { return "將透過 \(device.host) 連線" }
        if device.tailscaleAddress != nil { return "不在同一個網路・將透過 Tailscale 連線" }
        if let last = device.lastConnected {
            return "未偵測到・上次連線 \(last.formatted(.relative(presentation: .named)))"
        }
        return "未偵測到（可能在休眠中）"
    }
}

/// 為每次連線建立獨立的 RemoteClient
private struct SessionContainer: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var browser: BonjourBrowser
    @EnvironmentObject private var tailnet: TailnetController
    let device: SavedMac

    var body: some View {
        SessionHost(device: device, browser: browser, tailnet: tailnet, store: store)
    }
}

private struct SessionHost: View {
    @StateObject private var client: RemoteClient

    init(device: SavedMac, browser: BonjourBrowser, tailnet: TailnetController, store: DeviceStore) {
        let client = RemoteClient(device: device, browser: browser, tailnet: tailnet)
        client.onHostInfo = { [weak store] info, quality in
            store?.update(device.id, with: info, quality: quality)
        }
        _client = StateObject(wrappedValue: client)
    }

    var body: some View {
        RemoteSessionView(client: client)
    }
}
