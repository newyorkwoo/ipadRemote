import Foundation
import Carbon

/// 讀取 / 切換 Mac 的輸入法（Text Input Sources）
enum InputSourceManager {
    static let changedNotification = Notification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String)

    private static func sources() -> [TISInputSource] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
            kTISPropertyInputSourceIsEnabled: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
                as? [TISInputSource] else { return [] }
        return list
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    static func list() -> [InputSourceInfo] {
        sources().compactMap { source in
            guard let id: String = property(source, kTISPropertyInputSourceID) else { return nil }
            let name: String = property(source, kTISPropertyLocalizedName) ?? id
            let selected: Bool = property(source, kTISPropertyInputSourceIsSelected) ?? false
            return InputSourceInfo(id: id, name: name, isSelected: selected)
        }
    }

    @discardableResult
    static func select(id: String) -> Bool {
        guard let source = sources().first(where: { property($0, kTISPropertyInputSourceID) == id }) else {
            return false
        }
        return TISSelectInputSource(source) == noErr
    }

    static let zhuyinID = "com.apple.inputmethod.TCIM.Zhuyin"
    static let abcID = "com.apple.keylayout.ABC"

    /// 注音 ↔ ABC 英文鍵盤。不用 selectNext，因為它會輪到其他輸入法；
    /// 注音自己的英文模式可能是全形，所以英文直接選純 ABC 鍵盤。
    /// 若找不到這兩個輸入法（例如 Mac 上沒有啟用），退回 selectNext。
    static func toggleChineseEnglish() {
        let all = list()
        guard all.contains(where: { $0.id == zhuyinID }), all.contains(where: { $0.id == abcID }) else {
            selectNext()
            return
        }
        let current = all.first(where: \.isSelected)?.id
        select(id: current == abcID ? zhuyinID : abcID)
    }

    static func selectNext() {
        let all = list()
        guard !all.isEmpty else { return }
        let current = all.firstIndex(where: \.isSelected) ?? -1
        select(id: all[(current + 1) % all.count].id)
    }
}
