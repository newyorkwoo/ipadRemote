import UIKit

/// iPad 實體鍵盤（UIKeyboardHIDUsage）→ Mac 虛擬鍵碼
enum KeyMap {
    static func macKeyCode(for usage: UIKeyboardHIDUsage) -> UInt16? {
        table[usage.rawValue]
    }

    static func modifiers(from flags: UIKeyModifierFlags) -> Modifiers {
        var m: Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.alternate) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }

    private static let table: [Int: UInt16] = {
        var t: [Int: UInt16] = [:]
        // a–z (HID 4–29)
        let letters: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                 0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        for (i, code) in letters.enumerated() { t[4 + i] = code }
        // 1–9, 0 (HID 30–39)
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (i, code) in digits.enumerated() { t[30 + i] = code }
        // F1–F12 (HID 58–69)
        let fkeys: [UInt16] = [MacKey.f1, MacKey.f2, MacKey.f3, MacKey.f4, MacKey.f5, MacKey.f6,
                               MacKey.f7, MacKey.f8, MacKey.f9, MacKey.f10, MacKey.f11, MacKey.f12]
        for (i, code) in fkeys.enumerated() { t[58 + i] = code }

        let others: [Int: UInt16] = [
            40: MacKey.returnKey, 41: MacKey.escape, 42: MacKey.delete, 43: MacKey.tab, 44: MacKey.space,
            45: 0x1B /* - */, 46: 0x18 /* = */, 47: 0x21 /* [ */, 48: 0x1E /* ] */, 49: 0x2A /* \ */,
            51: 0x29 /* ; */, 52: 0x27 /* ' */, 53: 0x32 /* ` */, 54: 0x2B /* , */, 55: 0x2F /* . */,
            56: 0x2C /* / */, 57: MacKey.capsLock,
            74: MacKey.home, 75: MacKey.pageUp, 76: MacKey.forwardDelete, 77: MacKey.end, 78: MacKey.pageDown,
            79: MacKey.right, 80: MacKey.left, 81: MacKey.down, 82: MacKey.up,
            144: MacKey.kana /* LANG1 */, 145: MacKey.eisu /* LANG2 */,
            224: MacKey.control, 225: MacKey.shift, 226: MacKey.option, 227: MacKey.command,
            228: MacKey.rightControl, 229: MacKey.rightShift, 230: MacKey.rightOption, 231: MacKey.rightCommand,
        ]
        t.merge(others) { $1 }
        return t
    }()
}
