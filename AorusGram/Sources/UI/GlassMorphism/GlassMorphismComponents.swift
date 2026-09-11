import SwiftUI
import UIKit

private final class AorusGlassEffectsPreference: ObservableObject {
    static let shared = AorusGlassEffectsPreference()

    @Published private(set) var isEnabled: Bool
    private var observer: NSObjectProtocol?

    private init() {
        self.isEnabled = Self.currentValue()
        self.observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            let value = Self.currentValue()
            if self?.isEnabled != value {
                self?.isEnabled = value
            }
        }
    }

    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static func currentValue() -> Bool {
        return AorusLicenseAccess.isAllowed
            && (UserDefaults.standard.object(forKey: "aorusgram_feature_glass_ui") as? Bool ?? true)
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    var intensity: Double = 0.15
    var cornerRadius: CGFloat = 20
    var borderOpacity: Double = 0.25
    @ViewBuilder let content: () -> Content
    @ObservedObject private var glassEffects = AorusGlassEffectsPreference.shared

    var body: some View {
        content()
            .background(
                ZStack {
                    if glassEffects.isEnabled {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(intensity))
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                    }
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: glassEffects.isEnabled
                                    ? [.white.opacity(borderOpacity * 2), .white.opacity(borderOpacity * 0.3)]
                                    : [.white.opacity(0.10), .white.opacity(0.04)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(glassEffects.isEnabled ? 0.18 : 0.08), radius: glassEffects.isEnabled ? 20 : 6, x: 0, y: glassEffects.isEnabled ? 8 : 2)
    }
}

// MARK: - Glass Button

struct GlassButton: View {
    let title: String
    let icon: String
    var color: Color = .blue
    let action: () -> Void

    @State private var pressed = false
    @ObservedObject private var glassEffects = AorusGlassEffectsPreference.shared

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pressed = true }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pressed = false }
                action()
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(color.opacity(glassEffects.isEnabled ? 0.85 : 1.0))
                    if glassEffects.isEnabled {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(glassEffects.isEnabled ? 0.3 : 0.12), lineWidth: 1)
                }
            )
            .scaleEffect(pressed ? 0.95 : 1.0)
            .shadow(color: color.opacity(glassEffects.isEnabled ? 0.45 : 0.15), radius: pressed ? 4 : (glassEffects.isEnabled ? 12 : 5), x: 0, y: pressed ? 2 : (glassEffects.isEnabled ? 6 : 2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass Toggle Row

struct GlassToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var iconColor: Color = .blue
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .tint(iconColor)
                .onChange(of: isOn) { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Animated Background

struct AorusAnimatedBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#0A0A1A"), Color(hex: "#0D1B2A"), Color(hex: "#12203A")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(hex: "#2979FF").opacity(0.18))
                .frame(width: 350, height: 350)
                .blur(radius: 80)
                .offset(x: animate ? -60 : 60, y: animate ? -120 : -80)
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: animate)

            Circle()
                .fill(Color(hex: "#FF6D00").opacity(0.12))
                .frame(width: 280, height: 280)
                .blur(radius: 70)
                .offset(x: animate ? 80 : -40, y: animate ? 100 : 160)
                .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: animate)
        }
        .onAppear { animate = true }
    }
}

// MARK: - Spring Transition

extension AnyTransition {
    static var glassSlide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

// MARK: - Color Hex init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
