import SwiftUI
import AppKit

/// Add/edit sheet for a single endpoint, with a Test button that runs the
/// draft command right here — before it is saved, and before anything on
/// the internet can reach it.
@MainActor
struct EndpointEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: EndpointRule
    @State private var testing = false
    @State private var testOutput: String?
    @State private var testFailed = false

    private let onSave: (EndpointRule) -> Void

    private static let selectableMethods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    init(rule: EndpointRule, onSave: @escaping (EndpointRule) -> Void) {
        self._draft = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    requestSection
                    commandSection
                    mcpSection
                    if let testOutput {
                        testResultSection(testOutput)
                    }
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 600)
    }

    // MARK: - Sections

    private var requestSection: some View {
        section("Request") {
            field("Path", help: "The URL path this endpoint answers on.") {
                TextField("/deploy", text: $draft.path)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            field("Methods", help: "Leave all off to accept any method.") {
                HStack(spacing: 6) {
                    ForEach(Self.selectableMethods, id: \.self) { method in
                        Toggle(method, isOn: methodBinding(method))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                }
            }
            field("Description", help: "Shown in Settings, and read by AI clients as the MCP tool description.") {
                TextField("Deploys the site from main", text: $draft.toolDescription)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var commandSection: some View {
        section("Command") {
            field("Run", help: "{{request}} is replaced with the path of a JSON file holding the method, path, query, headers, and body. Don't quote it — Machook quotes it for you.") {
                TextEditor(text: $draft.command)
                    .font(.body.monospaced())
                    .frame(height: 60)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
            }
            field("Working directory", help: "Blank runs in your home folder.") {
                HStack(spacing: 6) {
                    TextField("~/projects/site", text: $draft.workingDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button("Pick…") { pickWorkingDirectory() }
                        .controlSize(.small)
                }
            }
            field("Timeout", help: "The command gets SIGTERM at this point, SIGKILL two seconds later.") {
                HStack(spacing: 6) {
                    TextField("", value: $draft.timeoutSeconds, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("seconds").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var mcpSection: some View {
        section("MCP") {
            field("Expose as a tool", help: "Off for provider-driven hooks an agent should not be calling.") {
                Toggle("", isOn: $draft.mcpEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if draft.mcpEnabled {
                field("Tool name", help: "Blank derives it from the path.") {
                    TextField(EndpointRule.deriveToolName(fromPath: EndpointRule.normalizePath(draft.path)),
                              text: $draft.mcpToolName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                field("Read-only", help: "Only for endpoints that just report something. Left off, MCP clients treat the tool as potentially destructive and may ask before running it — the right default for a shell command.") {
                    Toggle("", isOn: $draft.mcpReadOnly)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                field("Argument schema", help: "Optional JSON Schema describing the arguments. Blank accepts any JSON object, which arrives as the request body.") {
                    TextEditor(text: $draft.mcpInputSchema)
                        .font(.caption.monospaced())
                        .frame(height: 70)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                }
            }
        }
    }

    private func testResultSection(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: testFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(testFailed ? .red : .green)
                Text("Test result")
                    .font(.callout.weight(.semibold))
            }
            ScrollView {
                Text(output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 110)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem = draft.validationError() {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Test") { runTest() }
                .disabled(testing || draft.validationError() != nil)
            Button("Cancel") { dismiss() }
            Button("Done") {
                var normalized = draft
                normalized.path = EndpointRule.normalizePath(normalized.path)
                onSave(normalized)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.validationError() != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    /// Runs the draft command with an empty JSON body so the script's own
    /// happy path is exercised without waiting for a real webhook.
    private func runTest() {
        testing = true
        testOutput = "Running…"
        var rule = draft
        rule.path = EndpointRule.normalizePath(rule.path)

        Task {
            let envelope = RequestEnvelope(
                source: "test",
                method: "TEST",
                path: rule.path,
                body: Data("{}".utf8)
            )
            do {
                let result = try await CommandRunner.shared.run(
                    rule: rule,
                    envelope: envelope,
                    config: AppConfigStore.shared.current
                )
                var lines = ["exit \(result.exitCode) · \(result.durationMs) ms"]
                if result.timedOut { lines.append("TIMED OUT") }
                if !result.stdoutText.isEmpty { lines.append("--- stdout ---\n" + result.stdoutText) }
                if !result.stderrText.isEmpty { lines.append("--- stderr ---\n" + result.stderrText) }
                if result.stdout.isEmpty && result.stderr.isEmpty { lines.append("(no output)") }
                testFailed = !result.succeeded
                testOutput = lines.joined(separator: "\n")
            } catch {
                testFailed = true
                testOutput = error.localizedDescription
            }
            testing = false
        }
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            draft.workingDirectory = url.path
        }
    }

    private func methodBinding(_ method: String) -> Binding<Bool> {
        Binding(
            get: { draft.methods.contains(method) },
            set: { isOn in
                if isOn {
                    if !draft.methods.contains(method) { draft.methods.append(method) }
                } else {
                    draft.methods.removeAll { $0 == method }
                }
            }
        )
    }

    // MARK: - Layout

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
            content()
            if let help {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
