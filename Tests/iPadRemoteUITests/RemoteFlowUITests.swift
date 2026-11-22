import XCTest

/// 端對端 UI 測試：需要先在 Mac 上執行 Tools/FakeMac（Tools/run-simulation-tests.sh 會自動處理）
///
/// 流程：加入 Mac → 連線 → 點擊 / 雙擊 / 右鍵 → 切換輸入法 → 輸入中英文 → 特殊鍵與快捷鍵
///      → Mac 睡眠 → App 自動送 Wake-on-LAN → Mac 醒來 → 自動重新連線 → 結束
final class RemoteFlowUITests: XCTestCase {
    private let pairingCode = ProcessInfo.processInfo.environment["FAKE_MAC_CODE"] ?? "TESTA-BCDEF-GHJKM-NPQRS"
    private let port = ProcessInfo.processInfo.environment["FAKE_MAC_PORT"] ?? "52890"
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // 模擬器有設定密碼時 App 鎖會啟動；UI 測試以 UserDefaults 參數關閉 App 鎖（App 鎖本身另有單元測試）
        app.launchArguments = ["-uiTestReset", "-appLockEnabled", "NO"]
        app.launch()
    }

    private func screenshot(_ name: String) {
        step += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 等待 FakeMac 回傳的提示（代表 Mac 端確實收到並執行了指令）
    @discardableResult
    private func expectNotice(_ text: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "Mac 端沒有回報：\(text)", file: file, line: line)
        return match
    }

    private func waitForConnection(_ connected: Bool, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let status = element("connectionStatus")
        let predicate = NSPredicate(format: "value == %@", connected ? "connected" : "notConnected")
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: timeout), .completed,
                       "連線狀態應為 \(connected ? "已連線" : "未連線")", file: file, line: line)
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
    }

    func testFullRemoteControlFlow() throws {
        // ── 1. 加入 Mac ──
        XCTAssertTrue(app.staticTexts["尚未加入 Mac"].waitForExistence(timeout: 5))
        screenshot("空的裝置列表")

        app.buttons["加入 Mac"].firstMatch.tap()
        let name = element("field.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("家裡的 MacBook")
        let codeField = element("field.code")
        codeField.tap(); codeField.typeText(pairingCode.lowercased().replacingOccurrences(of: "-", with: ""))
        XCTAssertEqual(codeField.value as? String, pairingCode, "配對碼應自動轉大寫並加上分隔線")
        let host = element("field.host")
        host.tap(); host.typeText("127.0.0.1")
        replaceText(in: element("field.port"), with: port)
        let wakeHost = element("field.wakeHost")
        wakeHost.tap(); wakeHost.typeText("127.0.0.1")
        screenshot("加入 Mac 表單")
        app.buttons["儲存"].tap()

        XCTAssertTrue(app.staticTexts["家裡的 MacBook"].waitForExistence(timeout: 5))
        screenshot("裝置列表")

        // ── 2. 連線（TLS 加密）──
        app.buttons["連線"].firstMatch.tap()
        waitForConnection(true, timeout: 15)
        sleep(2) // 等第一個關鍵幀畫面出來
        screenshot("已連線 遠端桌面")

        // ── 3. 滑鼠 ──
        let canvas = element("remoteCanvas")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.40)).tap()
        expectNotice("左鍵點擊 ×1")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.40)).doubleTap()
        expectNotice("左鍵點擊 ×2")
        canvas.twoFingerTap()
        expectNotice("右鍵點擊")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
            .press(forDuration: 0.6, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7)))
        expectNotice("拖曳完成")
        screenshot("滑鼠點擊與拖曳")

        // ── 4. 切換 Mac 輸入法 ──
        element("inputSourceMenu").tap()
        let zhuyin = app.buttons["注音"].firstMatch
        XCTAssertTrue(zhuyin.waitForExistence(timeout: 3), "輸入法選單應列出 Mac 的輸入法")
        screenshot("輸入法選單")
        zhuyin.tap()
        expectNotice("輸入法已切換：注音")

        // ── 5. 打字（含中文）──
        element("keyboardButton").tap()
        let field = element("remoteTextField")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Hello 你好，世界")
        expectNotice("已輸入：Hello 你好，世界")
        screenshot("即時輸入中文")

        app.buttons["⌫"].tap()
        expectNotice("按鍵：delete")
        // 按工具列鍵後 iPad 輸入框應清空，之後的輸入才會與 Mac 同步
        XCTAssertNotEqual(field.value as? String, "Hello 你好，世界", "輸入框應在按下工具列鍵後清空")
        app.buttons["esc"].tap()
        expectNotice("按鍵：esc")
        app.buttons["⌘"].tap()
        field.typeText("c")
        expectNotice("按鍵：⌘C")
        screenshot("特殊鍵與快捷鍵")

        // ── 6. Mac 睡眠 → 自動喚醒 → 自動重連 ──
        field.typeText("SLEEP")
        let card = element("connectionCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Mac 睡眠後應顯示重新連線狀態")
        screenshot("Mac 睡眠中 自動重連")
        expectNotice("已被喚醒並重新連線", timeout: 30)
        waitForConnection(true, timeout: 5)
        sleep(1)
        screenshot("自動喚醒並重新連線")

        // ── 7. 結束 ──
        element("closeButton").tap()
        XCTAssertTrue(app.staticTexts["家裡的 MacBook"].waitForExistence(timeout: 5))
        screenshot("回到裝置列表")
    }
}
