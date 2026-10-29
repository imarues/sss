import SwiftUI
import UIKit
import Foundation
import CoreText
struct StoreTheme {
    private static func adaptive(dark: String, light: String) -> Color {
        func uiColor(_ hex: String) -> UIColor {
            let rgb = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { trait in
            uiColor(trait.userInterfaceStyle == .light ? light : dark)
        })
    }
    // Keep Night identical to the previous palette; Day uses the same brand.
    static let accent = adaptive(dark: "#7AA2FF", light: "#426DE0")
    static let onAccent = adaptive(dark: "#0B1020", light: "#FFFFFF")
    static let background = adaptive(dark: "#0B1020", light: "#F7F9FF")
    static let surface = adaptive(dark: "#151B2E", light: "#FFFFFF")
    static let surfaceBorder = adaptive(dark: "#262F4A", light: "#D6E0F0")
    static let sheet = adaptive(dark: "#11172A", light: "#EFF3FC")
    static let field = adaptive(dark: "#1C2340", light: "#EDF2FD")
    static let textPrimary = adaptive(dark: "#F2F4FA", light: "#17223A")
    static let textSecondary = adaptive(dark: "#9AA3BC", light: "#5E6D88")
    static let badgeNew = adaptive(dark: "#34D399", light: "#128D66")
    static let badgeUpdated = adaptive(dark: "#FBBF24", light: "#9D6800")
    static let tabInactive = adaptive(dark: "#7B84A1", light: "#6A7591")
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
