import AppKit
import SwiftUI

/// `Squelch --snapshot out.png`：把主視窗畫成 PNG，用真的頻道資料，不需要螢幕錄影權限。
/// 加 `--panel` 只畫右側的「正在播放」面板：離屏截圖抓不到 inspector 和側欄（毛玻璃），主視窗裡那兩欄是黑的。
@MainActor
enum Snapshot {
    static func render(to url: URL, item: SidebarItem = .latest, panelOnly: Bool = false) async {
        let library = Library()
        if library.episodes.isEmpty { await library.refresh() }
        if item == .search { await library.search("WWDC SwiftUI") }
        // `--channel`：第一個頻道的頁面。
        var item = item
        if item == .channel(""), let first = library.channels.first { item = .channel(first.id) }
        let player = Player(library: library)
        if let ep = library.list(for: .latest).first {
            player.current = ep
            player.duration = ep.duration ?? 2900
            player.position = player.duration * 0.31
            player.segments = [SkipSegment(start: 101, end: 195, category: "sponsor")]
            player.isPlaying = true
        }
        // `--width 900`：看窄視窗的排版（主視窗最小 900 寬）。
        let width = CommandLine.arguments.firstIndex(of: "--width").flatMap {
            $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 1280
        let size = panelOnly ? NSSize(width: 320, height: 820) : NSSize(width: width, height: 800)
        let root: AnyView = panelOnly
            ? AnyView(PlayerPanel().background(Color(nsColor: .windowBackgroundColor)))
            : AnyView(ContentView(initialSelection: item))
        let view = root
            .environment(library)
            .environment(player)
            .environment(Account(checkWebKit: false))
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        // 把工具列接到視窗上，截圖後才能列出工具列裡有什麼（工具列畫在視窗框上，PNG 裡看不到）。
        host.sceneBridgingOptions = [.toolbars, .title]
        host.frame = NSRect(origin: .zero, size: size)
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
        printSearchFields(in: window)
    }

    /// 列出視窗裡的搜尋框在哪：工具列裡的、內容裡的（側欄上方那種），各幾個、多寬、x 在哪。
    private static func printSearchFields(in window: NSWindow) {
        for item in window.toolbar?.items ?? [] where item is NSSearchToolbarItem {
            print("toolbar search: \(item.itemIdentifier.rawValue)")
        }
        func walk(_ view: NSView) {
            if view is NSSearchField {
                let frame = view.convert(view.bounds, to: nil)
                print("search field: x=\(Int(frame.minX)) width=\(Int(frame.width)) in \(type(of: view.superview ?? view))")
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview { walk(root) }
    }
}
