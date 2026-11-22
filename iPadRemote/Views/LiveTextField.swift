import SwiftUI
import UIKit

/// 文字輸入框，支援 iPad 上任何輸入法（注音、倉頡、拼音、日文…）
///
/// 即時模式：每確定一個字（選字完成）就立刻送到 Mac；刪除也會同步送出 ⌫
/// 整段模式：打完整段按「傳送」或 Return 再一次送出
struct LiveTextField: UIViewRepresentable {
    var placeholder: String
    var liveMode: Bool
    /// 數值改變時清空輸入框（例如按了工具列的 ⌫ / 快捷鍵後，避免與 Mac 端文字不同步）
    var resetToken: Int = 0
    @Binding var isFocused: Bool
    var onInsert: (String) -> Void
    var onDelete: (Int) -> Void
    var onReturn: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> BackspaceAwareTextField {
        let field = BackspaceAwareTextField()
        field.placeholder = placeholder
        field.accessibilityIdentifier = "remoteTextField"
        field.font = .preferredFont(forTextStyle: .body)
        field.borderStyle = .none
        field.returnKeyType = .send
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.onEmptyBackspace = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.parent.liveMode else { return }
            coordinator.parent.onDelete(1)
        }
        return field
    }

    func updateUIView(_ field: BackspaceAwareTextField, context: Context) {
        let wasLive = context.coordinator.parent.liveMode
        let oldToken = context.coordinator.parent.resetToken
        context.coordinator.parent = self
        if wasLive != liveMode || oldToken != resetToken {
            context.coordinator.committed = ""
            field.text = ""
        }
        if isFocused && !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused && field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LiveTextField
        var committed = ""
        /// 上一次檢查時輸入法是否在組字；用來辨識「選字確認」
        private var wasComposing = false
        /// 最近一次由組字確定成文字的時間（實體鍵盤按 Return 選字時，系統可能接著再送一次 Return）
        private var lastCompositionCommit: CFTimeInterval = 0

        init(_ parent: LiveTextField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            syncCommittedText(field)
            // 中文輸入法按空白鍵選字時，常是先替換候選字（此時仍標記為組字中），
            // 之後才結束組字，而結束組字不一定再觸發 editingChanged。下一輪再檢查一次。
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                self.syncCommittedText(field)
            }
        }

        /// 結束組字（unmarkText）時一定會觸發選取範圍變更
        func textFieldDidChangeSelection(_ field: UITextField) {
            syncCommittedText(field)
        }

        /// 把「已確定」的文字與上次送出的內容比對，只送出差異；重複呼叫不會重複送出
        private func syncCommittedText(_ field: UITextField) {
            guard parent.liveMode else { return }
            // 輸入法仍在組字（有底線的候選文字）時不送出；空的標記範圍視為已確定
            if let marked = field.markedTextRange, !marked.isEmpty {
                wasComposing = true
                return
            }
            if wasComposing {
                wasComposing = false
                lastCompositionCommit = CACurrentMediaTime()
            }
            let current = field.text ?? ""
            guard current != committed else { return }
            let old = Array(committed)
            let new = Array(current)
            var prefix = 0
            while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
            let deletions = old.count - prefix
            if deletions > 0 { parent.onDelete(deletions) }
            let inserted = String(new[prefix...])
            if !inserted.isEmpty { parent.onInsert(inserted) }
            committed = current
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            let composing = field.markedTextRange.map { !$0.isEmpty } ?? false
            let justCommitted = CACurrentMediaTime() - lastCompositionCommit < 0.25
            // 組字中按 Return（注音「選定」）是確認候選字，不是換行：先確定文字並送出，不清空也不送 ↩
            if composing {
                field.unmarkText()
                syncCommittedText(field)
                return false
            }
            // 輸入法剛用同一個 Return 確定了候選字：這次 Return 只算選字，不送 ↩、不清空輸入框
            if justCommitted {
                syncCommittedText(field)
                lastCompositionCommit = 0
                return false
            }
            if parent.liveMode {
                parent.onReturn("")
            } else if let text = field.text, !text.isEmpty {
                parent.onReturn(text)
            }
            committed = ""
            field.text = ""
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { DispatchQueue.main.async { self.parent.isFocused = true } }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { DispatchQueue.main.async { self.parent.isFocused = false } }
        }
    }
}

final class BackspaceAwareTextField: UITextField {
    var onEmptyBackspace: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        releaseAncestorPressHandling()
    }

    override func becomeFirstResponder() -> Bool {
        releaseAncestorPressHandling()
        return super.becomeFirstResponder()
    }

    /// 實體鍵盤的空白鍵 / Return 在 iPadOS 也會產生 `.select` 按壓事件。
    /// SwiftUI 掛在上層視圖的手勢辨識器若接受按壓，會在輸入法之前把空白鍵吃掉，
    /// 造成注音打不出一聲（ㄈㄚ + 空白鍵 → 沒反應）。上層手勢只需要觸控，不需要按壓。
    private func releaseAncestorPressHandling() {
        var view = superview
        while let current = view {
            current.gestureRecognizers?.forEach { recognizer in
                if !recognizer.allowedPressTypes.isEmpty { recognizer.allowedPressTypes = [] }
            }
            view = current.superview
        }
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty && markedTextRange == nil {
            onEmptyBackspace?()
        }
        super.deleteBackward()
    }
}
