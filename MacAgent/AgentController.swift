import Foundation
import AppKit
import ServiceManagement
import Combine
import UserNotifications

final class AgentController: ObservableObject {
    @Published private(set) var pairingCode: String
    @Published private(set) var status = "啟動中…"
    @Published private(set) var statusOK = false
    @Published private(set) var connectedClient: String?
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var hasScreenPermission = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var network: SystemInfo.NetworkInterface?
    @Published private(set) var addresses: [String] = []
    @Published private(set) var onACPower = true
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    /// 遠端待命：接電源時不讓系統睡眠，iPad 在不同網路也能隨時連入並點亮螢幕
    @Published var standbyMode: Bool {
        didSet {
            UserDefaults.standard.set(standbyMode, forKey: "standbyMode")
            power.setStandby(standbyMode)
        }
    }
    var tailscaleIP: String? { addresses.first(where: NetworkAddress.isTailscale) }

    /// 內嵌 Tailscale：不必另外安裝 Tailscale App，登入一次就能從任何網路連入
    let tailnet: TailnetController
    private let tailnetGateway: TailnetGateway
    /// 內嵌節點的 tailnet 位址（hostInfoProvider 在伺服器佇列上讀取）
    private let tailnetIP = Locked<String?>(nil)
    private var tailnetCancellable: AnyCancellable?

    let port: UInt16
    let hostID: String
    private let devices = PairedDeviceStore(keychainAccount: "mac-paired-devices")
    private lazy var server = RemoteServer(devices: devices)
    private let power = PowerManager()
    private var observers: [NSObjectProtocol] = []
    private var clipboardClearWork: DispatchWorkItem?

    private static let codeAccount = "mac-pairing-code"

    init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "hostID") {
            hostID = id
        } else {
            hostID = UUID().uuidString
            defaults.set(hostID, forKey: "hostID")
        }
        let storedPort = defaults.integer(forKey: "port")
        port = storedPort > 0 ? UInt16(storedPort) : RemoteConstants.defaultPort

        if let code = Keychain.get(Self.codeAccount), PairingCode.isValid(code) {
            pairingCode = code
        } else {
            let code = PairingCode.generate()
            Keychain.set(code, for: Self.codeAccount)
            pairingCode = code
        }
        let id = hostID
        tailnet = TailnetController(hostName: {
            TailnetNaming.macHostName(computerName: SystemInfo.computerName, hostID: id)
        })
        tailnetGateway = TailnetGateway(port: port)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        standbyMode = defaults.object(forKey: "standbyMode") as? Bool ?? true
        power.setStandby(standbyMode)

        server.onStatus = { [weak self] message, ok in
            self?.status = message
            self?.statusOK = ok
        }
        server.onClientChanged = { [weak self] name in
            guard let self else { return }
            let previous = self.connectedClient
            self.connectedClient = name
            if let name, name != previous { Self.notify("「\(name)」開始控制這台 Mac", body: "如果不是你，請從選單列的 iPad Remote 中斷連線並移除這台 iPad。") }
        }
        server.onPairingCodeChanged = { [weak self] code in
            guard let self else { return }
            self.pairingCode = code
            Keychain.set(code, for: Self.codeAccount)
        }
        server.onPaired = { [weak self] device in
            self?.pairedDevices = self?.devices.all ?? []
            Self.notify("已配對新的 iPad：\(device.name)", body: "配對碼已自動更換。如果不是你，請在選單列移除這台 iPad。")
        }
        pairedDevices = devices.all
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        server.hostInfoProvider = { [weak self] in self?.makeHostInfo() ?? Self.emptyHostInfo }

        refresh()
        startServer()
        startTailnet()

        // 睡眠喚醒、網路改變後重新監聽
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.server.restart()
            self?.refresh()
        })

        // 第一次執行時預設開啟「登入時啟動」，否則 Mac 重新開機後 iPad 會連不上
        if !defaults.bool(forKey: "didDefaultLaunchAtLogin") {
            defaults.set(true, forKey: "didDefaultLaunchAtLogin")
            if !launchAtLogin {
                launchAtLogin = true      // 在 init 裡不會觸發 didSet，所以手動套用
                applyLaunchAtLogin()
            }
        }
    }

    func refresh() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        network = SystemInfo.primaryInterface()
        addresses = SystemInfo.reachableIPv4Addresses()
        onACPower = power.isOnACPower
        pairedDevices = devices.all
        syncLaunchAtLogin()
    }

    private func startTailnet() {
        let gateway = tailnetGateway
        tailnet.onRunning = { [weak self] node in
            do {
                try gateway.start(on: node)
            } catch {
                NSLog("tailnet 監聽失敗：\(error)")
            }
            self?.objectWillChange.send()
        }
        tailnet.onStopped = { gateway.stop() }
        tailnetCancellable = tailnet.$selfIPv4.sink { [weak self] ip in
            self?.tailnetIP.withLock { $0 = ip }
        }
        tailnet.resume()
    }

    private func startServer() {
        server.start(pairingCode: pairingCode, port: port,
                     serviceName: SystemInfo.computerName, hostID: hostID)
    }

    /// 換新配對碼：舊碼立即失效；已配對的 iPad 使用自己的金鑰，不受影響
    func regeneratePairingCode() {
        pairingCode = PairingCode.generate()
        Keychain.set(pairingCode, for: Self.codeAccount)
        server.updatePairingCode(pairingCode)
    }

    /// 移除一台 iPad：它的金鑰刪除、連線中斷，之後必須用新的配對碼重新配對
    func removeDevice(_ device: PairedDevice) {
        server.removeDevice(id: device.id)
        pairedDevices.removeAll { $0.id == device.id }
    }

    /// 從 Mac 端立即中斷目前的遠端控制
    func disconnectClient() {
        server.disconnectClient()
    }

    /// 拷貝配對碼：只放在這台 Mac（不經通用剪貼板同步）、標記為機密，60 秒後自動清除
    func copyPairingCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(pairingCode, forType: .string)
        item.setData(Data(), forType: InputInjector.concealedType)
        pasteboard.writeObjects([item])
        let change = pasteboard.changeCount
        clipboardClearWork?.cancel()
        let work = DispatchWorkItem {
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
        clipboardClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private static func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func requestScreenPermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private var syncingLaunchAtLogin = false

    private func applyLaunchAtLogin() {
        guard !syncingLaunchAtLogin else { return }
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("登入啟動設定失敗：\(error)")
        }
        if launchAtLogin, service.status == .requiresApproval {
            // 使用者需要在「系統設定 › 一般 › 登入項目」允許
            SMAppService.openSystemSettingsLoginItems()
        }
        syncLaunchAtLogin()
    }

    /// 讓開關反映系統實際狀態（使用者可能在系統設定裡移除了登入項目）
    private func syncLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        let actual = status == .enabled || status == .requiresApproval
        guard actual != launchAtLogin else { return }
        syncingLaunchAtLogin = true
        launchAtLogin = actual
        syncingLaunchAtLogin = false
    }

    private func makeHostInfo() -> HostInfo {
        let net = SystemInfo.primaryInterface()
        return HostInfo(hostID: hostID,
                        computerName: SystemInfo.computerName,
                        model: SystemInfo.model,
                        isLaptop: SystemInfo.isLaptop,
                        macAddress: net?.mac,
                        otherMACAddresses: Array((net?.allMACs ?? []).dropFirst()),
                        ipv4: net?.ipv4,
                        broadcast: net?.broadcast,
                        addresses: reachableAddresses(),
                        displays: SystemInfo.displays(),
                        inputSources: InputSourceManager.list())
    }

    /// 區網、系統 Tailscale，再加上內嵌 Tailscale 節點的位址（iPad 換到任何網路時都會嘗試）
    private func reachableAddresses() -> [String] {
        var list = SystemInfo.reachableIPv4Addresses()
        if let ip = tailnetIP.withLock({ $0 }), !list.contains(ip) { list.append(ip) }
        return list
    }

    private static let emptyHostInfo = HostInfo(hostID: "", computerName: "Mac", model: "", isLaptop: false,
                                                displays: [], inputSources: [])
}
