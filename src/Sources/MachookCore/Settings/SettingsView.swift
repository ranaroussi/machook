import SwiftUI
import AppKit
import ServiceManagement

@MainActor
public struct SettingsView: View {
    @State private var config: AppConfig = AppConfigStore.shared.current
    @ObservedObject private var tunnelStatus = TunnelStatus.shared
    @ObservedObject private var serverStatus = ServerStatus.shared
    @ObservedObject private var log = ExecutionLog.shared

    @State private var editing: EndpointRule?
    @State private var justSaved = false
    @State private var copied = false
    @State private var saveProblem: String?
    @State private var confirmUnauthenticatedTunnel = false
    @State private var showAdvanced = false
    @State private var launchOnLogin: Bool = SMAppService.mainApp.status == .enabled

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            TabView {
                endpointsTab.tabItem { Label("Endpoints", systemImage: "list.bullet.rectangle") }
                tunnelTab.tabItem    { Label("Tunnel",    systemImage: "globe") }
                generalTab.tabItem   { Label("General",   systemImage: "gear") }
            }
            .padding(12)

            Divider()
            saveBar
        }
        .frame(width: 680, height: 620)
        .onReceive(NotificationCenter.default.publisher(for: AppConfigStore.didChangeNotification)) { _ in
            config = AppConfigStore.shared.current
        }
        .sheet(item: $editing) { rule in
            EndpointEditorView(rule: rule) { updated in
                if let index = config.endpoints.firstIndex(where: { $0.id == updated.id }) {
                    config.endpoints[index] = updated
                } else {
                    config.endpoints.append(updated)
                }
            }
        }
        .alert("Publish endpoints without a token?", isPresented: $confirmUnauthenticatedTunnel) {
            Button("Cancel", role: .cancel) {}
            Button("Publish anyway", role: .destructive) { commit() }
        } message: {
            Text("""
            The tunnel is enabled but the bearer token is empty, so anyone \
            who learns the URL can run your commands on this Mac. Set a \
            token unless you are only testing.
            """)
        }
    }

    // MARK: - Endpoints

    private var endpointsTab: some View {
        tabScroll {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Endpoints")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button {
                        editing = EndpointRule(path: "", command: "")
                    } label: {
                        Label("Add endpoint", systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                sectionCard {
                    if config.endpoints.isEmpty {
                        emptyEndpointsState
                    } else {
                        ForEach(Array(config.endpoints.enumerated()), id: \.element.id) { index, _ in
                            if index > 0 { rowDivider }
                            endpointRow(index)
                        }
                    }
                }

                Text("""
                Each path runs its command with `{{request}}` replaced by a JSON \
                file holding the method, path, query, headers, and body. \
                stdout becomes the response.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyEndpointsState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No endpoints yet")
                .font(.callout)
            Text("Add one to map a URL path to a shell command.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private func endpointRow(_ index: Int) -> some View {
        let rule = config.endpoints[index]
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $config.endpoints[index].enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.path.isEmpty ? "(no path)" : rule.path)
                        .font(.body.monospaced())
                    if !rule.methods.isEmpty {
                        tag(rule.methods.joined(separator: " · "))
                    }
                    if rule.mcpEnabled {
                        tag("MCP")
                    }
                    if rule.mcpReadOnly {
                        tag("read-only")
                    }
                }
                Text(rule.command.isEmpty ? "(no command)" : rule.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let problem = rule.validationError() {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let base = tunnelStatus.publicURL, !base.isEmpty {
                    HStack(spacing: 4) {
                        Text(base + rule.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            copyToClipboard(base + rule.path)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help("Copy URL")
                    }
                }
            }

            Spacer(minLength: 8)

            Button("Edit") { editing = rule }
                .controlSize(.small)
            Button {
                config.endpoints.removeAll { $0.id == rule.id }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Delete endpoint")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(NSColor.quaternaryLabelColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .foregroundStyle(.secondary)
    }

    // MARK: - Tunnel

    private var tunnelTab: some View {
        tabScroll {
            section("Auth") {
                row("Bearer token",
                    help: "Required on every route except /health, and on MCP calls. Leave blank only for localhost testing.") {
                    SecureField("shared secret", text: $config.bearerToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }

            if config.tunnelEnabled && config.bearerToken.trimmingCharacters(in: .whitespaces).isEmpty {
                warningCard("""
                The tunnel is on with no bearer token. Anyone who learns the \
                URL can run your commands.
                """)
            }

            section("Cloudflare Tunnel") {
                row("Enable tunnel",
                    help: "Runs cloudflared so your endpoints are reachable from anywhere.") {
                    Toggle("", isOn: $config.tunnelEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                rowDivider
                row("Mode",
                    help: "Free gives a random URL that rotates on restart. Named uses a hostname you own.") {
                    Picker("", selection: $config.tunnelMode) {
                        Text("Free (trycloudflare.com)").tag(TunnelMode.quick)
                        Text("Named (custom domain)").tag(TunnelMode.named)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                .disabled(!config.tunnelEnabled)

                if config.tunnelMode == .named {
                    rowDivider
                    row("Tunnel token",
                        help: "The eyJh… connector token from the Zero Trust dashboard.") {
                        SecureField("eyJh…", text: $config.tunnelToken)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                    rowDivider
                    row("Public hostname",
                        help: "Bare host, no scheme. Must route to localhost:\(config.localAPIPort) in Cloudflare.") {
                        TextField("hooks.yourcompany.com", text: $config.tunnelHostname)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                } else if config.tunnelEnabled {
                    rowDivider
                    row("Public URL") {
                        if let url = tunnelStatus.publicURL, !url.isEmpty {
                            HStack(spacing: 6) {
                                Text(url)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Button(copied ? "Copied" : "Copy") { copyToClipboard(url) }
                                    .controlSize(.small)
                            }
                        } else {
                            Text("Connecting…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            section("MCP") {
                row("Expose endpoints as MCP tools",
                    help: "Serves POST /mcp on the same URL and token. Individual endpoints opt in when you edit them.") {
                    Toggle("", isOn: $config.mcpEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if config.mcpEnabled {
                    rowDivider
                    row("Tools published") {
                        Text("\(config.mcpTools().count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // A failed bind is invisible everywhere else in this window: the
            // tunnel can be green and every endpoint valid while nothing is
            // listening, so say it next to the control that fixes it.
            if let serverError = serverStatus.lastError {
                warningCard(serverError)
            } else if serverStatus.isListening, serverStatus.port != config.localAPIPort {
                // Falling back worked, which is exactly why it needs saying:
                // the port in this window is not the port serving requests.
                warningCard("""
                Port \(config.localAPIPort) was busy, so Machook is listening on \
                \(serverStatus.port) instead. A named tunnel pointed at \
                \(config.localAPIPort) will not reach it.
                """)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                sectionCard {
                    row("Local API port",
                        help: "Where the HTTP server listens. Must match the tunnel's target.") {
                        stepperField(value: $config.localAPIPort, range: 1024...65535, width: 80)
                    }
                    rowDivider
                    row("Fallback port",
                        help: "Tried when the port above is already taken. Set to 0 to insist on the primary port and report a failure instead.") {
                        stepperField(value: $config.fallbackAPIPort, range: 0...65535, width: 80)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced")
                    .font(.callout.weight(.semibold))
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        tabScroll {
            section("Execution") {
                row("Shell",
                    help: "Interprets each endpoint's command.") {
                    TextField("/bin/zsh", text: $config.shellPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                rowDivider
                row("Login shell",
                    help: "Loads your profile so Homebrew and pyenv paths resolve. Turn off for a faster start if your commands use absolute paths.") {
                    Toggle("", isOn: $config.loginShell)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                rowDivider
                row("Max concurrent commands",
                    help: "Requests beyond this get 503 instead of piling up.") {
                    stepperField(value: $config.maxConcurrentRuns, range: 1...64, width: 70)
                }
                rowDivider
                row("Max captured output (KB)",
                    help: "Output past this is discarded, though the command still runs to completion.") {
                    stepperField(value: $config.maxOutputKB, range: 1...102_400, width: 90)
                }
                rowDivider
                row("Max request body (MB)") {
                    stepperField(value: $config.maxBodyMB, range: 1...1024, width: 70)
                }
                rowDivider
                row("Keep request files",
                    help: "Leaves each {{request}} file on disk after the command exits. Useful while writing a script; off by default because payloads carry secrets.") {
                    Toggle("", isOn: $config.keepRequestFiles)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            section("Startup") {
                row("Launch at login") {
                    Toggle("", isOn: $launchOnLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchOnLogin) { _, newValue in
                            setLaunchAtLogin(newValue)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recent runs")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if !log.entries.isEmpty {
                        Button("Clear") { log.clear() }
                            .controlSize(.small)
                    }
                }
                sectionCard {
                    if log.entries.isEmpty {
                        Text("Nothing has run yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        ForEach(Array(log.entries.prefix(12).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { rowDivider }
                            HStack(spacing: 8) {
                                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(entry.succeeded ? .green : .red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(entry.label)  ·  \(entry.source)")
                                        .font(.caption.monospaced())
                                    if !entry.outputHead.isEmpty {
                                        Text(entry.outputHead)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text("\(entry.statusCode) · \(entry.durationMs)ms")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                    }
                }
            }

            section("About") {
                row("Version") {
                    Text("\(Self.shortVersion()) (\(Self.buildNumber()))")
                        .foregroundStyle(.secondary)
                }
                rowDivider
                row("Bundle identifier") {
                    Text(Bundle.main.bundleIdentifier ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack(spacing: 10) {
            if let saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if justSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Revert") {
                config = AppConfigStore.shared.current
                saveProblem = nil
            }
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func save() {
        // Normalize first so "ep1" and "/ep1/" collapse before we look
        // for duplicates.
        for index in config.endpoints.indices {
            config.endpoints[index].path = EndpointRule.normalizePath(config.endpoints[index].path)
        }

        if let broken = config.endpoints.first(where: { $0.validationError() != nil }) {
            saveProblem = "\(broken.path.isEmpty ? "An endpoint" : broken.path): \(broken.validationError() ?? "")"
            return
        }

        var seen = Set<String>()
        for rule in config.endpoints {
            if !seen.insert(rule.path).inserted {
                saveProblem = "Two endpoints both claim \(rule.path)"
                return
            }
        }

        saveProblem = nil

        if config.tunnelEnabled, config.bearerToken.trimmingCharacters(in: .whitespaces).isEmpty {
            confirmUnauthenticatedTunnel = true
            return
        }
        commit()
    }

    private func commit() {
        let next = config
        AppConfigStore.shared.update { $0 = next }
        justSaved = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            justSaved = false
        }
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }

    /// Registers or removes the login item, reverting the toggle when the
    /// system refuses so the UI never drifts from actual state.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            launchOnLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Layout building blocks

    @ViewBuilder
    private func tabScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            sectionCard(content)
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func warningCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func row<Trailing: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var rowDivider: some View {
        Divider().padding(.leading, 12)
    }

    @ViewBuilder
    private func stepperField(value: Binding<Int>, range: ClosedRange<Int>, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .onChange(of: value.wrappedValue) { _, newValue in
                    if newValue < range.lowerBound {
                        value.wrappedValue = range.lowerBound
                    } else if newValue > range.upperBound {
                        value.wrappedValue = range.upperBound
                    }
                }
            Stepper("", value: value, in: range).labelsHidden()
        }
    }

    private static func shortVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static func buildNumber() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
