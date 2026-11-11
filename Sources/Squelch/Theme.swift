import AppKit
import ImageIO
import SwiftUI

/// Squelch 的配色：圖示的琥珀色當主色，底色是圖示背景那種夜間駕駛艙的藍黑。
/// 主視窗固定深色（像 Spotify），頁面頂端和播放列再依封面的顏色染一層（像 Apple Music）。
enum Theme {
    static let amber = Color(red: 1, green: 0.698, blue: 0.118)          // #FFB21E
    /// 琥珀底上的圖示用藍黑，白色在琥珀上看不清楚。
    static let onAmber = Color(red: 0.051, green: 0.067, blue: 0.098)
    static let base = Color(red: 0.055, green: 0.071, blue: 0.102)       // #0E121A
    static let bar = Color(red: 0.035, green: 0.047, blue: 0.071)        // #090C12
    static let live = Color(red: 1, green: 0.30, blue: 0.30)
    /// 音量超過 100%（放大）的顏色。主色已經是琥珀，放大改用珊瑚紅，兩個才分得開。
    static let boost = Color(red: 1, green: 0.42, blue: 0.29)
    /// SponsorBlock 會跳過的片段。
    static let sponsor = Color(red: 0.24, green: 0.84, blue: 0.55)
    static let hover = Color.white.opacity(0.07)
}

extension SidebarItem {
    var symbol: String {
        switch self {
        case .latest: "sparkles"
        case .live: "dot.radiowaves.left.and.right"
        case .search: "magnifyingglass"
        case .subscriptions: "person.2.fill"
        case .inProgress: "clock.arrow.circlepath"
        case .queue: "list.bullet"
        case .history: "clock.fill"
        case .channel: "antenna.radiowaves.left.and.right"
        }
    }

    /// 側欄小方塊和頁面頂端的漸層。頻道頁改用頭像取出來的顏色。
    var colors: [Color] {
        switch self {
        case .latest: [Theme.amber, Color(red: 0.95, green: 0.42, blue: 0.10)]
        case .live: [Color(red: 1, green: 0.32, blue: 0.32), Color(red: 0.76, green: 0.10, blue: 0.36)]
        case .search: [Color(red: 0.18, green: 0.78, blue: 0.72), Color(red: 0.10, green: 0.45, blue: 0.70)]
        case .subscriptions: [Color(red: 0.50, green: 0.40, blue: 1), Color(red: 0.30, green: 0.18, blue: 0.80)]
        case .inProgress: [Color(red: 0.25, green: 0.84, blue: 0.55), Color(red: 0.08, green: 0.52, blue: 0.36)]
        case .queue: [Color(red: 0.32, green: 0.56, blue: 1), Color(red: 0.17, green: 0.30, blue: 0.82)]
        case .history: [Color(red: 0.56, green: 0.60, blue: 0.68), Color(red: 0.29, green: 0.33, blue: 0.41)]
        case .channel: [Color(red: 0.56, green: 0.60, blue: 0.68), Color(red: 0.29, green: 0.33, blue: 0.41)]
        }
    }
}

/// 側欄和頁首用的彩色方塊圖示。
struct TileIcon: View {
    let item: SidebarItem
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: item.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: item.symbol)
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

/// 從縮圖或頭像取一個代表色，給頁首和播放列染色。用彩度加權平均：灰的、黑的像素幾乎不算。
@MainActor @Observable
final class ArtworkPalette {
    static let shared = ArtworkPalette()

    private var colors: [URL: Color] = [:]
    private var ambients: [URL: CGImage] = [:]
    @ObservationIgnored private var requested: Set<URL> = []

    /// 縮到 6×6 的封面，放大後就是一片柔和的色塊，當面板背景。不靠 `.blur`：離屏截圖畫不出圖層濾鏡。
    func ambient(for url: URL?) -> CGImage? {
        guard let url else { return nil }
        _ = color(for: url)
        return ambients[url]
    }

    /// 還沒算好時回傳 nil，算好後畫面會自己更新。
    func color(for url: URL?) -> Color? {
        guard let url else { return nil }
        if let color = colors[url] { return color }
        if !requested.contains(url) {
            requested.insert(url)
            Task {
                guard let result = await Self.extract(url) else { return }
                colors[url] = Color(red: result.rgb.0, green: result.rgb.1, blue: result.rgb.2)
                ambients[url] = Self.image(result.ambient, side: Self.ambientSide)
            }
        }
        return nil
    }

    nonisolated static let ambientSide = 6

    nonisolated static func draw(_ image: CGImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    static func image(_ pixels: [UInt8], side: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    nonisolated static func extract(_ url: URL) async -> (rgb: (Double, Double, Double), ambient: [UInt8])? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 48,
              ] as CFDictionary) else { return nil }
        guard let pixels = draw(image, side: 16), let ambient = draw(image, side: ambientSide) else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
            let high = max(pr, pg, pb), low = min(pr, pg, pb)
            let saturation = high == 0 ? 0 : (high - low) / high
            let weight = 0.02 + saturation * saturation * high
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }
        // 調成適合當深色背景的顏色：亮度固定，彩度拉到看得出顏色，但不刺眼。
        let average = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        let tunedSat = sat < 0.08 ? sat : min(max(sat, 0.45), 0.85)
        guard let tuned = NSColor(hue: hue, saturation: tunedSat, brightness: 0.62, alpha: 1).usingColorSpace(.sRGB) else { return nil }
        return ((Double(tuned.redComponent), Double(tuned.greenComponent), Double(tuned.blueComponent)), ambient)
    }
}

/// 頁面背景：藍黑底，頂端一片封面色往下淡掉。
struct PageBackground: View {
    var color: Color

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base
            LinearGradient(stops: [
                .init(color: color.opacity(0.62), location: 0),
                .init(color: color.opacity(0.22), location: 0.55),
                .init(color: color.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 460)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: color)
    }
}

/// 正在播的那一列，用跳動的三條取代編號。暫停時停在低處。
struct EqualizerBars: View {
    var playing: Bool
    var color: Color = Theme.amber

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let level = playing ? (sin(t * (5.3 + Double(i) * 1.9) + Double(i) * 1.3) + 1) / 2 : 0.25
                    Capsule().frame(width: 3, height: 3 + 11 * level)
                }
            }
            .frame(height: 14, alignment: .bottom)
            .foregroundStyle(color)
        }
        .accessibilityLabel(playing ? Text("播放中") : Text("暫停"))
    }
}

/// 細的進度條：平常是一條細線，滑鼠移上去變粗、出現圓鈕、填色變成主色。進度和音量共用。
struct ThinSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var fill: Color = .white
    var activeFill: Color = Theme.amber
    /// 要標出來的區段（SponsorBlock 會跳過的片段）。
    var marks: [ClosedRange<Double>] = []
    var markColor: Color = Theme.sponsor
    /// 刻度（音量的 100%）。
    var tick: Double?
    var step: Double = 0
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void = { _ in }

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let active = hovering || dragging
            let height: CGFloat = active ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule()
                    .fill(active ? activeFill : fill)
                    .frame(width: max(height, width * fraction(value)))
                // 片段畫在填色上面，播過了也看得到。
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Capsule()
                        .fill(markColor)
                        .frame(width: max(3, width * (fraction(mark.upperBound) - fraction(mark.lowerBound))))
                        .offset(x: width * fraction(mark.lowerBound))
                }
                if let tick {
                    Rectangle()
                        .fill(.white.opacity(0.55))
                        .frame(width: 1.5, height: 12)
                        .offset(x: width * fraction(tick) - 0.75)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: width * fraction(value) - 6.5)
                    .opacity(active ? 1 : 0)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    onChanged(value(at: drag.location.x, width: width))
                }
                .onEnded { drag in
                    dragging = false
                    onEnded(value(at: drag.location.x, width: width))
                })
        }
        .frame(height: 16)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering || dragging)
        .accessibilityElement()
        .accessibilityValue(Text(String(format: "%.0f%%", fraction(value) * 100)))
        .accessibilityAdjustableAction { direction in
            let delta = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
            let next = min(max(value + (direction == .increment ? delta : -delta), range.lowerBound), range.upperBound)
            onChanged(next)
            onEnded(next)
        }
    }

    private func fraction(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        let f = min(max(Double(x / width), 0), 1)
        var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
        if step > 0 { v = (v / step).rounded() * step }
        return v
    }
}

/// 小圖示按鈕：平常灰，滑鼠移上去變白，按下去縮一點。
struct GlyphButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        GlyphBody(configuration: configuration, active: active)
    }

    private struct GlyphBody: View {
        let configuration: Configuration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(color)
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }

        private var color: Color {
            if !isEnabled { return .white.opacity(0.25) }
            if active { return Theme.amber }
            return hovering ? .white : .white.opacity(0.68)
        }
    }
}

/// 主色的圓形播放鈕：滑鼠移上去放大一點，按下去縮一點。
struct PlayCircle: View {
    var size: CGFloat
    var playing: Bool
    var loading = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.amber)
                if loading {
                    ProgressView().controlSize(size > 44 ? .regular : .small).tint(Theme.onAmber)
                } else {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.38, weight: .black))
                        .foregroundStyle(Theme.onAmber)
                        .offset(x: playing ? 0 : size * 0.035)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: hovering ? 10 : 6, y: 3)
            .scaleEffect(hovering ? 1.05 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.2), value: hovering)
        .accessibilityLabel(playing ? Text("暫停") : Text("播放"))
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// 縮圖：載入前是一塊深色。
struct Thumbnail: View {
    let url: URL?
    var cornerRadius: CGFloat = 6

    var body: some View {
        Color.clear
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.white.opacity(0.06))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    /// List 的列不要系統的內距、分隔線和底色，整列自己畫。
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
