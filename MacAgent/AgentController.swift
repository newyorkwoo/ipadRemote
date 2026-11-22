import Foundation
import AppKit
import ServiceManagement
import Combine

final class AgentController: ObservableObject {
    @Published private(set) var pairingCode: String
    @Published private(set) var status = "啟動中…"
    @Published private(set) var statusOK = false
    @Published private(set) var connectedClient: String?
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

    let port: UInt16
    let hostID: String
    private let server = RemoteServer()
    private let power = PowerManager()
    private var observers: [NSObjectProtocol] = []

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
        launchAtLogin = SMAppService.mainApp.status == .enabled
        standbyMode = defaults.object(forKey: "standbyMode") as? Bool ?? true
        power.setStandby(standbyMode)

        server.onStatus = { [weak self] message, ok in
            self?.status = message
            self?.statusOK = ok
        }
        server.onClientChanged = { [weak self] name in self?.connectedClient = name }
        server.hostInfoProvider = { [weak self] in self?.makeHostInfo() ?? Self.emptyHostInfo }

        refresh()
        startServer()

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
        syncLaunchAtLogin()
    }

    private func startServer() {
        server.start(pairingCode: pairingCode, port: port,
                     serviceName: SystemInfo.computerName, hostID: hostID)
    }

    func regeneratePairingCode() {
        pairingCode = PairingCode.generate()
        Keychain.set(pairingCode, for: Self.codeAccount)
        server.disconnectClient()
        startServer()
    }

    func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
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
                        addresses: SystemInfo.reachableIPv4Addresses(),
                        displays: SystemInfo.displays(),
                        inputSources: InputSourceManager.list())
    }

    private static let emptyHostInfo = HostInfo(hostID: "", computerName: "Mac", model: "", isLaptop: false,
                                                displays: [], inputSources: [])
}
