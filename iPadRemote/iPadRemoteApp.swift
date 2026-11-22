import SwiftUI

@main
struct iPadRemoteApp: App {
    @StateObject private var store = DeviceStore()
    @StateObject private var browser = BonjourBrowser()

    var body: some Scene {
        WindowGroup {
            DeviceListView()
                .environmentObject(store)
                .environmentObject(browser)
                .onAppear { browser.start() }
        }
    }
}
