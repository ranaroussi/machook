# Architecture

A technical deep-dive into how Machook is wired together.

If you're trying to **use** the app, see [`README.md`](../README.md).
If you're trying to **test** it, see [`TESTING.md`](../TESTING.md).
If something's misbehaving, see [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
If you're cutting a release, see [`docs/DISTRIBUTION.md`](DISTRIBUTION.md).

---

## 1. Top-level shape

Machook is one macOS menu bar app and nothing else. `LSUIElement` is
`true` in `src/Info.plist`, so there is no Dock icon and no window until
you open Settings. [`src/Sources/Machook/main.swift`](../src/Sources/Machook/main.swift)
is a bare `NSApplicationMain` — **no CLI flags, no `--mcp` mode, no
headless branch**. Everything remote arrives over one HTTP listener,
whether it is a webhook POST or an MCP `tools/call`.

| Surface | Where it enters | What it ends up doing |
|---------|-----------------|-----------------------|
| Webhook / plain HTTP | `POST https://<tunnel>/deploy` | `LocalAPIServer.dispatch` → `CommandRunner.run` |
| MCP tool call | `POST https://<tunnel>/mcp` (`tools/call`) | `MCPService.call` → `CommandRunner.run` |
| Settings "Test" button | `EndpointEditorView.runTest()` | `CommandRunner.run` on the unsaved draft |

All three converge on a single `CommandRunner.run(rule:envelope:config:)`.
There is exactly one place a command can be spawned, which is also the
only place the timeout, the output cap, and the concurrency budget are
enforced.

**Machook requires no macOS permissions.** It reads no protected data,
scripts no other app, and touches no TCC-guarded resource. There is no
Full Disk Access probe, no Automation prompt, no Contacts access, and
no permission gate anywhere in the boot path — `AppDelegate.bootRuntime()`
says so out loud. The only thing that can fail at startup is binding the
port.

---

## 2. Layout

```
src/
├── Package.swift                  # Machook (exe) + MachookCore (lib) + tests
├── Info.plist                     # LSUIElement, Sparkle feed, bundle id
├── Sources/
│   ├── Machook/
│   │   ├── main.swift             # NSApplicationMain, nothing else
│   │   └── Resources/             # AppIcon.icns, MenuBarIcon*.png, cloudflared (release)
│   └── MachookCore/
│       ├── AppConfig.swift        # AppConfig, AppConfigStore, TunnelMode
│       ├── AppDelegate.swift      # Menu bar, boot sequence, service restarts
│       ├── Log.swift              # os.Logger categories
│       ├── API/
│       │   ├── LocalAPIServer.swift   # Hummingbird routes, dispatch, auth, response mapping
│       │   └── ServerStatus.swift     # Observable listener state incl. bind failures
│       ├── Endpoints/
│       │   ├── EndpointRule.swift     # One endpoint: path, command, validation, tool name
│       │   ├── ShellQuote.swift       # The security boundary
│       │   ├── CommandTemplate.swift  # {{request}} substitution
│       │   ├── RequestEnvelope.swift  # The JSON envelope + staging directory
│       │   ├── CommandRunner.swift    # Spawn, drain, timeout, cap, concurrency
│       │   └── ExecutionLog.swift     # In-memory ring buffer of recent runs
│       ├── MCP/
│       │   └── MCPService.swift       # Tool catalog + tools/call
│       ├── Settings/
│       │   ├── SettingsView.swift     # Endpoints / Tunnel / General tabs
│       │   └── EndpointEditorView.swift # Add-edit sheet with a Test button
│       └── Tunnel/
│           ├── TunnelManager.swift    # cloudflared supervisor
│           └── TunnelStatus.swift     # @MainActor ObservableObject for SwiftUI
└── Tests/MachookCoreTests/
    ├── TemplateAndQuotingTests.swift  # Quoting, templates, rules, config, envelope
    └── CommandRunnerTests.swift       # Real shells: output, timeout, caps, injection
```

### Why the target split

`Package.swift` deliberately keeps the executable thin and puts every
interesting behaviour in the `MachookCore` library, because a test target
cannot reliably link an executable target's `main.swift` on macOS. The
consequence is worth stating: the shell-quoting boundary, the template
renderer, and the process runner are all reachable from `swift test`
without launching an app.

Platform floor is macOS 14; `swift-tools-version: 6.0` means the package
builds in Swift 6 language mode, so strict concurrency checking applies
to everything below.

---

## 3. Concurrency model

| Isolation | Owners |
|-----------|--------|
| `@MainActor` | `AppDelegate`, `SettingsView`, `EndpointEditorView`, `TunnelStatus`, `ServerStatus`, `ExecutionLog` |
| `final class @unchecked Sendable` + `NSLock` | `AppConfigStore`, `CommandRunner` (and its `SlotCounter`, `RunState`), `TunnelManager` (and its `Resolver`), `LocalAPIServer` |
| Detached `Task` | The Hummingbird `Application.runService()` loop |
| `DispatchQueue.global(qos: .userInitiated)` | The blocking spawn/drain/wait in `CommandRunner.execute`, plus one drain queue per pipe |
| `Sendable` values | `AppConfig`, `EndpointRule`, `RequestEnvelope`, `CommandResult`, `TunnelMode` |

Two patterns are worth calling out because they look like smells and
aren't:

- **`NSLock` behind synchronous methods.** `CommandRunner`'s slot counter
  exposes `acquire(limit:)` / `release()` rather than locking inline,
  because `NSLock.lock()` cannot be called directly inside an `async`
  function — the compiler cannot prove we never suspend while holding it.
- **`Box<T>` wrappers.** `Process` and `FileHandle` are not `Sendable`,
  so they are carried into dispatch closures inside a small
  `@unchecked Sendable` box. Each boxed handle is touched by exactly one
  thread, which is what makes the `@unchecked` honest.

Observable state crosses back to the UI through `Task { @MainActor in … }`
hops (`TunnelStatus`, `ServerStatus`, `ExecutionLog.post`). Nothing in the
runtime holds a reference to the UI.

---

## 4. Boot sequence

```
NSApplicationMain
   │
   ▼
AppDelegate.applicationDidFinishLaunching
   │
   ├── SUPublicEDKey present in Info.plist?
   │      ├── yes → SPUStandardUpdaterController(startingUpdater: true)
   │      └── no  → skip Sparkle entirely (it aborts hard on a missing key)
   │
   ├── installMainMenu()   → NSApp.mainMenu with App + Edit submenus
   ├── setupMenuBar()      → NSStatusItem + NSMenu (delegate = self)
   └── bootRuntime()
        │
        ├── RequestEnvelope.sweepStagingDirectory()   # drop envelopes >6h old
        ├── TunnelManager()
        ├── LocalAPIServer(ports: config.listenPortCandidates(), tunnel:)
        ├── api.start { port in listenerDidBind(port:) }   # detached Task
        │      └── tries each candidate port in order; the tunnel is
        │          started from this callback, never before it
        ├── lastSnapshot = snapshot(of: config)
        └── refreshMenu()
   │
   └── observers: AppConfigStore.didChangeNotification → configChanged
                  .machookOpenSettings                → openSettings
```

There is no permission gate in that sequence, by design. The sweep runs
first because a crash or force-quit between writing an envelope and the
`defer` that deletes it leaves a payload on disk; six hours is long
enough that no in-flight request is affected.

### Which port, and who gets told

`listenPortCandidates()` returns `[localAPIPort, fallbackAPIPort]` with
zeros, out-of-range values, and duplicates removed. The listener tries them
in order and Hummingbird's `onServerRunning` callback is the only signal
that counts as success — the port is not known to have worked until that
fires.

Two rules fall out of it:

- **Retry only before serving.** A candidate is abandoned for the next one
  only when it never reached "running" *and* the error is `EADDRINUSE`. A
  listener that has served traffic and then falls over is reported, not
  relocated: moving it would silently change the address the tunnel and
  every configured sender are pointing at.
- **The tunnel follows the bind, not the config.** `startTunnel(port:)` is
  called from the bind callback with the port that actually bound, so a
  fallback cannot leave cloudflared forwarding to a dead port. If nothing
  binds, no tunnel starts at all.

Landing on the fallback is a quiet success, which is its own hazard: the
port in Settings is not the port serving requests. So it is stated in the
menu (`Listening on 7877 — port 7876 was busy`), in the Tunnel tab as a
warning card, and in `/status`, which reports `local_api_port` (the port
serving requests) alongside `configured_api_port` (the one in Settings).
Those two differing is the machine-readable signal that the fallback is
in use.

### Restarting the right thing on Save

`configChanged` keeps a `ServiceSnapshot` of exactly five fields —
`tunnelEnabled`, `tunnelMode`, `tunnelToken`, `tunnelHostname`, `ports` —
and diffs it on every notification. Saving an edit that touched none of
them (a command, a timeout, a bearer token, an MCP toggle) leaves the
listener and the tunnel alone:

| Changed | Effect |
|---------|--------|
| Nothing in the snapshot | Menu refresh only |
| Either port | `api.stop()`, `tunnel.stop()`, new `LocalAPIServer` on the new candidates; the bind callback then restarts the tunnel |
| Any tunnel field | `tunnel.stop()` then `startTunnel(port:)` against the bound port if still enabled |
| Endpoint table, execution limits, bearer token | Nothing to restart — read live per request |

---

## 5. The request lifecycle

Endpoints are **not** registered as routes at boot. One catch-all
`/**` handler per method resolves the path against the live config on
every request, so an endpoint added in Settings answers the next request
with no restart.

```
HTTP request on 127.0.0.1:<port>   (or through cloudflared)
   │
   ▼ BearerAuthMiddleware
   ├── path == "/health" → pass through unauthenticated
   ├── configured token empty → pass through (localhost dev only)
   └── constant-time compare of `Authorization` against "Bearer <token>"
         └── mismatch → 401 + WWW-Authenticate: Bearer
   │
   ▼ Router
   ├── GET  /health → {"ok":true}
   ├── GET  /status → runtime snapshot JSON
   ├── POST /mcp    → MCPService.handleStatelessHTTPRequest
   └── GET|POST|PUT|PATCH|DELETE /** → dispatch
        │
        ├── normalizePath(uri.path)
        ├── config.rule(forPath:)            → nil?
        │     ├── config.anyRule(forPath:) hit → 503 "Endpoint /x is disabled"
        │     └── otherwise                    → 404 "No endpoint configured for /x"
        ├── rule.accepts(method:)            → 405 "/x accepts POST, GET"
        ├── rule.validationError()           → 500 "Endpoint misconfigured: …"
        ├── req.body.collect(upTo: maxBodyMB) → 413 "Request body exceeds N MB"
        ├── collect query params
        ├── collect headers, dropping `Authorization`
        ├── RequestEnvelope(source: "http", method:, path:, query:, headers:, body:)
        │
        ▼ CommandRunner.run
        ├── claim a concurrency slot        → 503 "Too many commands already running (limit N)"
        ├── envelope.write()                → $TMPDIR/machook/requests/<epoch-ms>-<id8>.json
        ├── CommandTemplate.render(command, envelopePath:)  → 500 on a bad placeholder
        ├── spawn `<shell> -lc "<rendered command>"`
        ├── drain stdout + stderr concurrently, capped
        ├── wait, with SIGTERM/SIGKILL on timeout
        └── defer: delete the envelope (unless "Keep request files")
        │
        ▼ LocalAPIServer.response(for:)
        └── exit code + stdout → status, body, headers
```

### Response mapping

| Outcome | Status | Body |
|---------|--------|------|
| exit 0, stdout non-empty | `200` | stdout verbatim, `Content-Type` sniffed |
| exit 0, stdout empty | `200` | `{"ok":true,"exit_code":0,"duration_ms":15}` |
| non-zero exit | `500` | `{"error":"Command exited 7","stderr":"bad\n","exit_code":7}` |
| timed out | `504` | `{"error":"Command timed out after 1022 ms","exit_code":15,"stderr":"…"}` |
| at concurrency capacity | `503` | `{"error":"Too many commands already running (limit 4)"}` |
| unknown path | `404` | `{"error":"No endpoint configured for /nope"}` |
| known path, wrong verb | `405` | `{"error":"/ep2 accepts POST, GET"}` |
| endpoint switched off | `503` | `{"error":"Endpoint /off is disabled"}` |
| missing/bad token | `401` | `{"error":"Missing or invalid bearer token. Send: Authorization: Bearer <token>"}` |

Every endpoint response also carries:

| Header | Meaning |
|--------|---------|
| `X-Machook-Exit-Code` | The child's exit status |
| `X-Machook-Duration-Ms` | Wall-clock time from spawn to reap |
| `X-Machook-Truncated: true` | Present only when stdout or stderr hit the output cap |

Two mapping decisions that are easy to misread:

- **Empty stdout gets a synthetic JSON body.** A command like `say hi`
  succeeds and prints nothing; an empty `200` tells the caller almost
  nothing, so a small `{"ok":true,…}` summary is substituted.
- **Content-Type is sniffed, not declared.** `sniffContentType` parses
  the bytes: valid JSON starting with `{` or `[` → `application/json`,
  otherwise valid UTF-8 → `text/plain; charset=utf-8`, otherwise
  `application/octet-stream`. A script that echoes JSON gets the right
  header without configuring anything.

Error bodies are serialized `withoutEscapingSlashes`, because these
messages quote endpoint paths and `"\/deploy"` reads like a typo.

### `GET /status`

```json
{
  "ok": true,
  "version": "0.1.0",
  "tunnel_url": "https://example.trycloudflare.com",
  "tunnel_running": true,
  "local_api_port": 7876,
  "configured_api_port": 7876,
  "endpoints_total": 6,
  "endpoints_enabled": 5,
  "mcp_enabled": true,
  "mcp_tools": 4,
  "active_runs": 0
}
```

`version` comes from `CFBundleShortVersionString`, so a binary run
straight out of `.build` (no Info.plist) reports `0.0.0`.

---

## 6. The security model

Machook publishes a shell to the internet on purpose. Four things keep
that from being reckless, and they are the parts to review first when
changing anything.

### 6.1 One bearer token in front of everything

`BearerAuthMiddleware` runs as router middleware, i.e. **before** route
matching. That ordering is deliberate: an unauthenticated caller cannot
probe which paths exist, because a wrong token on `/whatever` returns
`401` rather than `404`.

`/health` is the single exemption, so an uptime checker doesn't need the
secret. The comparison is constant-time (`constantTimeEqual`) — length
still leaks, which no comparison can avoid, but a byte-at-a-time oracle
does not. An empty configured token disables auth entirely, which is only
sane on localhost; `SettingsView.save()` refuses to pair that with an
enabled tunnel silently and makes you confirm a destructive-styled alert
first.

### 6.2 The shell-quoting invariant

> **The command template from Settings is the only string the shell ever
> parses. Everything that arrives from the network reaches the command as
> a single-quoted argv element or as a file path.**

`ShellQuote.quote(_:)` wraps a value in single quotes and rewrites any
embedded `'` as `'\''` — inside single quotes a POSIX shell interprets
nothing at all, and that three-character dance closes the quote, emits a
literal one, and reopens. A value made only of
`[A-Za-z0-9_-./]` skips quoting for log readability; `=` and `~` are
deliberately excluded from that inert set because zsh performs
`=command` and tilde expansion on them.

`CommandTemplate.render` substitutes `{{request}}` with the quoted
envelope path and rejects every other `{{…}}` placeholder. Passing an
unknown placeholder through literally would hand a script the text
`{{request.body.id}}`, which is miserable to debug, so it fails loudly at
save time (`EndpointRule.validationError`, which also keeps the editor's
Done button disabled) and again on every request, where the same
re-validation answers `500 Endpoint misconfigured: …` before anything is
spawned. `CommandRunError.badTemplate` is the runner's backstop for the
same condition. A matched pair of quotes around
the placeholder is absorbed (`cat "{{request}}"` renders correctly),
while an unmatched quote is left alone because it belongs to the user's
own string.

The practical consequence: a body of
`$(touch /tmp/machook-pwned); ` + backtick-`id` lands in the envelope as
data and creates nothing. There is a unit test asserting exactly that
(`testShellMetacharactersInPayloadDoNotExecute`).

### 6.3 Payloads travel as a file, not as arguments

Request data never appears on the command line at all. It is written to
one JSON file per request and the script is handed the path:

| Property | Value | Why |
|----------|-------|-----|
| Directory | `$TMPDIR/machook/requests/`, mode `0700` | The per-user temp dir, not `/tmp` — `/tmp` is world-readable and webhook payloads routinely carry tokens, signatures, and personal data |
| Filename | `<epoch-ms>-<id8>.json` | The millisecond stamp reads well; the request id prevents two webhooks landing in the same millisecond from reading each other's payload |
| File mode | `0600`, applied after the write | `.write(options: .atomic)` writes-then-renames, and the rename does not inherit the mode we asked for |
| Lifetime | Deleted in a `defer` once the command exits | Unless "Keep request files" is on, in which case the path is logged instead |
| Also exposed as | `MACHOOK_REQUEST_FILE` env var | So a script that ignores `{{request}}` can still find its payload |
| Stale files | Swept at launch, older than 6 h | Covers a crash between write and `defer` |
| `Authorization` header | Stripped before the envelope is written | The script has no use for our bearer token and it would otherwise be written to disk on every request |

Envelope shape:

| Key | Notes |
|-----|-------|
| `id` | 8 lowercase hex chars, also in the filename |
| `received_at` | ISO 8601 with fractional seconds |
| `source` | `"http"`, `"mcp"`, or `"test"` from the Settings Test button |
| `method` | The HTTP verb; `"MCP"` for a tool call, `"TEST"` from the editor |
| `path` | Normalized endpoint path |
| `query`, `headers` | Flat string maps; header names canonicalized to lowercase |
| `body` | Parsed JSON when the payload parses, else `null` — so `jq .body.x.y` works without a second parse |
| `body_raw` | The payload as text, always present for UTF-8 bodies, so form-encoded and plain-text payloads survive |
| `body_base64` | Replaces `body_raw` when the payload is not valid UTF-8 |
| `body_bytes` | Length in bytes |

It is written pretty-printed with sorted keys and unescaped slashes,
because the file is meant to be opened and `jq`-ed by hand.

### 6.4 Exposure is opt-in and single-channel

The Hummingbird listener binds `127.0.0.1` only —
`.hostname("127.0.0.1", port: port)`. Nothing on the LAN can reach it.
The one path to the internet is the cloudflared child process, which is
off by default. Turning the tunnel off closes the only door.

---

## 7. Configuration

`AppConfig` is a `Codable` struct persisted as JSON in `UserDefaults`
under the key `machook.config.v1`. Because the app uses
`UserDefaults.standard`, the backing domain is the bundle identifier from
`Info.plist`: `com.machook.app`.

`AppConfigStore.shared` is the only accessor: an `NSLock`-guarded cache
plus a write-through to `UserDefaults`, and every `update(_:)` posts
`AppConfigStore.didChangeNotification`. `AppDelegate` and `SettingsView`
both observe it.

`AppConfig.init(from:)` decodes **every field defensively** —
`(try? c.decode(...)) ?? default` per key. That is not laziness: it means
shipping a new toggle can never throw during decode and reset somebody's
whole endpoint table to defaults.

| Field | Default | Notes |
|-------|---------|-------|
| `bearerToken` | `""` | Empty disables auth |
| `localAPIPort` | `7876` | Settings clamps to 1024–65535 |
| `fallbackAPIPort` | `7877` | Tried when the primary is taken; `0` disables it |
| `tunnelEnabled` | `false` | |
| `tunnelMode` | `.quick` | `quick` or `named` |
| `tunnelToken`, `tunnelHostname` | `""` | Named mode needs both |
| `endpoints` | `[]` | The path → command table |
| `mcpEnabled` | `true` | Master switch for `POST /mcp` |
| `maxConcurrentRuns` | `4` | Settings clamps to 1–64 |
| `maxOutputKB` | `1024` | Per stream, per run; clamps to 1–102400 |
| `maxBodyMB` | `10` | Clamps to 1–1024 |
| `keepRequestFiles` | `false` | |
| `shellPath` | `/bin/zsh` | |
| `loginShell` | `true` | |

Per endpoint (`EndpointRule`):

| Field | Default | Notes |
|-------|---------|-------|
| `path` | `""` | Normalized on save and on every lookup |
| `command` | `""` | The only string the shell parses |
| `methods` | `["POST"]` | Empty accepts any method; comparison is case-insensitive |
| `enabled` | `true` | Disabled → `503`, distinguishable from `404` |
| `timeoutSeconds` | `30` | Validated 1–3600 |
| `workingDirectory` | `""` | Empty → `NSHomeDirectory()`; `~` expanded; must exist |
| `toolDescription` | `""` | Doubles as the MCP tool description |
| `mcpEnabled` | `true` | Off for provider-driven hooks an agent shouldn't invoke |
| `mcpToolName` | `""` | Empty derives from the path |
| `mcpInputSchema` | `""` | Must parse as a JSON object if set |
| `mcpReadOnly` | `false` | Adds MCP read-only annotations |

### Path normalization and matching

`EndpointRule.normalizePath` tolerates what people actually paste: a full
URL (they copy the tunnel address out of the menu bar), a missing leading
slash, a trailing slash, a query string, surrounding whitespace. All of
`ep1`, `/ep1/`, `/ep1?token=abc`, and
`https://x.trycloudflare.com/ep1` collapse to `/ep1`.

Matching is **exact after normalization** — no prefixes, no patterns, no
wildcards. That keeps "which command does this URL run?" a question with
exactly one answer. `/health`, `/status`, and `/mcp` are reserved; a rule
claiming one is rejected at save time, because the built-in route would
shadow it anyway.

`rule(forPath:)` returns only enabled rules; `anyRule(forPath:)` ignores
the enabled flag, which is what lets the dispatcher tell "no such
endpoint" apart from "that one is switched off".

---

## 8. The command runner

```swift
process.executableURL = URL(fileURLWithPath: shell)     // config.shellPath
process.arguments     = [loginShell ? "-lc" : "-c", renderedCommand]
process.currentDirectoryURL = URL(fileURLWithPath: rule.effectiveWorkingDirectory)
process.environment   = ProcessInfo.processInfo.environment
                        + ["MACHOOK_REQUEST_FILE": envelopePath]
process.standardInput = FileHandle.nullDevice
```

Six mechanics, each of which exists because of a specific failure:

1. **Login shell by default (`-lc`).** A GUI-launched app inherits a bare
   `PATH`, so without sourcing the profile a Homebrew `python3` or a
   `pyenv` shim simply isn't found. It costs a few hundred milliseconds
   per request, so the toggle exists for setups where every command uses
   absolute paths.
2. **`stdin` is `/dev/null`, never a pipe.** A pipe nobody writes to
   makes a script that calls `cat` or `read` block forever on a
   descriptor that will never deliver anything.
   `testStdinIsClosedSoReadingCommandsDoNotHang` pins this.
3. **stdout and stderr drain concurrently, on two queues.** Reading
   stdout to EOF first deadlocks the moment a chatty script fills the
   64 KB stderr buffer: the child blocks on write and never exits.
4. **The output cap discards, it does not stop reading.** `drain(_:cap:)`
   keeps at most `maxOutputKB` per stream but keeps consuming to EOF,
   for the same reason — stopping early leaves the child blocked on a
   full pipe. The run still completes, and the response gets
   `X-Machook-Truncated: true`.
5. **Timeout escalates SIGTERM → SIGKILL after 2 s.** Only the direct
   child is signalled. `zsh -c` execs a single simple command, so for the
   common one-command template that child *is* the script; a script that
   backgrounds work of its own can still leave a grandchild alive.
   `kill(-pid)` is deliberately **not** used: `Process` puts the child in
   Machook's own process group, so a negative pid would signal Machook
   too.
6. **Pipe drain has its own 3 s ceiling after exit.** Normally both pipes
   hit EOF when the child exits; a grandchild that inherited stdout keeps
   them open, and one stray background process must not hang the HTTP
   request forever. Past the ceiling we log and return partial output.

Concurrency is a counted budget (`SlotCounter`), claimed before the
envelope is written and released in a `defer`. Over capacity the caller
gets `503` immediately rather than the Mac fork-bombing itself when a
webhook provider retries in a loop. `CommandRunner.shared.activeCount`
is what `/status` reports as `active_runs`.

The whole spawn/drain/wait sequence is blocking, so it runs on
`DispatchQueue.global(qos: .userInitiated)` and comes back through
`withCheckedThrowingContinuation`. Keeping it inside one closure is also
what stops the non-`Sendable` `Process` and its pipes from crossing an
isolation boundary.

### Recent runs

`ExecutionLog` is a `@MainActor` ring buffer of the last 100 runs
(source, label, status code, exit code, duration, first line of output
truncated to 120 chars). Both surfaces post to it. It is deliberately
**not** persisted: unlike the outbound relay this app replaced, there is
nothing to retry and nothing to reconcile after a crash, so a SQLite
table would be storage for its own sake. The menu bar shows the last 5,
the Settings General tab the last 12.

---

## 9. MCP

`POST /mcp` speaks MCP JSON-RPC over HTTP using the official Swift SDK.
Every enabled endpoint that opted in is a tool, and a `tools/call`
funnels into the same `CommandRunner` as an HTTP request. The only
difference is what lands in the envelope: HTTP contributes a real body,
headers, and query; a tool call contributes its arguments as `body`,
`method` as `"MCP"`, and `source` as `"mcp"`.

### A fresh Server per request

```swift
let transport = StatelessHTTPServerTransport(validationPipeline: …)
let service = MCPService(transport: transport)
try await service.start()
let response = await transport.handleRequest(request)
await service.stop()
```

`StatelessHTTPServerTransport` does not isolate the SDK `Server` attached
to it, and an SDK `Server` tracks whether it has already initialized. A
shared `Server` therefore fails the *second* client with "Server is
already initialized". Building both per request fixes that and permits
concurrent clients; the cost is a negligible amount of setup next to
spawning a shell. Stateless is the right fit anyway — these tools are all
request/response, so there is no SSE stream to keep open and no
`MCP-Session-Id` for clients to juggle.

### Validation pipeline

| Validator | Setting | Why |
|-----------|---------|-----|
| `OriginValidator` | `.disabled` | The SDK default matches only `127.0.0.1`/`localhost` Host headers, which would block every tunnel request. Access control is the bearer token's job. |
| `AcceptHeaderValidator` | `.jsonOnly` | No SSE surface, so a client must accept `application/json`. `curl` does not send this by default. |
| `ContentTypeValidator` | default | |
| `ProtocolVersionValidator` | default | |

The `/mcp` body is collected `upTo: 1_048_576` bytes — 1 MB, independent
of `maxBodyMB`, which governs endpoint dispatch only. With
`mcpEnabled` off the route answers `404 {"error":"MCP is disabled in Settings"}`.

### The catalog is rebuilt per `tools/list`

`AppConfig.mcpTools()` filters to rules that are enabled, MCP-enabled,
and currently valid, so an endpoint added in Settings appears without a
restart and a broken one disappears instead of failing at call time.

Tool names come from `resolvedToolNames()`: the explicit `mcpToolName`
when set, otherwise derived from the path by dropping the leading slash
and collapsing anything outside `[A-Za-z0-9_-]` to a single `_`
(`/github/push` → `github_push`, `/ep1` → `ep1`, capped at 64 chars).
Collisions get a `_2`, `_3` suffix — two endpoints resolving to the same
name would otherwise make one of them permanently unreachable over MCP.

`tools/call` on a name that isn't in the live catalog returns
`isError: true` with `Unknown tool: <name>`, which is also what an
MCP-disabled endpoint looks like from the client's side.

### Schemas and annotations

An endpoint with no `mcpInputSchema` advertises a freeform object
(`additionalProperties: true`). That is the honest default: the command is
an opaque script, so its parameters cannot be inferred, and any JSON the
model passes still lands in the envelope's `body`.

Annotations are only attached when `mcpReadOnly` is on
(`readOnlyHint`, `destructiveHint: false`, `idempotentHint`,
`openWorldHint: false`). Everything else is left unannotated on purpose:
MCP treats an unannotated tool as potentially destructive, which is
exactly right for a tool that runs an arbitrary shell command. Marking a
reporting-only endpoint read-only is what stops well-behaved clients from
approval-gating it on every call.

### Result mapping

| Outcome | Result |
|---------|--------|
| exit 0, stdout non-empty | `content[0].text` = stdout, `isError: false` |
| exit 0, stdout empty | `{"ok":true,"exit_code":0,"duration_ms":…}` |
| non-zero exit | `isError: true`, `Command exited <n>` + stderr (or stdout when stderr is empty) |
| timed out | `isError: true`, `Command timed out after <n> ms` |
| runner error (capacity, bad template, …) | `isError: true` with the runner's message |

The same runs are recorded in `ExecutionLog` with a synthetic status code
(200/500/504) so the menu bar treats HTTP and MCP traffic identically.

---

## 10. Cloudflare Tunnel supervision

`TunnelManager` supervises one `cloudflared` child process.

| | `.quick` (free) | `.named` (custom domain) |
|---|---|---|
| Arguments | `tunnel --no-autoupdate --url http://localhost:<port>` | `tunnel --no-autoupdate run --token <token>` |
| Ingress config | The `--url` flag | The Cloudflare dashboard's Public Hostnames |
| URL discovery | Regex `https://[a-z0-9-]+\.trycloudflare\.com` against the child's output | `https://<tunnelHostname>`, pre-populated from config |
| Readiness signal | The URL appearing | The line `Registered tunnel connection` |
| Cloudflare account | Not needed | Required |
| URL stability | New random URL per restart | Stable hostname you own |

`.quick` is the default because it is the only zero-configuration option
— it gets a working public URL on first launch with no account. `.named`
is what you switch to once a webhook provider or an MCP client has the
URL saved in *its* config, since a rotating hostname breaks both.

Named mode pre-populates `publicURL` and fires the completion
immediately, before cloudflared finishes its ~3–10 s bootstrap: the
hostname is determined by configuration, not discovered, so there is
nothing to wait for and the menu bar can show the real address right
away. Quick mode genuinely cannot know its URL until cloudflared prints
it, so `publicURL` stays `nil` until the regex matches.

Binary lookup order:

```
1. Contents/Resources/cloudflared    (bundled by CI release builds)
2. /opt/homebrew/bin/cloudflared     (Apple Silicon Homebrew)
3. /usr/local/bin/cloudflared        (Intel Homebrew)
4. /usr/bin/cloudflared
5. /usr/bin/which cloudflared        (anything else on PATH)
```

If none resolve, the user gets an alert with a `brew install cloudflared`
button that copies the command.

Three details that were each a bug once:

- **`--no-autoupdate` must come before `run`.** It is a `tunnel`
  subcommand flag, not a `run` flag. Placed after, cloudflared rejects the
  CLI, prints help, and exits 0 within ~40 ms — a failure whose only
  visible symptom is a tunnel that never appears.
- **Tokens are redacted in the log.** The spawn line prints
  `<redacted-token-N-chars>` instead of the connector token, so the
  system log never holds a credential.
- **`stop()` is synchronous.** SIGTERM, poll for up to 3 s, then SIGKILL
  and poll for 1 s more. It has to be, because `configChanged` calls
  `start()` immediately afterwards and a stale child would register
  against the wrong tunnel or fail to register at all.

A one-shot `Resolver` box guarantees the completion handler fires exactly
once — first URL match, or a 12 s timeout with `nil`. `TunnelStatus.shared`
mirrors state to SwiftUI on a `@MainActor` hop; raw cloudflared output is
logged at `debug` level so steady state stays quiet but connection
failures are diagnosable.

---

## 11. Menu bar and Settings

The menu is rebuilt in `menuNeedsUpdate` — right before it opens — so the
tunnel URL, endpoint count, and recent runs are current without polling a
timer. Top to bottom:

1. `⚠ <listener error>` — **only when the bind failed**, first, because
   no endpoint and no tunnel can work until it is fixed and the alternative
   symptom is silence.
2. The tunnel URL (click to copy), or `Tunnel: connecting…`, or
   `Tunnel: off (localhost:<port>)`.
3. `<n> endpoints, <m> MCP tools`, then up to 8 paths (command in the
   tooltip) and `… and N more`.
4. `Recent` — the last 5 runs as `✓ /path · 200 · 41ms`, output head in
   the tooltip.
5. Settings… (`⌘,`), Restart tunnel (`⌘T`), Check for updates…, Quit
   (`⌘Q`).

`ServerStatus` exists specifically to make the listener's state visible.
The listener runs in a detached `Task`, so a bind error would otherwise
vanish with the task and leave a healthy-looking menu bar icon in front
of nothing. `describeListenerFailure` translates NIO's bare `errno 48`
into `Ports 7876 and 7877 are both in use by other apps — choose a
different port in Settings.` (and `errno 13` into the "use a port above
1024" variant), naming every port that was tried. It carries the bound
port too, which is what lets the menu and the Tunnel tab point out a
fallback that worked but moved the address.

`SettingsView` is three tabs in a fixed 680×620 window:

| Tab | Contents |
|-----|----------|
| **Endpoints** | The rule table: enable switch, path, method/MCP/read-only tags, command, inline validation error or the live tunnel URL with a copy button; Add / Edit / Delete |
| **Tunnel** | Bearer token, the unauthenticated-tunnel warning card, tunnel enable + mode + token/hostname or live public URL, MCP master switch and published tool count, listener error or fallback-in-use card, and Advanced → local API port + fallback port |
| **General** | Execution (shell, login shell, max concurrent, max output KB, max body MB, keep request files), Launch at login (`SMAppService`), Recent runs, version and bundle identifier |

`save()` normalizes every path first (so `ep1` and `/ep1/` collapse before
the duplicate check), refuses the save on the first `validationError()`,
refuses duplicate paths, and — when the tunnel is on with an empty
token — routes through a confirmation alert instead of publishing a shell
silently.

`EndpointEditorView` is the add/edit sheet, and its **Test** button is
the reason endpoint bring-up doesn't require a webhook: it runs the
*unsaved draft* through `CommandRunner` with `source: "test"`,
`method: "TEST"`, and a `{}` body, then shows exit code, duration, stdout,
and stderr inline. The command is exercised before it is saved and before
anything on the internet can reach it.

`installMainMenu()` is a small but load-bearing piece of AppKit
plumbing: an `LSUIElement` app has no default main menu, so without
explicit App and Edit submenus, `⌘C`/`⌘V`/`⌘X`/`⌘A`/`⌘Z` silently no-op
in every SwiftUI text field.

---

## 12. Logging

```swift
public enum Log {
    private static let subsystem = "com.machook.app"
    public static let app    = Logger(subsystem: subsystem, category: "app")
    public static let api    = Logger(subsystem: subsystem, category: "api")
    public static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    public static let runner = Logger(subsystem: subsystem, category: "runner")
    public static let mcp    = Logger(subsystem: subsystem, category: "mcp")
}
```

Everything goes through those five categories, so one predicate shows the
whole picture:

```bash
log stream --predicate 'subsystem == "com.machook.app"' --info
```

Paths, statuses, and durations are logged with `privacy: .public` so they
are readable without a debugger attached; payload contents are never
logged, and the connector token is redacted at the one place it would
otherwise appear.

---

## 13. Build pipeline

```
cd src && swift build -c release          # or `make release`
   │
   ▼
./create-app-bundle.sh                    # or `make app`
   │
   ├── Machook.app/Contents/{MacOS,Resources,Frameworks}
   ├── cp .build/release/Machook → Contents/MacOS/
   ├── install_name_tool -add_rpath @loader_path/../Frameworks
   ├── cp Sources/Machook/Resources/* → Contents/Resources/
   ├── cp SwiftPM *.bundle → Contents/Resources/
   ├── assert no `Bundle.module` use in Sources, and none linked into the binary
   ├── assert no build-machine absolute paths embedded
   ├── bundle cloudflared (bundled copy → PATH copy → download latest)
   ├── cp src/Info.plist, set CFBundleShortVersionString + CFBundleVersion
   ├── inject SUPublicEDKey when SPARKLE_ED_PUBLIC_KEY is set
   └── codesign cloudflared, Sparkle XPC services + framework, binary, bundle
       (Developer ID + hardened runtime when available, else ad-hoc `-`)
```

The `Bundle.module` guard deserves its comment in the script: SwiftPM's
generated accessor probes a resource-bundle path this bundler does not
write, falls back to an absolute path inside the build machine's
checkout, and calls `fatalError` when neither resolves. Because the icon
loader runs before anything draws and `LSUIElement` suppresses the crash
dialog, the app would silently fail to launch on every machine except the
one that built it. All resource loading goes through `Bundle.main`
instead, and the script fails the build if that regresses.

Version numbers are derived, not hand-edited: `CFBundleShortVersionString`
from `$APP_VERSION` or `git describe --tags --abbrev=0`,
`CFBundleVersion` from `git rev-list --count HEAD`.

Make targets: `build`, `release`, `app`, `install`, `run`, `test`,
`icon`, `clean`, `info`.

### Release

`.github/workflows/release.yml` fires on a `v*` tag (or manual dispatch)
and, per architecture (`arm64`, `x86_64`):

1. Select an Xcode with a Swift 6 toolchain, import the Developer ID cert.
2. Download the matching `cloudflared` release tarball for bundling.
3. `./create-app-bundle.sh` with `CODESIGN_IDENTITY`, `APP_VERSION`,
   `TARGET_ARCH`, `SPARKLE_ED_PUBLIC_KEY`.
4. Notarize with `notarytool submit --wait`, then `stapler staple` +
   `stapler validate`.
5. Package `machook-<arch>.zip` (via `ditto -c -k --sequesterRsrc
   --keepParent`) and `machook-<arch>.dmg`, each with a `.sha256`.
6. Create the GitHub release, then update `appcast.xml` via
   `scripts/appcast-add.sh`, which signs each ZIP with the Sparkle EdDSA
   private key and appends an `<item>` pointing at the release asset.

Sparkle itself is wired through `Info.plist` (`SUFeedURL`,
`SUScheduledCheckInterval` 86400, `SUEnableAutomaticChecks` true,
`SUAutomaticallyUpdate` false) and `SUPublicEDKey`, which ships empty on
purpose — Sparkle aborts on an invalid key, and `AppDelegate` skips the
updater entirely while it is blank, so local dev builds simply have no
auto-update. See [`docs/DISTRIBUTION.md`](DISTRIBUTION.md) for keygen and
the maintainer checklist.

---

## 14. Why these dependencies

| Dependency | Why |
|------------|-----|
| `Hummingbird` | Lightweight async HTTP server, Swift 6 friendly, no ObjC, minimal transitive deps. Middleware plus a `/**` catch-all is all this app needs from a server. |
| `modelcontextprotocol/swift-sdk` | The official MCP SDK, and it ships the stateless HTTP server transport plus the validation pipeline pieces, so the MCP surface is a few dozen lines rather than a protocol implementation. |
| `Sparkle` | The standard for macOS auto-updates outside the App Store, with EdDSA signature verification. |
| `cloudflared` *(external binary, not a package)* | The tunnel. Supervised as a child process because that is the only supported way to run it; bundled into `Contents/Resources` by release builds and found on `PATH` in dev. |

Notably absent, and intentionally: no database, no ORM, no HTTP client,
no AppleScript bridge. Machook holds no durable state beyond
`UserDefaults` and the transient envelope files.

---

## 15. Out of scope, on purpose

Machook maps a URL to a command and gets out of the way. These do **not**
belong in this codebase:

- Scripting languages, DSLs, or a workflow builder — the command is your
  script, in whatever language you like.
- Retry queues and delivery guarantees. A request runs once,
  synchronously, and the caller learns the outcome from the status code.
  Webhook providers already retry.
- Request signature verification (GitHub HMAC, Stripe signatures). The
  envelope carries the headers and the raw body; verifying them is three
  lines in your script and stays out of Machook's trust decisions.
- Field interpolation into the command line beyond `{{request}}`. It is
  the one thing that would put network data next to shell syntax, so if
  it ever lands it goes through `ShellQuote` like everything else.
- Multi-user auth, roles, per-endpoint tokens, audit storage. One token,
  one Mac, one owner.
