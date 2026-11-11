import AppKit
import SwiftUI

/// `Squelch --snapshot out.png`：把主視窗畫成 PNG，用真的頻道資料，不需要螢幕錄影權限。
@MainActor
enum Snapshot {
    static func render(to url: URL) async {
        let library = Library()
        if library.episodes.isEmpty { await library.refresh() }
        let player = Player(library: library)
        if let ep = library.list(for: .latest).first {
            player.current = ep
            player.duration = ep.duration ?? 2900
            player.position = player.duration * 0.31
            player.segments = [SkipSegment(start: 101, end: 195, category: "sponsor")]
        }
        let view = ContentView()
            .environment(library)
            .environment(player)
            .frame(width: 1100, height: 700)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(4))   // 等縮圖載入
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }
}
