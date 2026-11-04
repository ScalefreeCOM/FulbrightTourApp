import SwiftUI
import AppKit
import StudyToursCore

/// West → East: USA (sidebar) · Fulbright (content) · EU (inspector).
enum Theme {
    // USA — Old Glory
    static let usNavy = Color(red: 10/255, green: 49/255, blue: 97/255)        // #0A3161
    static let usRed = Color(red: 179/255, green: 25/255, blue: 66/255)        // #B31942
    // Fulbright Visual Identity Standards — primary palette
    static let fbBlue = Color(red: 0/255, green: 61/255, blue: 165/255)        // Legacy Blue #003DA5
    static let fbMid = Color(red: 0/255, green: 119/255, blue: 200/255)        // Azure Blue  #0077C8
    static let fbCyan = Color(red: 0/255, green: 169/255, blue: 224/255)       // Sky Blue    #00A9E0
    // Fulbright neutrals
    static let lightGray = Color(red: 199/255, green: 201/255, blue: 199/255)  // #C7C9C7
    static let slate = Color(red: 112/255, green: 115/255, blue: 114/255)      // #707372

    /// Brand typeface for digital use is Montserrat (fallback per brand guide); system font if not installed.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        NSFont(name: "Montserrat-Regular", size: size) != nil
            ? .custom("Montserrat", size: size).weight(weight)
            : .system(size: size, weight: weight)
    }
    // High-contrast variants for text/icons on the dark glass (WCAG AA ≥ 4.5:1 on navy)
    static let skyOnDark = Color(red: 191/255, green: 232/255, blue: 250/255)    // #BFE8FA
    static let alertOnDark = Color(red: 255/255, green: 153/255, blue: 168/255)  // #FF99A8
    static let warnOnDark = Color(red: 255/255, green: 200/255, blue: 120/255)   // #FFC878

    // EU flag
    static let euBlue = Color(red: 0/255, green: 51/255, blue: 153/255)        // #003399
    static let euGold = Color(red: 255/255, green: 204/255, blue: 0/255)       // #FFCC00
}

// MARK: - USA: star field + stripe

struct StarField: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 1776)
            for _ in 0..<Int(size.width * size.height / 900) {
                let p = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height)
                let r = 1.5 + rng.next() * 2.5
                ctx.fill(Star.path(center: p, radius: r), with: .color(.white.opacity(0.06 + rng.next() * 0.08)))
            }
        }
        .allowsHitTesting(false)
    }
}

struct USSidebarBackground: View {
    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Theme.usNavy, Theme.usNavy.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            StarField()
            HStack(spacing: 3) {
                Rectangle().fill(Theme.usRed).frame(width: 4)
                Rectangle().fill(.white.opacity(0.85)).frame(width: 2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .ignoresSafeArea()
    }
}

// MARK: - EU: ring of 12 stars

struct EUStarRing: View {
    var size: CGFloat = 70
    var body: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let ring = s.width * 0.36
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi - .pi / 2
                let p = CGPoint(x: c.x + ring * cos(a), y: c.y + ring * sin(a))
                ctx.fill(Star.path(center: p, radius: s.width * 0.055), with: .color(Theme.euGold))
            }
        }
        .frame(width: size, height: size)
    }
}

enum Star {
    static func path(center c: CGPoint, radius r: CGFloat) -> Path {
        var p = Path()
        for i in 0..<10 {
            let rad = i.isMultiple(of: 2) ? r : r * 0.4
            let a = Double(i) * .pi / 5 - .pi / 2
            let pt = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1)
    }
}

// MARK: - Fulbright: header band

struct FulbrightHeader: View {
    let title: String
    var subtitle: String = ""
    var systemImage: String = "globe.europe.africa"

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage).font(.system(size: 26, weight: .light))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(22, .semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.callout).opacity(0.85) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 22, tint: Theme.fbBlue.opacity(0.9))
    }
}

// MARK: - Liquid Glass (macOS 26+), material fallback before

extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        // Default navy tint keeps text legible over the detailed background artwork.
        // Strong navy tint: white text stays readable on the light background.
        let tint = tint ?? Theme.usNavy.opacity(0.85)
        if Snapshot.active {
            // Offscreen snapshots can't capture Liquid Glass; draw an opaque stand-in to review layout and contrast.
            self.background(tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background(Theme.usNavy.opacity(0.55), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// The Gemini-generated artwork spans the whole window (USA west · Fulbright center · EU east).
struct AppBackground: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color(red: 0.89, green: 0.92, blue: 0.96)          // same blue-grey as the artwork's base tone
                // low-contrast version of the artwork (variant B, see design/background-variants)
                if let img = BrandImage.load("background-lowcontrast") ?? BrandImage.load(BrandImage.hero) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    Capsule().fill(Theme.fbCyan).frame(width: 4, height: 16)   // brand accent as shape, not as text colour
                    Text(title).font(Theme.font(15, .semibold)).foregroundStyle(.white)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 18)
    }
}

// MARK: - Partner logos

enum Partner: String, CaseIterable, Identifiable {
    case germany = "germany"
    case hungary = "hungary"
    case enam = "enam"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .germany: return "Fulbright Alumni e.V."
        case .hungary: return "Hungarian Fulbright Association"
        case .enam: return "ENAM"
        }
    }
    var subtitle: String {
        switch self {
        case .germany: return "German Fulbright Alumni Association"
        case .hungary: return "Hungary"
        case .enam: return "European Network of American Alumni Associations"
        }
    }

    var image: NSImage? { BrandImage.load(rawValue, trimWhitespace: true) }
}

struct PartnerLogo: View {
    let partner: Partner
    var height: CGFloat = 40
    var body: some View {
        if let img = partner.image {
            Image(nsImage: img).resizable().scaledToFit().frame(height: height)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(partner.name).font(.caption.weight(.semibold))
                Text(partner.subtitle).font(.caption2).opacity(0.75)
            }
            .frame(minHeight: height, alignment: .leading)
        }
    }
}

/// Disambiguate from Foundation.Host.
typealias Host = StudyToursCore.Host

/// Loads images by base name: user overrides (Settings → Branding) → app bundle → project folder (for `swift run`).
enum BrandImage {
    static let fulbrightPrimary = "Fulbright_Primary_RGB_FullColor"
    static let fulbrightGlobe = "Fulbright_Globe_RGB_FullColor"
    static let hero = "Gemini_Generated_Image_sln0tjsln0tjsln0"

    private static var cache: [String: NSImage] = [:]

    static func load(_ name: String, trimWhitespace: Bool = false) -> NSImage? {
        let key = name + (trimWhitespace ? "#trim" : "")
        if let c = cache[key] { return c }
        var dirs = [Store.logosDirectory]
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Logos")) }
        // dev fallback: <package>/Resources/Logos relative to this source file
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Logos"))
        for d in dirs {
            for ext in ["png", "jpg", "jpeg"] {
                if var i = NSImage(contentsOf: d.appendingPathComponent("\(name).\(ext)")) {
                    if trimWhitespace { i = trimmed(i) }
                    cache[key] = i
                    return i
                }
            }
        }
        return nil
    }

    static func invalidate() { cache = [:] }

    /// Crops surrounding white/transparent margins (the artwork itself is not changed).
    static func trimmed(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let a = buf[o + 3]
                let isBlank = a < 16 || (buf[o] > 240 && buf[o + 1] > 240 && buf[o + 2] > 240)
                if !isBlank { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // keep a small clear-space margin around the mark
        let pad = Int(Double(max(maxX - minX, maxY - minY)) * 0.04)
        let rect = CGRect(x: max(minX - pad, 0), y: max(minY - pad, 0),
                          width: min(maxX - minX + 1 + 2 * pad, w), height: min(maxY - minY + 1 + 2 * pad, h))
        // Bitmap buffer row 0 is the top row — same orientation as CGImage cropping.
        guard let c = cg.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))) else { return image }
        return NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
    }
}

/// Hero banner: USA (west) · Fulbright (center) · EU (east).
struct HeroBanner: View {
    var height: CGFloat = 230
    var body: some View {
        if let img = BrandImage.load(BrandImage.hero) ?? BrandImage.load("Background") {
            // Anchor to the top so the Fulbright mark in the artwork stays visible.
            Color.clear.frame(height: height).frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Fulbright study tour banner: United States, Fulbright, Europe")
        }
    }
}
