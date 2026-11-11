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
                let item: SidebarItem = CommandLine.arguments.contains("--subscriptions") ? .subscriptions : .latest
                await Snapshot.render(to: URL(fileURLWithPath: path), item: item)
                exit(0)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
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

    init() {
        let account = Account()
        let library = Library()
        library.account = account
        let player = Player(library: library)
        player.history = WatchHistory(account: account)
        _account = State(initialValue: account)
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        AppDelegate.player = player
        library.startAutoRefresh()
        Task.detached(priority: .background) { YTDLP.pruneCache() }
    }

    var body: some Scene {
        Window("Squelch", id: "main") {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(account)
                .frame(minWidth: 820, minHeight: 500)
        }
        .commands { PlaybackCommands(player: player) }

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
        }
    }
}

struct PlaybackCommands: Commands {
    let player: Player

    var body: some Commands {
        CommandMenu("播放") {
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

    var body: some View {
        if let ep = player.current {
            Text(ep.title)
            Text("\(ep.channelTitle) · \(Format.time(player.position)) / \(Format.time(player.duration)) · \(Format.rate(player.rate))")
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
        Button("結束 Squelch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
