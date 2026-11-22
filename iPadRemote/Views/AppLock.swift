import SwiftUI
import LocalAuthentication

/// App 鎖：開啟 App、或離開超過 30 秒後回來時，要先通過 Face ID / Touch ID / 密碼才能看到 Mac 畫面或控制。
/// 避免別人拿到已解鎖的 iPad 就能直接操作你的 Mac。
final class AppLock: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled { isLocked = false }
        }
    }
    @Published private(set) var authenticating = false

    static let gracePeriod: TimeInterval = 30
    private static let enabledKey = "appLockEnabled"
    private var backgroundedAt: Date?

    init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey)
        self.enabled = enabled
        isLocked = enabled && Self.canAuthenticate
    }

    /// iPad 沒有設定密碼時無法驗證（也就沒有東西可以保護），此時不上鎖
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "密碼"
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
        case .active:
            if enabled, Self.canAuthenticate, let since = backgroundedAt,
               Date().timeIntervalSince(since) > Self.gracePeriod {
                isLocked = true
            }
            backgroundedAt = nil
            if isLocked { unlock() }
        default:
            break
        }
    }

    func unlock() {
        guard isLocked, !authenticating else { return }
        guard Self.canAuthenticate else {
            isLocked = false
            return
        }
        authenticating = true
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解鎖以檢視並控制你的 Mac") { ok, _ in
            DispatchQueue.main.async {
                self.authenticating = false
                if ok { self.isLocked = false }
            }
        }
    }
}

/// 上鎖時蓋住整個畫面
struct AppLockOverlay: ViewModifier {
    @EnvironmentObject private var lock: AppLock

    func body(content: Content) -> some View {
        ZStack {
            content
            if lock.isLocked {
                ZStack {
                    Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "lock.fill").font(.system(size: 44))
                        Text("遠端 Mac 已鎖定").font(.title2.weight(.semibold))
                        Button("使用 \(AppLock.biometryName) 解鎖") { lock.unlock() }
                            .buttonStyle(.borderedProminent)
                            .disabled(lock.authenticating)
                    }
                }
                .transition(.opacity)
                .onAppear { lock.unlock() }
            }
        }
    }
}

extension View {
    func appLockOverlay() -> some View { modifier(AppLockOverlay()) }
}
