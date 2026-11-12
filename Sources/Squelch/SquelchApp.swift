import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        UserDefaults.standard.register(defaults: Dictionary(uniqueKeysWithValues:
            SponsorBlock.categories.map { ($0.key, $0.defaultOn) }))
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            Task { @MainActor in
                let item: SidebarItem = CommandLine.arguments.contains("--subscriptions") ? .subscriptions
                    : CommandLine.arguments.contains("--search") ? .search
                    : CommandLine.arguments.contains("--channel") ? .channel("")
                    : CommandLine.arguments.contains("--queue") ? .queue : .latest
                await Snapshot.render(to: URL(fileURLWithPath: path), item: item,
                                      panelOnly: CommandLine.arguments.contains("--panel"))
                exit(0)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        }
        if CommandLine.arguments.contains("--subtitle-flow") {
            Task { @MainActor in
                let ok = await SubtitleFlowCheck.run(CommandLine.arguments)
                exit(ok ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--subtitle-check") {
            Task { @MainActor in
                let ok = await SubtitleCheck.run(CommandLine.arguments)
                exit(ok ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in
                let ok = await SelfTest.run()
                exit(ok ? 0 : 1)
            }
            dispatchMain()
        }
        SquelchApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var player: Player?
    static weak var library: Library?

    // `squelch://add?channel=@handle`：App 開著也能直接訂閱，不用關掉再改 library.json。
    // 自己接 Apple Event，不用 SwiftUI 的 onOpenURL：那個會把主視窗叫到前面。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        guard let command = ChannelInput.command(from: url) else {
            NSLog("Squelch: 看不懂這個網址：%@", text)
            return
        }
        guard let library = Self.library else { return }
        switch command {
        case .add(let input):
            Task {
                do {
                    let title = try await library.addChannel(input)
                    NSLog("Squelch: 已加入頻道 %@", title)
                } catch {
                    NSLog("Squelch: 加入 %@ 失敗：%@", input, error.localizedDescription)
                }
            }
        case .remove(let input):
            do {
                let title = try library.removeChannel(matching: input)
                NSLog("Squelch: 已移除頻道 %@", title)
            } catch {
                NSLog("Squelch: 移除 %@ 失敗：%@", input, error.localizedDescription)
            }
        }
    }

    // 關掉視窗照樣在背景播，從選單列或 Dock 叫回來。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Self.player?.saveProgress(force: true)
    }
}

struct SquelchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library: Library
    @State private var player: Player
    @State private var account: Account
    @State private var subtitles: Subtitles

    init() {
        let account = Account()
        let library = Library()
        library.account = account
        let player = Player(library: library)
        player.history = WatchHistory(account: account)
        let subtitles = Subtitles()
        subtitles.player = player
        player.subtitles = subtitles
        _subtitles = State(initialValue: subtitles)
        _account = State(initialValue: account)
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        AppDelegate.player = player
        AppDelegate.library = library
        library.startAutoRefresh()
        library.startLiveWatch()
        Task.detached(priority: .background) { YTDLP.pruneCache() }
        YTDLPUpdate.checkIfDue()
    }

    var body: some Scene {
        Window("Squelch", id: "main") {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(account)
                .environment(subtitles)
                .frame(minWidth: 900, minHeight: 500)
        }
        .commands { PlaybackCommands(player: player) }

        // 桌面迷你模式：無邊框、浮在最上層，拖背景移動。位置由系統記住。
        Window("迷你播放器", id: "mini") {
            MiniPlayer()
                .environment(library)
                .environment(player)
                .environment(subtitles)
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultWindowPlacement { content, context in
            // 第一次打開放在螢幕右上角。
            let size = content.sizeThatFits(.unspecified)
            let screen = context.defaultDisplay.visibleRect
            return WindowPlacement(CGPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24), size: size)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(library)
                .environment(player)
        } label: {
            Image(systemName: player.isPlaying ? "waveform" : "waveform.path")
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(account)
                .environment(subtitles)
        }
    }
}

struct PlaybackCommands: Commands {
    let player: Player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandMenu("播放") {
            Button("迷你模式") { MiniMode.toggle(openWindow: openWindow, dismissWindow: dismissWindow) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button(player.isPlaying ? "暫停" : "播放") { player.toggle() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(player.current == nil)
            Button("倒退 15 秒") { player.skip(-15) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.current == nil)
            Button("快轉 30 秒") { player.skip(30) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player.current == nil)
            Button("下一集") { player.playNext() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            Divider()
            Button("大聲一點") { player.changeVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("小聲一點") { player.changeVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button(player.volume == 0 ? "取消靜音" : "靜音") { player.toggleMute() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("加快") { player.cycleRate(1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("放慢") { player.cycleRate(-1) }
                .keyboardShortcut("[", modifiers: .command)
        }
    }
}

struct MenuBarContent: View {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let ep = player.current {
            Text(ep.title)
            if player.isLive {
                Text("\(ep.channelTitle) · 直播中")
            } else {
                Text("\(ep.channelTitle) · \(Format.time(player.position)) / \(Format.time(player.duration)) · \(Format.rate(player.rate))")
            }
            Divider()
            Button(player.isPlaying ? "暫停" : "播放") { player.toggle() }
            Button("倒退 15 秒") { player.skip(-15) }
            Button("快轉 30 秒") { player.skip(30) }
            Button("下一集") { player.playNext() }
            Divider()
        } else {
            Text("沒有在播")
            Divider()
        }
        Button("打開 Squelch") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("迷你模式") {
            openWindow(id: "mini")
            dismissWindow(id: "main")
        }
        Button("結束 Squelch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// 完整視窗和迷你視窗二選一：打開一個就收起另一個。
@MainActor
enum MiniMode {
    static var isActive: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("mini") == true && $0.isVisible }
    }

    static func toggle(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        if isActive {
            openWindow(id: "main")
            NSApp.activate()
            dismissWindow(id: "mini")
        } else {
            openWindow(id: "mini")
            dismissWindow(id: "main")
        }
    }
}
