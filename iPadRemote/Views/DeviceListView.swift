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
    @State private var editing: EditorTarget?
    @State private var session: SavedMac?
    @State private var toast: String?
    @State private var deleting: SavedMac?

    private var newlyDiscovered: [DiscoveredMac] {
        browser.discovered.filter { found in
            !store.devices.contains { $0.hostID != nil && $0.hostID == found.hostID }
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

                    if !newlyDiscovered.isEmpty {
                        discoveredSection
                    }
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("我的 Mac")
            .toolbar {
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
                    if found.id != newlyDiscovered.last?.id {
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

private struct DeviceCard: View {
    let device: SavedMac
    let isOnline: Bool
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
                        .fill(isOnline ? Color.green : Color.secondary.opacity(0.5))
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
    let device: SavedMac

    var body: some View {
        SessionHost(device: device, browser: browser, store: store)
    }
}

private struct SessionHost: View {
    @StateObject private var client: RemoteClient

    init(device: SavedMac, browser: BonjourBrowser, store: DeviceStore) {
        let client = RemoteClient(device: device, browser: browser)
        client.onHostInfo = { [weak store] info, quality in
            store?.update(device.id, with: info, quality: quality)
        }
        _client = StateObject(wrappedValue: client)
    }

    var body: some View {
        RemoteSessionView(client: client)
    }
}
