/**
 * PaperApp.swift — the Mac app.
 *
 * A window, a menu bar, and a web view pointed at the loopback server this
 * process runs. The engine, the ledger and the analyst all live in-process; there
 * is no separate server process, no launchd job and no port anyone has to remember.
 *
 * The menu drives the same controls the page already has, by clicking them, so
 * the interface has exactly one implementation of every action.
 */

import AppKit
import SwiftUI
import WebKit

@main
struct PaperMain {
    static func main() {
        // build.sh asks the binary to draw its own icon. That's a build step,
        // not a launch, so it must not bounce in the Dock.
        if let i = CommandLine.arguments.firstIndex(of: "--iconset"),
           CommandLine.arguments.count > i + 1 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Icon.writeIconset(to: CommandLine.arguments[i + 1])
            return
        }
        /* The audit, against whatever book is on disk. Read-only and offline: it
         * opens the shadow book, scores the candidate field and prints the report.
         * Nothing is promoted and nothing is written — deciding to change the
         * desk's reading is the running app's job, and a diagnostic that mutates
         * what it is diagnosing is not one. */
        if CommandLine.arguments.contains("--predictaudit") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            exit(PredictAuditCLI.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--selftest") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            exit(SelfTest.run() ? 0 : 1)
        }
        // The live counterpart to --selftest: every way the prediction desk can break
        // silently is on the far side of a network call, and the self-test cannot see
        // any of them because it runs against fabricated tapes on purpose.
        if CommandLine.arguments.contains("--predicttest") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            // Detached, not a plain Task. `@main`'s entry point is main-actor isolated,
            // so a Task created here inherits that isolation and then deadlocks against
            // the semaphore the main thread is sitting on — silently, with no output at
            // all, which is a memorable hour.
            let done = DispatchSemaphore(value: 0)
            let result = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            result.initialize(to: false)
            Task.detached { result.pointee = await PredictProbe.run(); done.signal() }
            done.wait()
            exit(result.pointee ? 0 : 1)
        }
        PaperApp.main()
    }
}

/// The desk's address, published once the server is up so the web view can load it.
@MainActor
final class Server: ObservableObject {
    static let shared = Server()

    @Published var url: URL?
    @Published var failure: String?

    private var http: HTTPServer?
    private var ticker: Timer?

    func start() {
        guard http == nil else { return }
        // Every request passes the gate before a handler sees it. The token it
        // checks for is delivered only inside the page served from this server.
        let gate = RequestGate()
        let server = HTTPServer(gate: gate) { request in
            if request.path.hasPrefix("/api/") {
                return await Desk.shared.handle(request)
            }
            return SiteFiles.serve(request.path, sessionToken: gate.token)
        }

        Task {
            await Desk.shared.openLedgers()
            do {
                let port = try server.start()
                self.http = server
                self.url = URL(string: "http://127.0.0.1:\(port)/")
                log("Paper — the trading simulator.")
                log("  Desk:    http://127.0.0.1:\(port)/")
                log("  Ledger:  \(Desk.dataDirectory.appendingPathComponent("portfolio.json").path)")
                log("  Analyst: \(Analyst.status().available ? "online (\(Analyst.model))" : "offline — quantitative engine only")")
                log("  Simulation only. No real orders, no brokerage, no real money.")
                self.startTicker()
                // A prediction run left going when the app was last quit picks its own
                // loop back up here. Its windows kept resolving while the app was shut,
                // and the first tick settles every one of them before deciding anything
                // new — so a run comes back to a true balance rather than to the one it
                // had when the lid closed.
                await PredictDesk.shared.resumeAll()
            } catch {
                self.failure = error.localizedDescription
            }
        }
    }

    /// Brackets are swept every time market data refreshes, so a target or stop
    /// fires whether or not anyone is looking at the window.
    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { await Desk.shared.tick() }
        }
    }
}

struct PaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var server = Server.shared

    var body: some Scene {
        WindowGroup("Paper") {
            DeskView()
                .frame(minWidth: 900, minHeight: 620)
                .onAppear { server.start() }
        }
        .defaultSize(width: 1280, height: 860)
        .commands { PaperCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The interface is dark by design (`data-theme="dark"` on the page), so the
        // title bar and the window's own ground match it rather than framing it in
        // a light chrome the content never asked for.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

/* ------------------------------------------------------------------- view */

struct DeskView: View {
    @StateObject private var server = Server.shared

    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.055, blue: 0.071).ignoresSafeArea()
            if let url = server.url {
                WebView(url: url)
            } else if let failure = server.failure {
                VStack(spacing: 10) {
                    Text("Paper could not open its desk.")
                        .font(.system(size: 15, weight: .semibold))
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// The one web view, held as a singleton so menu commands can reach it without
/// threading a reference through the SwiftUI tree.
@MainActor
final class WebHost: NSObject, WKNavigationDelegate {
    static let shared = WebHost()

    let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.071, alpha: 1)
        webView.allowsBackForwardNavigationGestures = false
        // The web inspector can read the session token, so it is off unless asked for: PAPER_INSPECT=1.
        if #available(macOS 13.3, *) { webView.isInspectable = ProcessInfo.processInfo.environment["PAPER_INSPECT"] == "1" }

        // WebKit throttles a page's timers while its window sits in the background,
        // so the desk's own thirty-second poll stalls and the freshness badge goes
        // amber on a desk that is not actually stale. Coming back to the app pulls
        // fresh prices immediately, which is what the badge going green should mean.
        NotificationCenter.default.addObserver(
            self, selector: #selector(wake),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func wake() {
        guard webView.url != nil else { return }
        click("#refresh")
    }

    func load(_ url: URL) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }

    /// Menu actions are performed by clicking the controls the page already has, so
    /// there is never a second implementation of "refresh" to keep in step.
    func click(_ selector: String) {
        run("document.querySelector(\(js(selector)))?.click()")
    }

    func show(_ view: String) {
        click(".tab[data-view=\"\(view)\"]")
    }

    /**
     * Opens settings, moves to the Reset section, and presses the button the page
     * already has — rather than reimplementing the reset behind the menu.
     *
     * The delays are because each step creates the control the next one needs; the
     * dialog that follows is the page's own, so the confirmation and the typed word
     * are identical whichever way you arrived.
     */
    func eraseEverything() {
        click("#settingsBtn")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.click("[data-section=\"danger\"]")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.click("#factoryResetBtn")
            }
        }
    }

    func run(_ script: String) {
        webView.evaluateJavaScript(script) { _, error in
            if let error { log("[ui] \(error.localizedDescription)", .warn, "ui") }
        }
    }

    func reload() {
        webView.reload()
    }

    private func js(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Headlines and news items are real links to real publishers. They belong in
    /// the user's browser, not inside the desk.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if navigationAction.navigationType == .linkActivated, url.host != "127.0.0.1" {
            // Headlines come from a news feed Paper does not control. Only web links go
            // to the browser; a file:, smb: or app-specific scheme is dropped, not opened.
            if let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                NSWorkspace.shared.open(url)
            }
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }
}

struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let host = WebHost.shared
        host.load(url)
        return host.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        WebHost.shared.load(url)
    }
}

/* --------------------------------------------------------------- the menus */

struct PaperCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { WebHost.shared.click("#settingsBtn") }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Button("Refresh Prices") { WebHost.shared.click("#refresh") }
                .keyboardShortcut("r", modifiers: .command)
            Button("Run the Analyst") {
                WebHost.shared.show("analyst")
                // The button only exists once the Analyst view has painted.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    WebHost.shared.click("#runBtn")
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Guided Setup…") {
                WebHost.shared.run("document.querySelector('[data-start-setup]')?.click()")
                // The button only exists on the Settings tab, so fall back to the
                // route the page exposes for exactly this.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    WebHost.shared.run("location.hash = '#start'; location.reload()")
                }
            }

            Divider()

            Button("Show Ledger in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    Desk.dataDirectory.appendingPathComponent("portfolio.json")
                ])
            }
            Button("Reset Account…") { confirmReset() }
            Button("Erase Everything…") { WebHost.shared.eraseEverything() }
        }

        CommandGroup(after: .toolbar) {
            Button("Desk") { WebHost.shared.show("desk") }.keyboardShortcut("1", modifiers: .command)
            Button("Markets") { WebHost.shared.show("markets") }.keyboardShortcut("2", modifiers: .command)
            Button("Analyst") { WebHost.shared.show("analyst") }.keyboardShortcut("3", modifiers: .command)
            Button("Journal") { WebHost.shared.show("journal") }.keyboardShortcut("4", modifiers: .command)
            Button("Learning") { WebHost.shared.show("learning") }.keyboardShortcut("5", modifiers: .command)
            Button("Guide") { WebHost.shared.show("learn") }.keyboardShortcut("6", modifiers: .command)
            Divider()
            Button("Reload Interface") { WebHost.shared.reload() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .help) {
            Button("What Paper Is") { WebHost.shared.show("learn") }
        }
    }

    @MainActor
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset the account?"
        alert.informativeText = "This erases every open position and the whole trade history on the active account, and puts the balance back to its opening figure. The record of what you got right and wrong goes with it — including the evidence behind anything the engine has learned."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await Desk.shared.resetAccount()
            await MainActor.run { WebHost.shared.reload() }
        }
    }
}
