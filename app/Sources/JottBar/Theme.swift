import SwiftUI
import AppKit

// ======================================================================
// PALETTE
// ======================================================================
// One place for the brand colours so the whole app reads as one surface.
// Everything used to lean on `Color.accentColor`, which is whatever the
// user picked in System Settings -- fine, but it meant the app had no
// identity of its own and the weekly timesheet could not be styled to
// match the rest. These are fixed values instead.
//
// Each colour is built as a dynamic NSColor so the light/dark pair is
// resolved by the system at draw time. SwiftUI's `.opacity()` composites
// against whatever is behind it, so tints stay correct in both modes.

enum Theme {

    /// Light/dark pair, resolved per-appearance rather than per-launch.
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }

    // ----- Brand -----------------------------------------------------
    /// The signature red. Brightened slightly in dark mode: the light-mode
    /// value sits too close to the background to carry a label.
    static let accent = dynamic(light: hex(0xE74123), dark: hex(0xFF5A3C))

    /// The counterpart used for anything deliberately *not* billable --
    /// internal meetings, breaks, non-ticket time.
    static let slate = dynamic(light: hex(0x6B7D88), dark: hex(0x8FA3AE))

    // ----- Surfaces --------------------------------------------------
    /// The page itself. Flat white in light mode, matching the mockup.
    static let surface = dynamic(light: hex(0xFFFFFF), dark: hex(0x1C2227))
    /// Headers, grouping rows, anything one step back from the page.
    static let surfaceMuted = dynamic(light: hex(0xF6F7F8), dark: hex(0x232A30))
    /// The inverted bar: totals footer, primary chrome.
    static let ink = dynamic(light: hex(0x25313A), dark: hex(0x0F1418))
    /// Text that sits on `ink`.
    static let onInk = dynamic(light: hex(0xFFFFFF), dark: hex(0xEDF1F3))
    /// The shell's sidebar. Dark in BOTH themes on purpose -- it is chrome,
    /// and the contrast against the page is what makes the shell read as a
    /// frame around the content rather than more content.
    static let sidebar = dynamic(light: hex(0x1B2127), dark: hex(0x12171B))

    // ----- Lines and text --------------------------------------------
    static let hairline = dynamic(light: hex(0xE3E7EA), dark: hex(0x323A41))
    static let primaryText = dynamic(light: hex(0x1A2228), dark: hex(0xE8ECEF))
    static let secondaryText = dynamic(light: hex(0x6B7D88), dark: hex(0x9AA8B1))
    static let tertiaryText = dynamic(light: hex(0xA8B4BB), dark: hex(0x6B7780))

    // ----- Heat ------------------------------------------------------
    /// Cell tint for a duration, as a fraction of the biggest cell in the
    /// grid. Opacity rather than a colour ramp so it composites correctly
    /// over either background, and floored well above zero so a one-minute
    /// entry still reads as "something happened here".
    static func heat(_ fraction: Double, billable: Bool) -> Color {
        let base = billable ? accent : slate
        let clamped = min(max(fraction, 0), 1)
        // Square-root curve: durations cluster at the low end, and a linear
        // ramp left almost every cell looking identical.
        return base.opacity(0.08 + 0.42 * sqrt(clamped))
    }
}

// ======================================================================
// APPEARANCE
// ======================================================================
// Every colour above is a light/dark pair resolved from the effective
// appearance, so overriding appearance at the application level is the
// only lever needed: NSApp.appearance cascades to every window, and the
// dynamic providers re-resolve on the next draw.

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// nil means "inherit", which is what follows the system setting --
    /// including when the user flips it while JottBar is running.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var next: AppearanceMode {
        let all = AppearanceMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

extension Theme {
    /// Applies the stored preference. Safe to call repeatedly.
    @MainActor
    static func applyStoredAppearance() {
        NSApp.appearance = Preferences.appearance.nsAppearance
    }

    @MainActor
    static func setAppearance(_ mode: AppearanceMode) {
        Preferences.appearance = mode
        applyStoredAppearance()
    }
}

// ======================================================================
// BRAND MARK
// ======================================================================
// The sidebar tile. Loaded from the bundle rather than drawn, so the
// real wordmark is used where one is available.
//
// Resolution is deliberately forgiving. install.sh copies the asset into
// Contents/Resources, but a plain `swift build` produces a bare
// executable with no bundle at all -- and a checkout without the asset
// is a normal state, not an error. Both fall back to a drawn tile.

enum Brand {
    /// Resolved once: the bundle does not gain files while running, and
    /// this is read on every sidebar redraw.
    static let mark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "redspace-logo", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        return image
    }()
}

/// The brand tile at a given edge length, with the drawn fallback.
struct BrandMark: View {
    var size: CGFloat
    var cornerRadius: CGFloat = 0

    var body: some View {
        Group {
            if let mark = Brand.mark {
                Image(nsImage: mark)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.accent
                    .overlay(
                        Text("J")
                            .font(.system(size: size * 0.48, weight: .heavy))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
