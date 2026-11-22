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

    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressedButtons = Set<MouseButton>()
    private var heldModifiers: Modifiers = []

    private var displayBounds: CGRect { CGDisplayBounds(displayID) }

    private var currentLocation: CGPoint {
        cursorLocation()
    }

    // MARK: 滑鼠

    func moveAbsolute(x: Double, y: Double) {
        let b = displayBounds
        let point = CGPoint(x: b.minX + clamp(x) * (b.width - 1),
                            y: b.minY + clamp(y) * (b.height - 1))
        postMove(to: point)
    }

    func moveRelative(dx: Double, dy: Double) {
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
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        event.flags = cgFlags(modifiers.union(heldModifiers))
        post(event)
        if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
    }

    func click(_ button: MouseButton, clickCount: Int, modifiers: Modifiers) {
        self.button(button, down: true, clickCount: clickCount, modifiers: modifiers)
        self.button(button, down: false, clickCount: clickCount, modifiers: modifiers)
    }

    func scroll(dx: Double, dy: Double) {
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
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

    /// 透過剪貼簿 + ⌘V 貼上（適合長文字，或 Mac 端輸入法攔截 Unicode 事件時）
    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        keyPress(MacKey.v, modifiers: .command)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
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
