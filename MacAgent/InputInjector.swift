import Foundation
import CoreGraphics
import AppKit

/// 用 CGEvent 模擬滑鼠與鍵盤（需要「輔助使用」權限）
final class InputInjector {
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    /// 實際送出事件的方式；測試時可替換成收集器，不會真的動到滑鼠鍵盤
    var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    /// 目前游標位置；測試時可替換
    var cursorLocation: () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero }
    /// 左鍵按下時把被點到的視窗帶到最前面；測試時可替換
    var activateWindow: (CGPoint) -> Void = { WindowActivator.bringWindowToFront(at: $0) }
    /// 貼上用的剪貼簿；測試時換成獨立剪貼簿，不會動到使用者的
    var pasteboard: NSPasteboard = .general
    /// 貼上後多久把剪貼簿還原
    var pasteRestoreDelay: TimeInterval = 0.6

    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressedButtons = Set<MouseButton>()
    private var heldModifiers: Modifiers = []

    private var displayBounds: CGRect { CGDisplayBounds(displayID) }

    /// 剛送出的游標位置。CGEvent 送出後，系統回報的游標位置要過一會兒才會更新（實測緊接著讀到的
    /// 幾乎都是上一次的座標），點擊若用系統位置，會點在上一次的地方：要點兩次才有反應、
    /// 點不到被蓋住的視窗。所以短時間內以自己送出的位置為準；之後改回系統位置（Mac 上可能有人動了實體滑鼠）。
    private var lastPosted: (point: CGPoint, time: TimeInterval)?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private let postedLocationValidity: TimeInterval = 1.0

    private var currentLocation: CGPoint {
        if let last = lastPosted, now() - last.time < postedLocationValidity { return last.point }
        return cursorLocation()
    }

    // MARK: 滑鼠

    func moveAbsolute(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        let b = displayBounds
        let point = CGPoint(x: b.minX + clamp(x) * (b.width - 1),
                            y: b.minY + clamp(y) * (b.height - 1))
        postMove(to: point)
    }

    func moveRelative(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        let b = displayBounds
        var p = currentLocation
        p.x = min(max(p.x + dx * b.width, b.minX), b.maxX - 1)
        p.y = min(max(p.y + dy * b.height, b.minY), b.maxY - 1)
        postMove(to: p)
    }

    private func postMove(to point: CGPoint) {
        let type: CGEventType
        let button: CGMouseButton
        if pressedButtons.contains(.left) { type = .leftMouseDragged; button = .left }
        else if pressedButtons.contains(.right) { type = .rightMouseDragged; button = .right }
        else if pressedButtons.contains(.middle) { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.flags = cgFlags(heldModifiers)
        event.map(post)
        lastPosted = (point, now())
    }

    func button(_ button: MouseButton, down: Bool, clickCount: Int, modifiers: Modifiers) {
        let location = currentLocation
        // 像真的滑鼠一樣：點到被蓋住的視窗時，要把它升到最前面
        if down && button == .left && !pressedButtons.contains(.left) {
            activateWindow(location)
        }
        let (type, cgButton) = eventType(for: button, down: down)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(min(max(1, clickCount), 3)))
        event.flags = cgFlags(modifiers.union(heldModifiers))
        post(event)
        lastPosted = (location, now())
        if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
    }

    func click(_ button: MouseButton, clickCount: Int, modifiers: Modifiers) {
        self.button(button, down: true, clickCount: clickCount, modifiers: modifiers)
        self.button(button, down: false, clickCount: clickCount, modifiers: modifiers)
    }

    func scroll(dx: Double, dy: Double) {
        // 遠端送來的數值先檢查並限制範圍：超出 Int32 會讓程式直接當掉
        guard dx.isFinite, dy.isFinite else { return }
        let limit = 10_000.0
        let wheel1 = Int32(min(max(dy, -limit), limit).rounded())
        let wheel2 = Int32(min(max(dx, -limit), limit).rounded())
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: wheel1, wheel2: wheel2, wheel3: 0)
        // 捲動送到剛移過去的位置（系統游標位置會落後，見 currentLocation）
        event?.location = currentLocation
        event.map(post)
    }

    private func eventType(for button: MouseButton, down: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case .left: return (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: return (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: return (down ? .otherMouseDown : .otherMouseUp, .center)
        }
    }

    // MARK: 鍵盤

    func key(_ keyCode: UInt16, down: Bool, modifiers: Modifiers) {
        if let modifier = MacKey.modifierKeys[keyCode] {
            if down { heldModifiers.insert(modifier) } else { heldModifiers.remove(modifier) }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
            event.type = .flagsChanged
            event.flags = cgFlags(heldModifiers)
            post(event)
            return
        }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = cgFlags(modifiers.union(heldModifiers))
        post(event)
    }

    func keyPress(_ keyCode: UInt16, modifiers: Modifiers) {
        key(keyCode, down: true, modifiers: modifiers)
        key(keyCode, down: false, modifiers: modifiers)
    }

    /// 直接輸入 Unicode 文字（不經過 Mac 的輸入法，所以 iPad 上打好的中文會原樣送出）
    func type(_ text: String) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 16, units.count)
            var chunk = Array(units[index..<end])
            // 避免把代理對 (surrogate pair) 切成兩半
            if end < units.count, UTF16.isLeadSurrogate(chunk.last!) {
                chunk.removeLast()
            }
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(event)
            }
            index += chunk.count
            usleep(2000)
        }
    }

    /// 剪貼簿管理工具（Maccy、Paste、Raycast…）的慣例：標記為機密、暫時的內容不記錄到歷史
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// 透過剪貼簿 + ⌘V 貼上（適合長文字，或 Mac 端輸入法攔截 Unicode 事件時）。
    /// 送出的文字可能是密碼，所以：
    /// • 只放在這台 Mac（不經「通用剪貼板」同步到其他裝置）
    /// • 標記為機密 / 暫時，剪貼簿工具不會記錄
    /// • 貼上後一定還原成原本的內容（原本是空的就清空），不留在剪貼簿上
    func paste(_ text: String) {
        let pasteboard = self.pasteboard
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { entry[type] = item.data(forType: type) }
            return entry
        }

        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.concealedType)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        keyPress(MacKey.v, modifiers: .command)

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteRestoreDelay) {
            // 期間如果使用者自己拷貝了別的東西，就不要覆蓋
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            let restored = saved.filter { !$0.isEmpty }.map { entry -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }

    /// 斷線時放開所有按住的鍵和滑鼠鍵，避免「卡鍵」
    func releaseAll() {
        for button in pressedButtons { self.button(button, down: false, clickCount: 1, modifiers: []) }
        for (code, modifier) in MacKey.modifierKeys where heldModifiers.contains(modifier) {
            key(code, down: false, modifiers: [])
        }
        pressedButtons.removeAll()
        heldModifiers = []
    }

    // MARK: 工具

    private func cgFlags(_ modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}
