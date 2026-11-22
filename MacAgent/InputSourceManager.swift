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

    static func selectNext() {
        let all = list()
        guard !all.isEmpty else { return }
        let current = all.firstIndex(where: \.isSelected) ?? -1
        select(id: all[(current + 1) % all.count].id)
    }
}
