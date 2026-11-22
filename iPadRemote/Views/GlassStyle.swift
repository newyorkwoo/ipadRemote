import SwiftUI

extension View {
    /// iPadOS 26+ 使用 Liquid Glass；較舊系統使用毛玻璃材質
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }
}

/// 工具列上的圓形圖示按鈕
struct GlassIconButton: View {
    let systemImage: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 底部提示泡泡
struct Toast: View {
    let text: String
    var systemImage = "checkmark.circle.fill"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glass(in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
