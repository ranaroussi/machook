# Changelog

All notable changes to Machook are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — unreleased

First release. A macOS menu bar app that runs local shell commands in response
to incoming webhooks.

### Added

- **Endpoint table.** Map a request path to a shell command, edited in Settings:
  methods, timeout, working directory, enable/disable. Endpoints resolve against
  the live configuration on every request, so changes take effect with no restart.
- **Request envelope.** Every request is written to a private temp file
  (`0600` in a `0700` per-user directory) as JSON — method, path, query, headers,
  parsed body, raw body — and the file's path replaces `{{request}}` in the
  command. The `Authorization` header is stripped before the file is written, the
  file is deleted when the command exits, and stale files are swept at launch.
  The path is also exported as `MACHOOK_REQUEST_FILE`.
- **Synchronous responses.** stdout becomes the response body with a sniffed
  content type, the exit code becomes the status: `200` on success, `500` with
  stderr on a non-zero exit, `504` on timeout, `503` at the concurrency cap or
  for a disabled endpoint, `405` for a rejected verb, `404` for an unknown path.
  Runs report `X-Machook-Exit-Code`, `X-Machook-Duration-Ms`, and
  `X-Machook-Truncated`.
- **MCP server.** `POST /mcp` publishes each endpoint as a tool, with the catalog
  generated from the live endpoint table. Tool calls execute the same command
  against the same envelope shape, with tool arguments delivered as the body.
  Per-endpoint tool name, description, input schema, and read-only annotation.
- **Cloudflare Tunnel.** Bundled and supervised `cloudflared` in quick mode
  (ephemeral `trycloudflare.com` URL, no account) or named mode (stable
  hostname). The current URL is in the menu bar; click to copy.
- **Verified tunnel URLs.** A published URL is not a working one: a quick tunnel
  can be assigned a hostname Cloudflare never puts in DNS, and every other
  signal still looks healthy. Machook now fetches `<url>/health` through the
  public URL, retrying on a Fibonacci schedule for about 90 seconds, and
  reports the outcome in the menu, in Settings, and as `tunnel_reachability`
  on `GET /status`. Failures are named rather than generic: a missing DNS
  record, an edge with no connector (Cloudflare error 1033), a tunnel that
  reaches us but finds nothing listening, or an Access policy in the way.
- **Tunnel process hygiene.** `SIGTERM` and `SIGINT` now quit the app through
  the normal path, so `pkill` no longer leaves a running menu bar app whose
  listener is dead. A `cloudflared` orphaned by a crash or a force-quit is
  terminated at the next launch, matched only by the exact executable path
  inside our own bundle so unrelated tunnels on the machine are never touched.
  If the listener stops without being asked to, the menu says so instead of
  looking healthy.
- **Readable tunnel logs.** `cloudflared` output was recorded at debug level,
  which a default `log show` drops — the failure was invisible in exactly the
  case you would go looking for it. Errors, warnings, and connection loss are
  promoted to `error` or `notice`. The connector token is passed through the
  environment rather than `--token`, so it no longer appears in `ps` output.
- **Bearer token auth** on every route except `GET /health`, compared in constant
  time. Settings refuses to save an enabled tunnel with an empty token.
- **Shell injection boundary.** The command template from Settings is the only
  string the shell parses; network data arrives as a quoted argv element or a
  file path. Quoting only passes a value through unquoted when every character is
  provably inert.
- **Command runner** with a wall-clock timeout (SIGTERM, then SIGKILL two seconds
  later), a per-stream output cap that keeps draining past the cap so the child
  never blocks on a full pipe, a concurrency budget, `/dev/null` on stdin, and an
  optional login shell so Homebrew and pyenv paths resolve.
- **Port fallback.** The listener tries `localAPIPort` (7876) and then
  `fallbackAPIPort` (7877), since a fixed default port is a coin flip on a
  machine that already runs something there. It only moves before it has served
  traffic, the menu bar and Settings say when the fallback is in use, and the
  tunnel is started against the port that actually bound rather than the
  configured one. Set the fallback to `0` to insist on a single port.
- **Menu bar surface**: tunnel URL, endpoint and tool counts, the last few runs,
  a note when the fallback port is in use, and a warning line when the HTTP
  listener cannot bind at all.
- **Built-in routes**: `GET /health` (unauthenticated) and `GET /status`.
- **Sample endpoint.** `examples/log-request.sh` records each request to
  `~/Library/Logs/machook/requests.log` (0600, in a 0700 directory, rotated at
  5 MiB) and answers with a JSON summary, so a new install can be exercised
  end to end before any real command is wired up. `?fail=1` exits non-zero on
  purpose to demonstrate the 500-plus-stderr mapping.
- Sparkle auto-updates, Developer ID signing, and notarization in CI.
- **Universal builds.** Releases ship one `machook-universal` artifact whose
  executable, bundled `cloudflared`, and `Sparkle.framework` each carry both
  `arm64` and `x86_64`. A Sparkle appcast channel advertises a single
  `<enclosure>` with no architecture filtering, so a per-arch release would
  offer half the user base a build their Mac cannot launch; CI now fails if any
  shipped binary is missing a slice. The appcast's `minimumSystemVersion` is
  read from `LSMinimumSystemVersion` rather than hardcoded, so an update is
  never offered to a macOS version the app cannot run on.
- 67 unit tests covering shell quoting, template rendering, path and tool-name
  normalization, endpoint validation, configuration decoding, envelope shape and
  file permissions, port-candidate selection, the port fallback against a real
  occupied socket, reachability classification, cloudflared log levels, stray
  process matching (including that another app's tunnel is never a candidate),
  listener shutdown reporting, and runner behaviour including timeouts, output
  caps, concurrency, and that injected metacharacters do not execute.
