import SwiftUI
import WebKit

struct LoginSheet: View {
    @Environment(Account.self) private var account
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("登入 YouTube").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            LoginWebView(account: account) {
                Task {
                    await account.refreshState()
                    guard account.isLoggedIn else { return }
                    dismiss()
                    await library.loadSubscriptions(force: true)
                }
            }
        }
        .frame(width: 520, height: 700)
    }
}

/// Google 登入頁。登入完成會導回 www.youtube.com，這時檢查 cookie。
struct LoginWebView: NSViewRepresentable {
    let account: Account
    let onYouTube: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onYouTube: onYouTube) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: account.makeLoginConfiguration())
        webView.customUserAgent = Account.userAgent
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: Account.loginURL))
        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onYouTube: () -> Void
        init(onYouTube: @escaping () -> Void) { self.onYouTube = onYouTube }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            if webView.url?.host == "www.youtube.com" { onYouTube() }
        }
    }
}
