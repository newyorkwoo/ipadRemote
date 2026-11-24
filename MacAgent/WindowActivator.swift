import AppKit
import ApplicationServices

/// 遠端點擊後把被點到的視窗帶到最前面
///
/// 合成的滑鼠事件不一定會讓 macOS 切換前景 App、升起視窗（例如 VS Code 被 Chrome 蓋住時，
/// 點 VS Code 露出來的部分，VS Code 仍留在 Chrome 下面）。這裡用輔助使用 API 直接處理。
enum WindowActivator {
    /// `point` 為全域螢幕座標（左上角為原點，與 CGEvent 相同）
    static func bringWindowToFront(at point: CGPoint) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return }
        // 清單由前到後排列。Dock、Window Server、「截圖」App 等會放一層蓋住整個螢幕的透明視窗，要略過，
        // 否則每次都會以為點到的是那一層，被蓋住的視窗就不會被帶到前面
        let displays = activeDisplayBounds()
        let windows = list.compactMap(WindowInfo.init).filter {
            !systemOverlayOwners.contains($0.owner)
                && !isFullScreenOverlay(layer: $0.layer, bounds: $0.bounds, displays: displays)
        }
        guard let target = windows.first(where: { $0.bounds.contains(point) && $0.alpha > 0 }) else { return }
        // 點到選單、浮動面板等非一般視窗：交給系統處理
        guard target.layer == 0, target.pid != ProcessInfo.processInfo.processIdentifier else { return }

        let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let topNormalWindow = windows.first(where: { $0.layer == 0 })
        if frontApp == target.pid, topNormalWindow?.number == target.number { return }   // 已經在最前面

        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = axWindow(of: app, matching: target.bounds) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if frontApp != target.pid {
            NSRunningApplication(processIdentifier: target.pid)?.activate()
        }
    }

    private static let systemOverlayOwners: Set<String> = ["Dock", "Window Server"]

    /// 不是一般視窗（layer ≠ 0）又幾乎蓋滿整個螢幕：系統或工具放的透明覆蓋層，不是使用者要點的東西。
    /// 選單、彈出面板、提示框都不會這麼大，仍交給系統處理
    static func isFullScreenOverlay(layer: Int, bounds: CGRect, displays: [CGRect]) -> Bool {
        guard layer != 0 else { return false }
        return displays.contains { display in
            bounds.intersects(display)
                && bounds.width >= display.width * 0.9 && bounds.height >= display.height * 0.9
        }
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    private struct WindowInfo {
        let number: Int
        let pid: pid_t
        let owner: String
        let layer: Int
        let alpha: Double
        let bounds: CGRect

        init?(_ info: [String: Any]) {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            self.number = number
            self.pid = pid
            self.owner = info[kCGWindowOwnerName as String] as? String ?? ""
            self.layer = layer
            self.alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            self.bounds = bounds
        }
    }

    /// 在 App 的視窗中找出位置與大小相符的那一個
    private static func axWindow(of app: AXUIElement, matching frame: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let origin = pointValue(window, kAXPositionAttribute),
                  let size = sizeValue(window, kAXSizeAttribute) else { return false }
            return abs(origin.x - frame.minX) < 2 && abs(origin.y - frame.minY) < 2
                && abs(size.width - frame.width) < 2 && abs(size.height - frame.height) < 2
        }
    }

    private static func pointValue(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
