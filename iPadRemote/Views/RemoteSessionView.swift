import SwiftUI

struct RemoteSessionView: View {
    @ObservedObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var lock: AppLock

    @AppStorage("trackpadMode") private var trackpadMode = false
    @AppStorage("liveTyping") private var liveTyping = true
    @AppStorage("usePaste") private var usePaste = false
    @State private var stickyModifiers: Modifiers = []
    @State private var showKeyboard = false
    @State private var textFocused = false
    @State private var toolbarExpanded = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteScreen(client: client, trackpadMode: trackpadMode, stickyModifiers: $stickyModifiers,
                         textInputActive: showKeyboard && textFocused)
                .focusEffectDisabled()   // 遠端畫面拿到鍵盤焦點時不顯示藍框
                .ignoresSafeArea()
                .opacity(client.state == .connected ? 1 : 0.35)
                .blur(radius: client.state == .connected ? 0 : 8)
                .animation(.easeInOut(duration: 0.3), value: client.state == .connected)

            if client.state != .connected {
                ConnectionStatusCard(client: client, onClose: close)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            VStack(spacing: 10) {
                toolbar
                if let notice = client.notice {
                    noticeBanner(notice)
                }
                Spacer()
                if showKeyboard && client.state == .connected {
                    KeyboardPanel(client: client,
                                  liveTyping: $liveTyping,
                                  usePaste: $usePaste,
                                  stickyModifiers: $stickyModifiers,
                                  textFocused: $textFocused,
                                  onHide: { withAnimation(.spring) { showKeyboard = false; textFocused = false } })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .animation(.spring(duration: 0.35), value: client.state)
        .animation(.spring(duration: 0.35), value: client.notice)
        .onAppear {
            client.inputBlocked = lock.isLocked
            client.connect()
        }
        // App 上鎖時不送出任何滑鼠、鍵盤、文字（硬體鍵盤的按鍵仍會送到遠端畫面元件，這裡一律擋下）
        .onChange(of: lock.isLocked) { _, locked in client.inputBlocked = locked }
        .onDisappear { client.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.appDidBecomeActive() }
        }
        .onChange(of: client.notice) { _, notice in
            guard let notice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if client.notice == notice { client.notice = nil }
            }
        }
    }

    private func close() {
        client.disconnect()
        dismiss()
    }

    // MARK: 工具列

    @ViewBuilder
    private var toolbar: some View {
        if toolbarExpanded {
            HStack(spacing: 2) {
                GlassIconButton(systemImage: "xmark", action: close)
                    .accessibilityIdentifier("closeButton")
                statusPill
                Divider().frame(height: 22).padding(.horizontal, 4)

                GlassIconButton(systemImage: trackpadMode ? "rectangle.and.hand.point.up.left" : "hand.point.up.left",
                                isActive: trackpadMode) {
                    trackpadMode.toggle()
                    client.notice = trackpadMode ? "觸控板模式：手指相對移動游標" : "直接觸控：游標跟著手指"
                }
                GlassIconButton(systemImage: "keyboard", isActive: showKeyboard) {
                    withAnimation(.spring) {
                        showKeyboard.toggle()
                        textFocused = showKeyboard
                    }
                }
                .accessibilityIdentifier("keyboardButton")
                inputSourceMenu
                shortcutsMenu
                displayMenu
                GlassIconButton(systemImage: "sun.max") { client.send(.wakeDisplay) }
                GlassIconButton(systemImage: client.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                isActive: client.audioEnabled) {
                    client.audioEnabled.toggle()
                    client.notice = client.audioEnabled ? "已開啟 Mac 聲音" : "已關閉 Mac 聲音"
                }
                .accessibilityIdentifier("audioButton")
                .accessibilityValue(client.audioEnabled ? "on" : "off")

                Divider().frame(height: 22).padding(.horizontal, 4)
                GlassIconButton(systemImage: "chevron.up") {
                    withAnimation(.spring) { toolbarExpanded = false }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .glass(in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            Button {
                withAnimation(.spring) { toolbarExpanded = true }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var statusColor: Color {
        switch client.state {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(client.hostInfo?.computerName ?? client.device.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let ms = client.latencyMs, client.state == .connected {
                Text("\(ms) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionStatus")
        .accessibilityValue(client.state == .connected ? "connected" : "notConnected")
    }

    private var inputSourceMenu: some View {
        Menu {
            Section("Mac 輸入法") {
                ForEach(client.inputSources) { source in
                    Button {
                        client.send(.selectInputSource(id: source.id))
                    } label: {
                        if source.isSelected {
                            Label(source.name, systemImage: "checkmark")
                        } else {
                            Text(source.name)
                        }
                    }
                }
            }
            Button("切換到下一個輸入法", systemImage: "arrow.triangle.2.circlepath") {
                client.send(.nextInputSource)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                if let current = client.inputSources.first(where: \.isSelected) {
                    Text(current.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 80)
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .frame(minWidth: 40, minHeight: 40)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityIdentifier("inputSourceMenu")
    }

    private var shortcutsMenu: some View {
        Menu {
            Section("系統") {
                shortcut("Spotlight", "magnifyingglass", MacKey.space, .command)
                shortcut("Mission Control", "rectangle.3.group", MacKey.up, .control)
                shortcut("切換 App", "square.on.square", MacKey.tab, .command)
                shortcut("強制結束…", "xmark.octagon", MacKey.escape, [.command, .option])
                shortcut("截圖（選取範圍）", "camera.viewfinder", 0x15 /* 4 */, [.command, .shift])
                shortcut("鎖定螢幕", "lock", MacKey.q, [.command, .control])
            }
            Section("編輯") {
                shortcut("拷貝", "doc.on.doc", MacKey.c, .command)
                shortcut("貼上", "doc.on.clipboard", MacKey.v, .command)
                shortcut("全選", "selection.pin.in.out", MacKey.a, .command)
                shortcut("還原", "arrow.uturn.backward", MacKey.z, .command)
                shortcut("關閉視窗", "xmark.square", MacKey.w, .command)
                shortcut("結束 App", "power", MacKey.q, .command)
            }
            Section("功能鍵") {
                ForEach(Array(zip(1...12, [MacKey.f1, MacKey.f2, MacKey.f3, MacKey.f4, MacKey.f5, MacKey.f6,
                                           MacKey.f7, MacKey.f8, MacKey.f9, MacKey.f10, MacKey.f11, MacKey.f12])),
                        id: \.0) { index, code in
                    Button("F\(index)") { client.send(.keyPress(keyCode: code, modifiers: [])) }
                }
            }
        } label: {
            Image(systemName: "command")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortcut(_ title: String, _ icon: String, _ key: UInt16, _ modifiers: Modifiers) -> some View {
        Button(title, systemImage: icon) {
            client.send(.keyPress(keyCode: key, modifiers: modifiers))
        }
    }

    private var displayMenu: some View {
        Menu {
            if let displays = client.hostInfo?.displays, displays.count > 1 {
                Section("螢幕") {
                    ForEach(displays) { display in
                        Button {
                            client.send(.selectDisplay(id: display.id))
                        } label: {
                            if display.id == client.currentDisplayID {
                                Label(display.name, systemImage: "checkmark")
                            } else {
                                Text(display.name)
                            }
                        }
                    }
                }
            }
            Picker("畫質", selection: $client.quality) {
                ForEach(StreamQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Section {
                Button("喚醒 Mac（Wake‑on‑LAN）", systemImage: "power") { client.wakeMac() }
            }
        } label: {
            Image(systemName: "display")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func noticeBanner(_ text: String) -> some View {
        Label(text, systemImage: "info.circle.fill")
            .accessibilityIdentifier("noticeBanner")
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glass(in: Capsule())
            .onTapGesture { client.notice = nil }
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 連線狀態卡

private struct ConnectionStatusCard: View {
    @ObservedObject var client: RemoteClient
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            icon
                .font(.system(size: 44, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(height: 56)

            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if case .failed = client.state {
            } else {
                ProgressView().controlSize(.large)
            }

            HStack(spacing: 12) {
                Button("結束", role: .cancel, action: onClose)
                    .buttonStyle(.bordered)
                if !client.device.macAddress.isEmpty {
                    Button {
                        client.wakeMac()
                    } label: {
                        Label("喚醒 Mac", systemImage: "power")
                    }
                    .buttonStyle(.bordered)
                }
                if case .failed = client.state {
                    Button("重試") { client.retryNow() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)

            if let sent = client.lastWakeSent {
                Text("已於 \(sent.formatted(date: .omitted, time: .standard)) 送出喚醒封包")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("connectionCard")
        .glass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    @ViewBuilder
    private var icon: some View {
        switch client.state {
        case .failed:
            Image(systemName: "exclamationmark.lock.fill").foregroundStyle(.red)
        case .reconnecting:
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
        default:
            Image(systemName: client.device.isLaptop ? "laptopcomputer" : "desktopcomputer")
                .foregroundStyle(.blue)
        }
    }

    private var title: String {
        switch client.state {
        case .idle, .connecting: return "正在連線到「\(client.device.name)」"
        case .connected: return ""
        case .reconnecting(let attempt, _): return attempt > 3 ? "正在嘗試喚醒並重新連線…" : "正在重新連線…"
        case .failed: return "無法連線"
        }
    }

    private var subtitle: String {
        switch client.state {
        case .idle, .connecting: return "建立加密連線中"
        case .connected: return ""
        case .reconnecting(let attempt, let reason): return "\(reason)\n第 \(attempt) 次嘗試・網路恢復後會自動連上"
        case .failed(let message): return message
        }
    }
}

// MARK: - 鍵盤面板

private struct KeyboardPanel: View {
    @ObservedObject var client: RemoteClient
    @Binding var liveTyping: Bool
    @Binding var usePaste: Bool
    @Binding var stickyModifiers: Modifiers
    @Binding var textFocused: Bool
    let onHide: () -> Void
    @State private var fieldResetToken = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Picker("模式", selection: $liveTyping) {
                    Text("即時").tag(true)
                    Text("整段").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                LiveTextField(placeholder: liveTyping ? "直接輸入，會即時傳到 Mac…" : "輸入整段文字後按傳送…",
                              liveMode: liveTyping,
                              resetToken: fieldResetToken,
                              isFocused: $textFocused,
                              onInsert: { text in sendText(text) },
                              onDelete: { count in
                                  for _ in 0..<count { client.send(.keyPress(keyCode: MacKey.delete, modifiers: [])) }
                              },
                              onReturn: { text in
                                  if text.isEmpty {
                                      client.send(.keyPress(keyCode: MacKey.returnKey, modifiers: []))
                                  } else {
                                      sendText(text)
                                  }
                              })
                    .frame(height: 22)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.tertiarySystemFill), in: Capsule())

                Toggle(isOn: $usePaste) {
                    Image(systemName: "doc.on.clipboard")
                }
                .toggleStyle(.button)
                .help("用剪貼簿貼上（Mac 輸入法攔截文字時使用）")

                Button(action: onHide) {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                key("esc", MacKey.escape)
                key("⇥", MacKey.tab)
                modifier("⌘", .command)
                modifier("⌥", .option)
                modifier("⌃", .control)
                modifier("⇧", .shift)
                Spacer(minLength: 8)
                key("←", MacKey.left)
                key("↑", MacKey.up)
                key("↓", MacKey.down)
                key("→", MacKey.right)
                Spacer(minLength: 8)
                key("⌫", MacKey.delete)
                key("↩", MacKey.returnKey)
            }
        }
        .padding(14)
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .frame(maxWidth: 900)
    }

    private func sendText(_ text: String) {
        if !stickyModifiers.isEmpty, text.count == 1, let scalar = text.lowercased().unicodeScalars.first,
           let code = Self.letterKeyCodes[Character(scalar)] {
            // 例如按住 ⌘ 再打 c → ⌘C
            client.send(.keyPress(keyCode: code, modifiers: stickyModifiers))
            stickyModifiers = []
            fieldResetToken += 1
            return
        }
        client.send(.text(text, usePaste: usePaste || text.count > 300))
    }

    private func key(_ label: String, _ code: UInt16) -> some View {
        Button {
            client.send(.keyPress(keyCode: code, modifiers: stickyModifiers))
            stickyModifiers = []
            fieldResetToken += 1
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .frame(minWidth: 34, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
    }

    private func modifier(_ label: String, _ value: Modifiers) -> some View {
        let active = stickyModifiers.contains(value)
        return Button {
            if active { stickyModifiers.remove(value) } else { stickyModifiers.insert(value) }
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(minWidth: 34, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
        .tint(active ? .accentColor : nil)
        .background(active ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static let letterKeyCodes: [Character: UInt16] = {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let codes: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                               0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        return Dictionary(uniqueKeysWithValues: zip(letters, codes))
    }()
}
