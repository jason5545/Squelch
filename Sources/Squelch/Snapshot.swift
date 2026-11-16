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
        // `--height 560`：看矮視窗（側欄頻道多時要能捲）。
        let height = CommandLine.arguments.firstIndex(of: "--height").flatMap {
            $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 800
        // `--mini`：桌面迷你模式（放在深色底上看圓角和邊框）。
        let mini = CommandLine.arguments.contains("--mini")
        // `--sidebar`：只畫側欄，底色換成不透明（主視窗裡側欄是毛玻璃，離屏截圖是黑的）。
        let sidebarOnly = CommandLine.arguments.contains("--sidebar")
        let size = panelOnly ? NSSize(width: 320, height: 820)
            : sidebarOnly ? NSSize(width: 240, height: height)
            : mini ? NSSize(width: MiniPlayer.width + 80, height: 260) : NSSize(width: width, height: height)
        let root: AnyView = panelOnly
            ? AnyView(PlayerPanel().background(Color(nsColor: .windowBackgroundColor)))
            : sidebarOnly ? AnyView(Sidebar(selection: .constant(item)).listStyle(.sidebar)
                .scrollContentBackground(.hidden).background(Color(white: 0.16)).preferredColorScheme(.dark))
            : mini ? AnyView(ZStack { Color(white: 0.32); MiniPlayer().fixedSize() })
            : AnyView(ContentView(initialSelection: item))
        // `--subtitles`：播放列上方顯示一句字幕。
        let subtitles = Subtitles(preview: [Cue(start: 0, end: .infinity,
                                                text: "So the trick is that the audio is decoded before it's played.",
                                                translation: "重點是聲音在播出來之前就已經解碼好了。")],
                                  enabled: CommandLine.arguments.contains("--subtitles"))
        let view = root
            .environment(library)
            .environment(player)
            .environment(Account(checkWebKit: false))
            .environment(subtitles)
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
        printScrollViews(in: window)
    }

    /// 列出每個捲動區域的可見高度和內容高度：內容比可見高、`scrolls` 卻是 false，就是捲不動。
    private static func printScrollViews(in window: NSWindow) {
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let doc = scroll.documentView {
                let frame = scroll.convert(scroll.bounds, to: nil)
                print("scroll: x=\(Int(frame.minX)) y=\(Int(frame.minY)) width=\(Int(frame.width)) height=\(Int(frame.height)) visible=\(Int(scroll.contentView.bounds.height)) insets=\(Int(scroll.contentInsets.top))/\(Int(scroll.contentInsets.bottom)) content=\(Int(doc.frame.height)) scrolls=\(scroll.hasVerticalScroller) \(type(of: doc))")
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview { walk(root) }
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
