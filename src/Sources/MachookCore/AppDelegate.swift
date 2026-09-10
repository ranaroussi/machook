import Cocoa
import SwiftUI
import Sparkle

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var settingsWindow: NSWindow?

    private var tunnel: TunnelManager?
    private var api: LocalAPIServer?
    private var updater: SPUStandardUpdaterController?

    /// Snapshot of the config fields that require a service bounce, so a
    /// Save that only touched an endpoint's command doesn't tear down the
    /// tunnel and the HTTP listener for no reason.
    private struct ServiceSnapshot: Equatable {
        var tunnelEnabled: Bool
        var tunnelMode: TunnelMode
        var tunnelToken: String
        var tunnelHostname: String
        var ports: [Int]
    }
    private var lastSnapshot: ServiceSnapshot?

    /// The port the listener actually claimed, which can be the fallback.
    /// Everything that has to reach the server uses this, never the
    /// configured primary.
    private var boundPort: Int?

    public override init() {
        super.init()
    }

    // MARK: NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        // Sparkle aborts hard if SUPublicEDKey is missing. Skip the updater
        // entirely until a release build injects a real key.
        let pubKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if !pubKey.isEmpty {
            updater = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }

        installMainMenu()
        setupMenuBar()
        bootRuntime()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configChanged),
            name: AppConfigStore.didChangeNotification,
            object: nil
        )

        // Posted by `TunnelManager` when named mode is selected without a
        // token + hostname, so the alert can send the user to Settings.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .machookOpenSettings,
            object: nil
        )
    }

    public func applicationWillTerminate(_ notification: Foundation.Notification) {
        api?.stop()
        tunnel?.stop()
    }

    // MARK: Runtime

    /// No permission gate here, deliberately: Machook reads no protected
    /// data, drives no other app, and needs no TCC grant. It starts,
    /// listens, and runs what you told it to run.
    private func bootRuntime() {
        // Clean up envelopes orphaned by a crash or a force-quit between
        // writing the file and the `defer` that removes it.
        RequestEnvelope.sweepStagingDirectory()

        let config = AppConfigStore.shared.current
        let tunnel = TunnelManager()
        let api = LocalAPIServer(ports: config.listenPortCandidates(), tunnel: tunnel)

        self.tunnel = tunnel
        self.api = api

        // The tunnel starts from the bind callback, not from here: which
        // port we get is only known once the listener has one, and a
        // tunnel aimed at the wrong port is a 502 with no local symptom.
        api.start { [weak self] port in
            Task { @MainActor in self?.listenerDidBind(port: port) }
        }

        lastSnapshot = snapshot(of: config)
        refreshMenu()
    }

    /// Called every time the listener claims a port, including after a
    /// port change in Settings.
    private func listenerDidBind(port: Int) {
        boundPort = port
        if tunnel?.isRunning == true { tunnel?.stop() }
        if AppConfigStore.shared.current.tunnelEnabled {
            startTunnel(port: port)
        }
        refreshMenu()
    }

    private func snapshot(of config: AppConfig) -> ServiceSnapshot {
        ServiceSnapshot(
            tunnelEnabled: config.tunnelEnabled,
            tunnelMode: config.tunnelMode,
            tunnelToken: config.tunnelToken,
            tunnelHostname: config.tunnelHostname,
            ports: config.listenPortCandidates()
        )
    }

    private func startTunnel(port: Int) {
        tunnel?.start(port: port) { [weak self] url in
            DispatchQueue.main.async { self?.refreshMenu() }
            if let url { Log.tunnel.info("tunnel up: \(url, privacy: .public)") }
        }
    }

    @objc private func configChanged() {
        let config = AppConfigStore.shared.current
        let next = snapshot(of: config)
        let previous = lastSnapshot
        lastSnapshot = next
        refreshMenu()

        guard previous != next else { return }

        // The HTTP listener only needs a bounce when the ports moved. The
        // endpoint table is read per request, so command edits are live.
        if previous?.ports != next.ports {
            Log.app.info("local API ports changed to \(next.ports, privacy: .public); restarting listener")
            api?.stop()
            tunnel?.stop()
            boundPort = nil
            if let tunnel {
                let api = LocalAPIServer(ports: next.ports, tunnel: tunnel)
                self.api = api
                // The bind callback restarts the tunnel on the new port.
                api.start { [weak self] port in
                    Task { @MainActor in self?.listenerDidBind(port: port) }
                }
            }
            return
        }

        if tunnel?.isRunning == true { tunnel?.stop() }
        if config.tunnelEnabled, let boundPort { startTunnel(port: boundPort) }
    }

    // MARK: Main menu (keybindings)

    /// Install a minimal `NSApp.mainMenu` so SwiftUI text fields get
    /// `Cmd+C / V / X / A / Z / Shift+Z`. Without this, the responder
    /// chain has no menu item bound to those key equivalents and the
    /// shortcuts no-op silently — a classic `LSUIElement` gotcha for
    /// menu-bar-only apps with a Settings window.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Machook",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",       action: Selector(("undo:")),             keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")),         keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),        keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),       keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),      keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),  keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.image?.accessibilityDescription = "Machook"
        }
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshMenu()
    }

    /// Rebuild right before the menu opens so the tunnel URL, endpoint
    /// count, and recent runs are current without polling on a timer.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    /// Load the bundled menu bar glyph and mark it as a template so macOS
    /// inverts it automatically for light/dark menu bars. We grab the @2x
    /// asset explicitly because `NSImage(named:)` is unreliable for
    /// unscaled PNGs, and through `Bundle.main` because the app bundler
    /// copies these straight into `Contents/Resources`.
    private static func menuBarImage() -> NSImage {
        let bundle = Bundle.main
        let candidates = ["MenuBarIcon@2x", "MenuBarIcon@3x", "MenuBarIcon"]
        for name in candidates {
            let url = bundle.url(forResource: name, withExtension: "png")
            if let url, let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                return image
            }
        }
        let fallback = NSImage(systemSymbolName: "bolt.horizontal.circle",
                               accessibilityDescription: "Machook") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    private func refreshMenu() {
        guard menu != nil else { return }
        menu.removeAllItems()

        let config = AppConfigStore.shared.current

        // A dead listener outranks everything else here: no endpoint and no
        // tunnel can work until it's resolved, and the only other symptom is
        // silence.
        if let serverError = ServerStatus.shared.lastError {
            let item = NSMenuItem.titled("⚠ \(serverError)")
            item.toolTip = serverError
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Landing on the fallback is a success, but a silent one: the port
        // in front of you is not the port in Settings.
        if let bound = boundPort, bound != config.localAPIPort {
            let item = NSMenuItem.titled("Listening on \(bound) — port \(config.localAPIPort) was busy")
            item.toolTip = "Machook fell back to its secondary port."
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let tunnelLine: String
        if let url = tunnel?.publicURL, !url.isEmpty {
            tunnelLine = url
        } else if config.tunnelEnabled {
            tunnelLine = "Tunnel: connecting…"
        } else {
            tunnelLine = "Tunnel: off (localhost:\(boundPort ?? config.localAPIPort))"
        }
        let tunnelItem = NSMenuItem.titled(tunnelLine)
        if let url = tunnel?.publicURL, !url.isEmpty {
            tunnelItem.target = self
            tunnelItem.action = #selector(copyTunnelURL)
            tunnelItem.isEnabled = true
            tunnelItem.toolTip = "Click to copy"
        }
        menu.addItem(tunnelItem)

        menu.addItem(.separator())

        let enabled = config.endpoints.filter(\.enabled)
        if config.endpoints.isEmpty {
            menu.addItem(.titled("No endpoints yet — open Settings"))
        } else {
            let toolCount = config.mcpTools().count
            menu.addItem(.titled("\(enabled.count) endpoint\(enabled.count == 1 ? "" : "s"), \(toolCount) MCP tool\(toolCount == 1 ? "" : "s")"))
            for rule in enabled.prefix(8) {
                let item = NSMenuItem.titled("   \(rule.path)")
                item.toolTip = rule.command
                menu.addItem(item)
            }
            if enabled.count > 8 {
                menu.addItem(.titled("   … and \(enabled.count - 8) more"))
            }
        }

        let recent = ExecutionLog.shared.entries.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.titled("Recent"))
            for entry in recent {
                let glyph = entry.succeeded ? "✓" : "✗"
                let title = "   \(glyph) \(entry.label) · \(entry.statusCode) · \(entry.durationMs)ms"
                let item = NSMenuItem.titled(title)
                if !entry.outputHead.isEmpty { item.toolTip = entry.outputHead }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(.action("Settings…", target: self, action: #selector(openSettings), key: ","))
        menu.addItem(.action("Restart tunnel", target: self, action: #selector(restartTunnel), key: "t"))
        menu.addItem(.separator())
        menu.addItem(.action("Check for updates…", target: self, action: #selector(checkUpdates), key: ""))
        menu.addItem(.action("Quit Machook", target: self, action: #selector(quit), key: "q"))
    }

    @objc private func copyTunnelURL() {
        guard let url = tunnel?.publicURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let win = NSWindow(contentViewController: host)
            win.title = "Machook"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func restartTunnel() {
        tunnel?.stop()
        guard AppConfigStore.shared.current.tunnelEnabled else { return }
        guard let boundPort else {
            // There is nothing to expose yet. The menu already carries the
            // bind error, so don't stack a tunnel failure on top of it.
            Log.tunnel.notice("tunnel restart requested while the listener is down; ignoring")
            refreshMenu()
            return
        }
        startTunnel(port: boundPort)
    }

    @objc private func checkUpdates() {
        updater?.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuItem ergonomics

private extension NSMenuItem {
    static func titled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func action(_ title: String, target: AnyObject, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}

public extension Foundation.Notification.Name {
    /// Posted by helper code that wants the Settings window opened (e.g.
    /// the named-tunnel misconfigured alert).
    static let machookOpenSettings = Foundation.Notification.Name("Machook.openSettings")
}
