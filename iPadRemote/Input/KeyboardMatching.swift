import UIKit

/// 依 Mac 目前的輸入法，挑出 iPad 上對應的軟體鍵盤（Mac 是注音 → iPad 也開注音鍵盤）
enum KeyboardMatching {
    /// Mac 輸入法 ID → (iPad 鍵盤語言前綴, 偏好的鍵盤名稱關鍵字)
    static func target(forMacSource id: String) -> (language: String, keyword: String?)? {
        let lower = id.lowercased()
        func has(_ s: String) -> Bool { lower.contains(s.lowercased()) }
        if has("TCIM") || has("TYIM") || has("Hant") {
            if has("Zhuyin") || has("Bopomofo") { return ("zh-Hant", "Zhuyin") }
            if has("Cangjie") { return ("zh-Hant", "Cangjie") }
            if has("Sucheng") { return ("zh-Hant", "Sucheng") }
            if has("Pinyin") { return ("zh-Hant", "Pinyin") }
            if has("Stroke") || has("Wubihua") { return ("zh-Hant", "Stroke") }
            return ("zh-Hant", nil)
        }
        if has("SCIM") || has("Hans") {
            if has("Wubi") { return ("zh-Hans", "Wubi") }
            if has("Stroke") { return ("zh-Hans", "Stroke") }
            return ("zh-Hans", "Pinyin")
        }
        if has("Kotoeri") || has("Japanese") {
            return ("ja", has("Kana") && !has("Romaji") ? "Kana" : "Romaji")
        }
        if has("Korean") { return ("ko", nil) }
        if has("Vietnamese") { return ("vi", nil) }
        if has("Thai") { return ("th", nil) }
        // 一般鍵盤配置（ABC、U.S.、British…）
        if has("keylayout") {
            if has("ABC") || has("US") || has("British") || has("Australian") || has("Canadian") { return ("en", nil) }
            if has("French") { return ("fr", nil) }
            if has("German") { return ("de", nil) }
            if has("Spanish") { return ("es", nil) }
            return ("en", nil)
        }
        return nil
    }

    /// 在 iPad 已加入的鍵盤（語言 + 內部識別字串）中挑出最符合的索引；沒有對應的鍵盤時回傳 nil
    static func bestIndex(forMacSource id: String, candidates: [(language: String, identifier: String)]) -> Int? {
        guard let target = target(forMacSource: id) else { return nil }
        let lang = target.language.lowercased()
        let matching = candidates.indices.filter {
            let l = candidates[$0].language.lowercased()
            return l == lang || l.hasPrefix(lang + "-") || l.hasPrefix(lang + "_")
        }
        if let keyword = target.keyword?.lowercased(),
           let exact = matching.first(where: { candidates[$0].identifier.lowercased().contains(keyword) }) {
            return exact
        }
        return matching.first
    }

    /// 反方向：使用者在 iPad 鍵盤上按地球鍵換了鍵盤 → 找出 Mac 上對應的輸入法。
    /// Mac 目前的輸入法已經對應這個鍵盤時回傳它（不必切換）；表情符號、聽寫等沒有對應時回傳 nil
    static func macSourceIndex(forIPadLanguage language: String, identifier: String,
                               sources: [InputSourceInfo]) -> Int? {
        let iPadLang = language.lowercased()
        let iPadID = identifier.lowercased()
        func languageMatches(_ i: Int) -> Bool {
            guard let t = target(forMacSource: sources[i].id) else { return false }
            let l = t.language.lowercased()
            return iPadLang == l || iPadLang.hasPrefix(l + "-") || iPadLang.hasPrefix(l + "_")
        }
        func keywordMatches(_ i: Int) -> Bool {
            guard let keyword = target(forMacSource: sources[i].id)?.keyword?.lowercased() else { return true }
            return iPadID.contains(keyword)
        }
        let sameLanguage = sources.indices.filter(languageMatches)
        guard !sameLanguage.isEmpty else { return nil }
        // 識別字串取得到時，注音對注音、倉頡對倉頡；取不到時只能比語言
        let exact = iPadID.isEmpty ? sameLanguage : sameLanguage.filter(keywordMatches)
        let pool = exact.isEmpty ? sameLanguage : exact
        return pool.first(where: { sources[$0].isSelected }) ?? pool.first
    }

    /// 鍵盤的（語言, 識別字串）
    static func describe(_ mode: UITextInputMode) -> (language: String, identifier: String) {
        (mode.primaryLanguage ?? "", identifier(of: mode))
    }

    /// iPad 上對應 Mac 輸入法的鍵盤
    static func inputMode(forMacSource id: String?) -> UITextInputMode? {
        guard let id else { return nil }
        let modes = UITextInputMode.activeInputModes
        let candidates = modes.map { ($0.primaryLanguage ?? "", identifier(of: $0)) }
        return bestIndex(forMacSource: id, candidates: candidates).map { modes[$0] }
    }

    /// 鍵盤的內部識別字串（例如 zh_Hant-Zhuyin@sw=Zhuyin）；用來區分同語言的注音 / 倉頡，取不到就只比對語言
    private static func identifier(of mode: UITextInputMode) -> String {
        let key = "identifier"
        guard mode.responds(to: NSSelectorFromString(key)) else { return "" }
        return mode.value(forKey: key) as? String ?? ""
    }
}
