import XCTest
@testable import iPadRemote

/// Mac 輸入法 → iPad 軟體鍵盤的對應
final class KeyboardMatchingTests: XCTestCase {
    /// iPad 常見的鍵盤組合（語言, 內部識別字串）
    private let iPadKeyboards: [(language: String, identifier: String)] = [
        ("en-US", "en_US@sw=QWERTY;hw=Automatic"),
        ("zh-Hant", "zh_Hant-HWR@sw=HWR"),
        ("zh-Hant", "zh_Hant-Zhuyin@sw=Zhuyin;hw=Automatic"),
        ("zh-Hant", "zh_Hant-Cangjie@sw=Cangjie;hw=Automatic"),
        ("ja-JP", "ja_JP-Romaji@sw=QWERTY-Japanese;hw=Automatic"),
        ("emoji", "emoji@sw=Emoji"),
    ]

    func testZhuyinPicksZhuyinNotHandwriting() {
        XCTAssertEqual(KeyboardMatching.bestIndex(forMacSource: "com.apple.inputmethod.TCIM.Zhuyin", candidates: iPadKeyboards), 2)
        XCTAssertEqual(KeyboardMatching.bestIndex(forMacSource: "com.apple.inputmethod.TCIM.Cangjie", candidates: iPadKeyboards), 3)
    }

    func testABCPicksEnglish() {
        XCTAssertEqual(KeyboardMatching.bestIndex(forMacSource: "com.apple.keylayout.ABC", candidates: iPadKeyboards), 0)
        XCTAssertEqual(KeyboardMatching.bestIndex(forMacSource: "com.apple.keylayout.US", candidates: iPadKeyboards), 0)
    }

    func testJapanese() {
        XCTAssertEqual(KeyboardMatching.bestIndex(forMacSource: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
                                                  candidates: iPadKeyboards), 4)
    }

    /// 識別字串取不到時，只比對語言也能找到繁中鍵盤
    func testFallsBackToLanguageOnly() {
        let noIDs = iPadKeyboards.map { ($0.language, "") }
        XCTAssertEqual(KeyboardMatching.bestIndex(forMacSource: "com.apple.inputmethod.TCIM.Zhuyin", candidates: noIDs), 1)
    }

    /// iPad 沒有加入對應的鍵盤或不認得的輸入法：不強制切換
    func testNoMatchLeavesKeyboardAlone() {
        XCTAssertNil(KeyboardMatching.bestIndex(forMacSource: "com.apple.inputmethod.SCIM.ITABC", candidates: iPadKeyboards))
        XCTAssertNil(KeyboardMatching.bestIndex(forMacSource: "com.example.unknown", candidates: iPadKeyboards))
    }

    // MARK: iPad 換鍵盤 → Mac 換輸入法

    private let macSources = [
        InputSourceInfo(id: "com.apple.keylayout.ABC", name: "ABC", isSelected: true),
        InputSourceInfo(id: "com.apple.inputmethod.TCIM.Cangjie", name: "倉頡", isSelected: false),
        InputSourceInfo(id: "com.apple.inputmethod.TCIM.Zhuyin", name: "注音", isSelected: false),
    ]

    func testIPadZhuyinSelectsMacZhuyin() {
        XCTAssertEqual(KeyboardMatching.macSourceIndex(forIPadLanguage: "zh-Hant",
                                                       identifier: "zh_Hant-Zhuyin@sw=Zhuyin;hw=Automatic",
                                                       sources: macSources), 2)
        XCTAssertEqual(KeyboardMatching.macSourceIndex(forIPadLanguage: "en-US", identifier: "en_US@sw=QWERTY",
                                                       sources: macSources), 0)
    }

    /// 只知道語言時：Mac 已經是同語言的輸入法就不換
    func testLanguageOnlyKeepsCurrentMacSource() {
        var sources = macSources
        sources[0].isSelected = false
        sources[1].isSelected = true
        XCTAssertEqual(KeyboardMatching.macSourceIndex(forIPadLanguage: "zh-Hant", identifier: "", sources: sources), 1)
    }

    func testEmojiOrMissingMacSourceDoesNothing() {
        XCTAssertNil(KeyboardMatching.macSourceIndex(forIPadLanguage: "emoji", identifier: "emoji@sw=Emoji", sources: macSources))
        XCTAssertNil(KeyboardMatching.macSourceIndex(forIPadLanguage: "ja-JP", identifier: "ja_JP-Romaji", sources: macSources))
    }
}
