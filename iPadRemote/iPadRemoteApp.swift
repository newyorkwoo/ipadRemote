import SwiftUI

@main
struct iPadRemoteApp: App {
    @StateObject private var store = DeviceStore()
    @StateObject private var browser = BonjourBrowser()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DeviceListView()
                .appLockOverlay()            // 必須在 environmentObject 之內
                .environmentObject(store)
                .environmentObject(browser)
                .environmentObject(lock)
                .onAppear { browser.start() }
        }
        .onChange(of: scenePhase) { _, phase in lock.scenePhaseChanged(phase) }
    }
}
