import Foundation
import CoreGraphics

/// 串流期間暫時把 Mac 螢幕切到較低的「看起來像」解析度，讓文字在 iPad 上變大。
///
/// - 用 `.forAppOnly` 設定：Agent 結束、當機或被強制關閉時，系統會自動還原成原本的解析度。
/// - 斷線後延遲幾秒才還原：短暫斷線重連時螢幕不會來回閃動。
/// - 同一時間只有一條控制連線，以 owner 區分，舊連線的還原不會蓋掉新連線的設定。
final class DisplayScaler {
    static let shared = DisplayScaler()

    struct Outcome {
        enum Kind { case applied, alreadyNative, restored, unavailable }
        let kind: Kind
        let width: Int
        let height: Int
    }

    /// 只拿選擇時需要的欄位，方便單元測試
    struct ModeInfo: Equatable {
        let width: Int          // 點
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double
        let usableForDesktop: Bool
        var isHiDPI: Bool { pixelWidth > width }
    }

    private let lock = NSLock()
    private var originals: [CGDirectDisplayID: CGDisplayMode] = [:]
    private var owners: [CGDirectDisplayID: ObjectIdentifier] = [:]
    private var pendingRestores: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private let restoreQueue = DispatchQueue(label: "ipadremote.displayscaler")

    /// 斷線後等這麼久才還原（期間重新連上就沿用）
    static let restoreDelay: TimeInterval = 8

    /// 依 scale 調整螢幕。`.native` 等於立即還原。
    func apply(_ scale: InterfaceScale, to display: CGDirectDisplayID, owner: AnyObject) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        pendingRestores.removeValue(forKey: display)?.cancel()

        guard let target = scale.targetWidth else {
            restoreLocked(display)
            let mode = CGDisplayCopyDisplayMode(display)
            return Outcome(kind: .restored, width: mode?.width ?? 0, height: mode?.height ?? 0)
        }
        guard let current = CGDisplayCopyDisplayMode(display) else {
            return Outcome(kind: .unavailable, width: 0, height: 0)
        }
        let original = originals[display] ?? current
        let modes = Self.allModes(display)
        guard let index = Self.chooseMode(original: Self.info(original), candidates: modes.map(Self.info),
                                          targetWidth: target) else {
            // 原本就已經夠大（例如 MacBook 內建螢幕），或找不到同比例的模式
            restoreLocked(display)
            let kind: Outcome.Kind = original.width <= target ? .alreadyNative : .unavailable
            return Outcome(kind: kind, width: original.width, height: original.height)
        }
        let chosen = modes[index]
        originals[display] = original
        owners[display] = ObjectIdentifier(owner)
        if !Self.same(chosen, current) {
            guard Self.configure(display, chosen) else {
                return Outcome(kind: .unavailable, width: current.width, height: current.height)
            }
        }
        return Outcome(kind: .applied, width: chosen.width, height: chosen.height)
    }

    /// 連線結束：延遲還原（若這段時間內新連線又套用，就取消還原）
    func release(_ display: CGDirectDisplayID, owner: AnyObject, after delay: TimeInterval = DisplayScaler.restoreDelay) {
        lock.lock(); defer { lock.unlock() }
        guard owners[display] == ObjectIdentifier(owner) else { return }
        owners[display] = nil
        pendingRestores[display]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.owners[display] == nil else { return }
            self.pendingRestores[display] = nil
            self.restoreLocked(display)
        }
        pendingRestores[display] = work
        restoreQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Agent 結束前呼叫：立即還原所有螢幕
    func restoreAll() {
        lock.lock(); defer { lock.unlock() }
        pendingRestores.values.forEach { $0.cancel() }
        pendingRestores = [:]
        for display in Array(originals.keys) { restoreLocked(display) }
    }

    private func restoreLocked(_ display: CGDirectDisplayID) {
        owners[display] = nil
        guard let original = originals.removeValue(forKey: display) else { return }
        if let current = CGDisplayCopyDisplayMode(display), Self.same(current, original) { return }
        _ = Self.configure(display, original)
    }

    // MARK: 選擇模式（純函式，可測試）

    /// 從候選中挑出與原本同比例、桌面可用、比原本小、寬度最接近目標的模式。
    /// 優先 HiDPI（文字較清楚）與相同更新率。原本就不比目標大時回傳 nil。
    static func chooseMode(original: ModeInfo, candidates: [ModeInfo], targetWidth: Int) -> Int? {
        guard original.width > targetWidth else { return nil }
        let ratio = Double(original.width) / Double(original.height)
        let usable = candidates.enumerated().filter { _, m in
            m.usableForDesktop && m.width < original.width && m.width >= 800 && m.height > 0
                && abs(Double(m.width) / Double(m.height) - ratio) < 0.02
        }
        return usable.min { a, b in
            score(a.element, original: original, target: targetWidth)
                < score(b.element, original: original, target: targetWidth)
        }?.offset
    }

    private static func score(_ m: ModeInfo, original: ModeInfo, target: Int) -> (Int, Int, Double, Int) {
        let refreshPenalty = original.refreshRate > 0 ? abs(m.refreshRate - original.refreshRate) : 0
        return (abs(m.width - target), m.isHiDPI ? 0 : 1, refreshPenalty, -m.pixelWidth)
    }

    // MARK: CoreGraphics

    private static func allModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    private static func info(_ mode: CGDisplayMode) -> ModeInfo {
        ModeInfo(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                 pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate,
                 usableForDesktop: mode.isUsableForDesktopGUI())
    }

    private static func same(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.ioDisplayModeID == b.ioDisplayModeID && a.width == b.width && a.pixelWidth == b.pixelWidth
    }

    private static func configure(_ display: CGDirectDisplayID, _ mode: CGDisplayMode) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}
