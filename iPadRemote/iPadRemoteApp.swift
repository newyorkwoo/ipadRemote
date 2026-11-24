import SwiftUI

@main
struct iPadRemoteApp: App {
    @StateObject private var store = DeviceStore()
    @StateObject private var browser = BonjourBrowser()
    @StateObject private var lock = AppLock()
    /// 內嵌 Tailscale：登入一次後，iPad 在任何網路都能連回 Mac
    @StateObject private var tailnet = TailnetController(hostName: {
        TailnetNaming.iPadHostName(deviceName: UIDevice.current.name)
    })
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DeviceListView()
                .appLockOverlay()            // 必須在 environmentObject 之內
                .environmentObject(store)
                .environmentObject(browser)
                .environmentObject(lock)
                .environmentObject(tailnet)
                .onAppear {
                    browser.start()
                    tailnet.resume()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            lock.scenePhaseChanged(phase)
            if phase == .active { tailnet.refresh() }
        }
    }
}
