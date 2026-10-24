import SwiftUI
import UIKit
import Foundation
import CoreText
struct StoreTheme {
    static let accent = Color(hex: "#7AA2FF")
    static let onAccent = Color(hex: "#0B1020")
    static let background = Color(hex: "#0B1020")
    static let surface = Color(hex: "#151B2E")
    static let surfaceBorder = Color(hex: "#262F4A")
    static let sheet = Color(hex: "#11172A")
    static let field = Color(hex: "#1C2340")
    static let textPrimary = Color(hex: "#F2F4FA")
    static let textSecondary = Color(hex: "#9AA3BC")
    static let badgeNew = Color(hex: "#34D399")
    static let badgeUpdated = Color(hex: "#FBBF24")
    static let tabInactive = Color(hex: "#7B84A1")
    static let splashBlue = Color(hex: "#011D57")

    static let pageHorizontal: CGFloat = 16
    static let sectionGap: CGFloat = 26
    static let cardRadius: CGFloat = 20
    static let compactRadius: CGFloat = 14
    static let iconRadius: CGFloat = 17
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: UInt64
        switch cleaned.count {
        case 8: (r, g, b, a) = (value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        default: (r, g, b, a) = (value >> 16, value >> 8 & 0xFF, value & 0xFF, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

enum AppFont {
    static func regular(_ size: CGFloat) -> Font { custom("PingARLT-Regular", size: size, fallback: .regular) }
    static func medium(_ size: CGFloat) -> Font { custom("PingARLT-Medium", size: size, fallback: .medium) }
    static func bold(_ size: CGFloat) -> Font { custom("PingARLT-Bold", size: size, fallback: .bold) }
    static func black(_ size: CGFloat) -> Font { custom("PingARLT-Black", size: size, fallback: .black) }

    private static func custom(_ name: String, size: CGFloat, fallback: Font.Weight) -> Font {
        if UIFont(name: name, size: size) != nil { return .custom(name, size: size) }
        return .system(size: size, weight: fallback, design: .rounded)
    }
}

enum FontLoader {
    static func registerBundledPingAR() {
        ["PingARLT-Regular", "PingARLT-Medium", "PingARLT-Bold", "PingARLT-Black"].forEach { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { return }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// A short tap response. No timers; respects Accessibility > Reduce Motion.
struct StoreGlassPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

extension View {
    /// Lightweight specular highlights using gradients, not offscreen blur.
    /// Works on iOS 16.1 and newer.
    func storeCard(radius: CGFloat = StoreTheme.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background {
                shape.fill(LinearGradient(
                    colors: [StoreTheme.field.opacity(0.91),
                             StoreTheme.surface.opacity(0.98), StoreTheme.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            }
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.28), StoreTheme.accent.opacity(0.12),
                                 .white.opacity(0.04), .white.opacity(0.13)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .allowsHitTesting(false)
            }
    }
}
