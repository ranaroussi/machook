# Testing Machook

Unit tests first, then a manual playbook. Each section is independent —
skip what you don't need.

If something fails, see [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) first.
For how the pieces fit together, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## 1. Unit tests

```bash
cd src && swift test
# or, from the repo root:
make test
```

79 tests across 8 suites. They exercise the security boundary and the
process runner directly rather than only through a live request, so a
regression in quoting or timeout handling fails here before it ever
reaches an HTTP surface.

| Suite | File | What it pins down |
|-------|------|-------------------|
| `ShellQuoteTests` | `TemplateAndQuotingTests.swift` | Inert values pass through unquoted; `; rm -rf ~`, `$(whoami)`, `` `id` ``, `a && b`, pipes all become one inert argv element; embedded `'` becomes `'\''`; `=ls` and `~/secrets` are quoted because zsh expands them |
| `CommandTemplateTests` | `TemplateAndQuotingTests.swift` | `{{request}}` substitution, paths with spaces, `{{ request }}` whitespace, multiple occurrences, matched surrounding quotes absorbed, unmatched quote preserved, unsupported placeholders throwing and being listed for the UI |
| `EndpointRuleTests` | `TemplateAndQuotingTests.swift` | Path normalization (`ep1`, `/ep1/`, pasted tunnel URL, query string), tool-name derivation, case-insensitive method matching, every validation rule |
| `AppConfigTests` | `TemplateAndQuotingTests.swift` | Tool-name collision suffixing, enabled-vs-exists lookup, MCP catalog filtering, decoding a config that predates a new field without losing endpoints |
| `RequestEnvelopeTests` | `TemplateAndQuotingTests.swift` | JSON body parsed into `body` and mirrored to `body_raw`, non-JSON body still delivered as text, binary body falling back to `body_base64`, written file is mode `0600` and not under `/tmp` |
| `ListenerFallbackTests` | `ListenerFallbackTests.swift` | A real occupied loopback socket: the listener skips the taken port for the fallback and serves `/health` there; with no fallback left, the failure surfaces on `ServerStatus` naming the port and the conflict; a shutdown nobody requested raises a visible error while a requested one stays quiet |
| `TunnelSupervisionTests` | `TunnelSupervisionTests.swift` | Reachability verdicts from probe outcomes (`530` as Cloudflare 1033, `502` as a local miss, offline, unexpected status); the DNS cross-check — a record found publicly blames this Mac and **not** Cloudflare, no record says "not published", an unanswerable check claims nothing, plus DoH parsing of A/CNAME/NXDOMAIN/SERVFAIL; which cloudflared output gets promoted out of debug; restart generations, so a superseded child cannot touch live state; stray-PID matching, including that another app's or Homebrew's tunnel is **never** a candidate, that a path prefix does not match, and that the supervised child is excluded; relative launch paths resolved to absolute |
| `CommandRunnerTests` | `CommandRunnerTests.swift` | Real shells: stdout capture, non-zero exit with stderr, envelope readable byte-for-byte, **shell metacharacters in a payload do not execute**, `MACHOOK_REQUEST_FILE`, keep-request-files, stdin is `/dev/null` so `cat` doesn't hang, timeout kills the child, output cap without breaking completion, working directory, concurrency rejection, bad placeholder failing before spawn |

`CommandRunnerTests` spawns real `zsh` processes (with `loginShell =
false` so nobody's profile banners land in stderr) and includes a 1 s
timeout test and a 2 s concurrency test, so the suite is not instant.

---

## 2. Prerequisites for manual testing

```bash
# 1. Build a signed bundle
make app

# 2. Install it
cp -R Machook.app /Applications/

# 3. Launch
open /Applications/Machook.app
```

**No permissions to grant.** Machook needs no Full Disk Access, no
Automation, no Contacts — nothing in System Settings → Privacy &
Security. If a step in this document seems to be waiting on a permission
prompt, that is a bug.

For the tunnel sections you also need `cloudflared`; release bundles ship
it, dev bundles fall back to your `PATH`:

```bash
brew install cloudflared
```

### Watch the logs while you test

Keep this running in a second terminal — it is the fastest way to see why
something returned what it returned:

```bash
log stream --predicate 'subsystem == "com.machook.app"' --info
```

Narrow it per category (`app`, `api`, `runner`, `mcp`, `tunnel`):

```bash
log stream --predicate 'subsystem == "com.machook.app" && category == "runner"' --info
log show   --predicate 'subsystem == "com.machook.app"' --info --last 5m
```

---

## 3. The test fixture

Every example below assumes port `7876`, bearer token `test-token`, and
these six endpoints.

| Path | Command | Methods | Timeout | Enabled | Exercises |
|------|---------|---------|---------|---------|-----------|
| `/ep1` | `/bin/cat {{request}}` | POST | 30 | yes | Happy path, envelope contents, injection |
| `/ep2` | `echo ok` | POST, GET | 30 | yes | 405 on another verb |
| `/quiet` | `true` | POST | 30 | yes | Empty stdout → synthetic JSON |
| `/boom` | `echo bad >&2; exit 7` | POST | 30 | yes | Non-zero exit → 500 |
| `/slow` | `sleep 5` | POST | 1 | yes | Timeout → 504 |
| `/off` | `echo nope` | POST | 30 | **no** | Disabled → 503 |

### Option A — the GUI

Menu bar → **Settings…** (or `⌘,`):

1. **Tunnel** tab → Bearer token: `test-token`. Leave the tunnel off for
   now.
2. **Tunnel** tab → Advanced → Local API port: `7876`.
3. **Endpoints** tab → **Add endpoint** for each row above. In the sheet:
   set the path, paste the command, click the method buttons you want,
   set the timeout. Hit **Test** before **Done** — it runs the draft
   command immediately with a `{}` body and shows exit code, duration,
   stdout, and stderr inline, so you find typos without involving HTTP.
4. **Save**. A green "Saved" appears for ~1.6 s. Endpoint edits are live:
   no restart, no tunnel bounce.

### Option B — seed it straight into UserDefaults

Faster for repeat runs. The config is one JSON blob in `UserDefaults`
under `machook.config.v1`, domain `com.machook.app`.

```bash
# Machook reads the blob once, when the config store is first touched,
# so it must not be running while you seed.
osascript -e 'quit app "Machook"' 2>/dev/null; sleep 1

python3 - <<'PY'
import json, subprocess, uuid

def ep(path, command, methods=("POST",), timeout=30, enabled=True, **kw):
    rule = {
        "id": str(uuid.uuid4()), "path": path, "command": command,
        "methods": list(methods), "enabled": enabled,
        "timeoutSeconds": timeout, "workingDirectory": "",
        "toolDescription": "", "mcpEnabled": True,
        "mcpToolName": "", "mcpInputSchema": "", "mcpReadOnly": False,
    }
    rule.update(kw)
    return rule

config = {
    "bearerToken": "test-token",
    "localAPIPort": 7876,
    # 0, so a busy 7876 fails loudly instead of quietly moving the
    # tests to 7877 half way through a matrix.
    "fallbackAPIPort": 0,
    "tunnelEnabled": False,
    "tunnelMode": "quick",
    "tunnelToken": "",
    "tunnelHostname": "",
    "mcpEnabled": True,
    "maxConcurrentRuns": 4,
    "maxOutputKB": 1024,
    "maxBodyMB": 10,
    "keepRequestFiles": False,
    "shellPath": "/bin/zsh",
    "loginShell": True,
    "endpoints": [
        ep("/ep1",   "/bin/cat {{request}}", ("POST",)),
        ep("/ep2",   "echo ok",              ("POST", "GET")),
        ep("/quiet", "true"),
        ep("/boom",  "echo bad >&2; exit 7"),
        ep("/slow",  "sleep 5", timeout=1),
        ep("/off",   "echo nope", enabled=False),
    ],
}

blob = json.dumps(config).encode()
subprocess.run(
    ["defaults", "write", "com.machook.app", "machook.config.v1", "-data", blob.hex()],
    check=True,
)
print("seeded", len(blob), "bytes")
PY

open /Applications/Machook.app
```

Read it back (the value is `Data`, so `defaults read` prints an unhelpful
hex summary — go through `plistlib` instead):

```bash
defaults export com.machook.app - | python3 -c '
import plistlib, sys
print(plistlib.load(sys.stdin.buffer)["machook.config.v1"].decode())' | jq .
```

Wipe everything and start clean:

```bash
osascript -e 'quit app "Machook"' 2>/dev/null; sleep 1
defaults delete com.machook.app
open /Applications/Machook.app
```

> Clicking **Save** in Settings rewrites the whole blob from what the
> window is showing, so a seeded value and an open Settings window will
> fight. Seed *or* use the GUI, not both at once.

### Shared shell setup

```bash
TOKEN=test-token
BASE=http://127.0.0.1:7876
AUTH=(-H "Authorization: Bearer $TOKEN")
```

---

## 4. Smoke test

```bash
# Menu bar shows the Machook glyph, and the menu lists
# "Tunnel: off (localhost:7876)" plus "5 endpoints, 5 MCP tools".

# /health is the only unauthenticated route
curl -sS "$BASE/health"
# {"ok":true}

# Everything else needs the token
curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/status"
# 401

curl -sS "${AUTH[@]}" "$BASE/status" | jq
# {
#   "ok": true, "version": "0.1.0",
#   "tunnel_url": "", "tunnel_running": false,
#   "tunnel_reachability": "unknown", "tunnel_reachability_note": "",
#   "local_api_port": 7876, "configured_api_port": 7876,
#   "endpoints_total": 6, "endpoints_enabled": 5,
#   "mcp_enabled": true, "mcp_tools": 5,
#   "active_runs": 0
# }
```

`version` reads `CFBundleShortVersionString`, so a binary launched
straight out of `src/.build` reports `0.0.0`.

`local_api_port` is the port actually bound and `configured_api_port` is
the one in Settings. If they differ, the primary port was taken and the
fallback is serving — call that port, not the configured one.

`tunnel_reachability` is `unknown` until a tunnel URL exists, then
`checking` while the URL is probed from the outside, then `reachable` or
`unreachable` with the reason in `tunnel_reachability_note`. See §10a.

---

## 5. Endpoint dispatch matrix

Run these in order; each one is a single expectation.

```bash
# Happy path — stdout becomes the body, Content-Type is sniffed as JSON
curl -sS -i "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"hello":"world"}' "$BASE/ep1"
# HTTP/1.1 200 OK
# content-type: application/json
# x-machook-exit-code: 0
# x-machook-duration-ms: 41
# { ... the whole request envelope ... }

# Empty stdout — a synthetic summary instead of a blank 200
curl -sS "${AUTH[@]}" -d '{}' "$BASE/quiet"
# {"ok":true,"exit_code":0,"duration_ms":15}

# Non-zero exit — 500 carrying stderr and the exit code
curl -sS -w '\n%{http_code}\n' "${AUTH[@]}" -d '{}' "$BASE/boom"
# {"error":"Command exited 7","stderr":"bad\n","exit_code":7}
# 500

# Timeout — SIGTERM at 1s, SIGKILL 2s later, caller gets 504
time curl -sS -w '\n%{http_code}\n' "${AUTH[@]}" -d '{}' "$BASE/slow"
# {"error":"Command timed out after 1022 ms","exit_code":15,...}
# 504
# (~1s, not ~5s)

# Unknown path — note this needs a VALID token; auth runs before routing
curl -sS -w '\n%{http_code}\n' "${AUTH[@]}" -d '{}' "$BASE/nope"
# {"error":"No endpoint configured for /nope"}
# 404

# Wrong verb on a known path
curl -sS -w '\n%{http_code}\n' -X DELETE "${AUTH[@]}" "$BASE/ep2"
# {"error":"/ep2 accepts POST, GET"}
# 405

# Disabled endpoint — distinguishable from a missing one
curl -sS -w '\n%{http_code}\n' "${AUTH[@]}" -d '{}' "$BASE/off"
# {"error":"Endpoint /off is disabled"}
# 503

# Missing token
curl -sS -i -d '{}' "$BASE/ep1" | head -5
# HTTP/1.1 401 Unauthorized
# www-authenticate: Bearer
# {"error":"Missing or invalid bearer token. Send: Authorization: Bearer <token>"}

# Wrong token
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'Authorization: Bearer nope' -d '{}' "$BASE/ep1"
# 401
```

Path normalization means these are all the same endpoint:

```bash
for p in /ep1 /ep1/ '/ep1?token=abc'; do
  curl -sS -o /dev/null -w "$p → %{http_code}\n" "${AUTH[@]}" -d '{}' "$BASE$p"
done
# /ep1 → 200
# /ep1/ → 200
# /ep1?token=abc → 200
```

---

## 6. Injection attempt — must NOT execute

This is the test that matters most. The payload is full of shell
metacharacters; it must arrive as data and run nothing.

```bash
rm -f /tmp/machook-pwned

curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"$(touch /tmp/machook-pwned); `id`"}' "$BASE/ep1" | jq -r .body_raw
# {"name":"$(touch /tmp/machook-pwned); `id`"}

ls /tmp/machook-pwned
# ls: /tmp/machook-pwned: No such file or directory   ← REQUIRED
```

Variations worth trying, all of which must behave identically (delivered
verbatim in `body_raw`, nothing executed):

```bash
for payload in \
  '{"x":"; rm -rf /tmp/machook-test"}' \
  '{"x":"a && touch /tmp/machook-pwned"}' \
  "{\"x\":\"' ; touch /tmp/machook-pwned ; '\"}" \
  '{"x":"$(curl http://example.com)"}' ; do
  curl -sS "${AUTH[@]}" -d "$payload" "$BASE/ep1" | jq -r .body_raw
done
ls /tmp/machook-pwned 2>&1   # must still be "No such file or directory"
```

The reason it holds: the command template from Settings is the only string
the shell parses. The envelope path is the sole substitution, it goes
through `ShellQuote`, and the payload itself is never on the command
line — it is in a file.

Also confirm the command line cannot be broken by a query string or a
header:

```bash
curl -sS "${AUTH[@]}" -H 'X-Evil: $(touch /tmp/machook-pwned)' \
  -d '{}' "$BASE/ep1?q=%24%28touch%20%2Ftmp%2Fmachook-pwned%29" \
  | jq '{query, evil: .headers["x-evil"]}'
ls /tmp/machook-pwned 2>&1   # still absent
```

---

## 7. Envelope inspection

`/ep1` is `/bin/cat {{request}}`, so its response *is* the envelope:

```bash
curl -sS "${AUTH[@]}" \
  -H 'Content-Type: application/json' -H 'X-Github-Event: push' \
  -d '{"users":[{"id":42}]}' \
  "$BASE/ep1?dry=1" | jq
```

Expected keys — `id`, `received_at`, `source`, `method`, `path`, `query`,
`headers`, `body`, `body_raw`, `body_bytes`:

```bash
curl -sS "${AUTH[@]}" -d '{"a":1}' "$BASE/ep1" | jq 'keys'
# ["body","body_bytes","body_raw","headers","id","method","path","query","received_at","source"]
```

Assertions worth making explicitly:

```bash
# source/method for an HTTP call
curl -sS "${AUTH[@]}" -d '{}' "$BASE/ep1" | jq '{source, method, path}'
# {"source":"http","method":"POST","path":"/ep1"}

# JSON bodies are pre-parsed, so jq .body.x.y works with no second parse
curl -sS "${AUTH[@]}" -d '{"users":[{"id":42}]}' "$BASE/ep1" | jq '.body.users[0].id'
# 42

# Non-JSON bodies still arrive as text, with body == null
curl -sS "${AUTH[@]}" -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'a=1&b=2' "$BASE/ep1" | jq '{body, body_raw, body_bytes}'
# {"body":null,"body_raw":"a=1&b=2","body_bytes":7}

# Non-UTF-8 bodies fall back to body_base64 (and there is no body_raw)
printf '\xff\xfe\x00\x01' | curl -sS "${AUTH[@]}" --data-binary @- "$BASE/ep1" \
  | jq '{body_base64, body_raw}'
# {"body_base64":"//4AAQ==","body_raw":null}

# The Authorization header is stripped before the file is written
curl -sS "${AUTH[@]}" -d '{}' "$BASE/ep1" | jq '.headers.authorization'
# null           ← REQUIRED: our bearer token must never hit disk
```

### The file itself

Turn on **General → Keep request files** in Settings and save, then:

```bash
curl -sS "${AUTH[@]}" -d '{"keep":true}' "$BASE/ep1" > /dev/null

# Directory is 0700, file is 0600, both under the per-user temp dir
DIR="$(getconf DARWIN_USER_TEMP_DIR)machook/requests"
ls -ld "$DIR"
ls -l "$DIR" | tail -3
# drwx------  … requests
# -rw-------  … 1770000000123-a1b2c3d4.json

# Not world-readable /tmp
echo "$DIR" | grep -qv '^/tmp/' && echo "not in /tmp: ok"

# The log records the kept path
log show --predicate 'subsystem == "com.machook.app" && category == "runner"' \
  --info --last 1m | grep "kept request envelope"
```

Turn "Keep request files" back **off**, then confirm cleanup and the env
var. Point an endpoint at `echo $MACHOOK_REQUEST_FILE` (or reuse the
Settings Test button):

```bash
# With an endpoint whose command is: echo $MACHOOK_REQUEST_FILE
P="$(curl -sS "${AUTH[@]}" -d '{}' "$BASE/envpath")"
echo "$P"           # …/machook/requests/1770000000123-a1b2c3d4.json
ls "$P" 2>&1        # No such file or directory — deleted once the command exited
```

Envelopes older than 6 hours are swept at launch, which covers a crash
between writing a file and the `defer` that removes it:

```bash
mkdir -p "$DIR" && touch -t 202001010000 "$DIR/stale-test.json"
osascript -e 'quit app "Machook"'; sleep 1; open /Applications/Machook.app; sleep 3
ls "$DIR/stale-test.json" 2>&1     # gone
log show --predicate 'subsystem == "com.machook.app" && category == "runner"' \
  --info --last 1m | grep "swept"
```

### stdin is `/dev/null`

A script that reads stdin must return immediately instead of hanging
until the timeout. Add an endpoint whose command is `/bin/cat` (no
`{{request}}`) and:

```bash
time curl -sS -o /dev/null -w '%{http_code}\n' "${AUTH[@]}" -d '{}' "$BASE/catstdin"
# 200, in milliseconds — not a 504 after the timeout
```

---

## 8. Limits

```bash
# Output cap: set General → Max captured output to 1 KB, save, then hit an
# endpoint whose command floods stdout, e.g.
#   /usr/bin/awk 'BEGIN{for(i=0;i<10000;i++)printf "x"}'
curl -sS -D- -o /tmp/machook-out "${AUTH[@]}" -d '{}' "$BASE/loud" | grep -i machook
# x-machook-exit-code: 0
# x-machook-truncated: true
wc -c < /tmp/machook-out
#     1024                       ← capped, but the command still exited 0

# Concurrency: set General → Max concurrent commands to 1, save
curl -sS "${AUTH[@]}" -d '{}' "$BASE/slow" >/dev/null &   # holds the only slot
sleep 0.3
curl -sS -w '\n%{http_code}\n' "${AUTH[@]}" -d '{}' "$BASE/ep1"
# {"error":"Too many commands already running (limit 1)"}
# 503
wait

# active_runs reflects it while a command is in flight
curl -sS "${AUTH[@]}" -d '{}' "$BASE/slow" >/dev/null &
sleep 0.3; curl -sS "${AUTH[@]}" "$BASE/status" | jq .active_runs   # 1
wait; curl -sS "${AUTH[@]}" "$BASE/status" | jq .active_runs        # 0

# Body cap: default Max request body is 10 MB
head -c 20000000 /dev/zero | curl -sS -w '\n%{http_code}\n' "${AUTH[@]}" \
  --data-binary @- "$BASE/ep1"
# {"error":"Request body exceeds 10 MB"}
# 413

# Reserved paths cannot be claimed: add an endpoint on /status in Settings.
# The editor footer shows "/status is reserved by Machook itself" and both
# Test and Done stay disabled.
```

Remember to put **Max captured output** and **Max concurrent commands**
back (1024 KB / 4) before continuing.

---

## 9. MCP over HTTP

`POST /mcp` needs the bearer token, `Content-Type: application/json`, and
an explicit `Accept: application/json` — `curl` does not send the last one
by default and the SDK's validator rejects the request without it.

```bash
MCP=(-X POST "$BASE/mcp" "${AUTH[@]}"
     -H 'Content-Type: application/json' -H 'Accept: application/json')

# initialize
curl -sS "${MCP[@]}" -d '{
  "jsonrpc":"2.0","id":1,"method":"initialize",
  "params":{"protocolVersion":"2025-06-18","capabilities":{},
            "clientInfo":{"name":"curl","version":"1"}}}' | jq
# result.serverInfo.name == "machook", result.protocolVersion == the
# version the server negotiated, result.capabilities.tools present

# tools/list — works with no prior initialize, because each request gets
# its own isolated SDK Server
curl -sS "${MCP[@]}" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq '.result.tools[].name'
# "ep1"
# "ep2"
# "quiet"
# "boom"
# "slow"
# (no "off" — it's disabled)

# Default schema is a freeform object when no argument schema is configured
curl -sS "${MCP[@]}" -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' \
  | jq '.result.tools[] | select(.name=="ep1") | .inputSchema'
# {"type":"object","properties":{},"additionalProperties":true}

# tools/call — the arguments arrive as the envelope body
curl -sS "${MCP[@]}" -d '{
  "jsonrpc":"2.0","id":4,"method":"tools/call",
  "params":{"name":"ep1","arguments":{"deploy":"main"}}}' \
  | jq -r '.result.content[0].text' | jq '{source, method, path, body}'
# {"source":"mcp","method":"MCP","path":"/ep1","body":{"deploy":"main"}}

# A failing tool reports isError with the exit code in the text
curl -sS "${MCP[@]}" -d '{
  "jsonrpc":"2.0","id":5,"method":"tools/call",
  "params":{"name":"boom","arguments":{}}}' | jq '{isError:.result.isError, text:.result.content[0].text}'
# {"isError":true,"text":"Command exited 7\nbad\n"}

# A silent tool returns the same synthetic summary as HTTP
curl -sS "${MCP[@]}" -d '{
  "jsonrpc":"2.0","id":6,"method":"tools/call",
  "params":{"name":"quiet","arguments":{}}}' | jq -r '.result.content[0].text'
# {"ok":true,"exit_code":0,"duration_ms":14}
```

Negative cases:

```bash
# Endpoint with "Expose as a tool" off, or a name that doesn't exist
curl -sS "${MCP[@]}" -d '{
  "jsonrpc":"2.0","id":7,"method":"tools/call",
  "params":{"name":"off","arguments":{}}}' | jq -r '.result.content[0].text'
# Unknown tool: off

# Missing Accept header
curl -sS -X POST "$BASE/mcp" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":8,"method":"tools/list"}' | jq
# an error mentioning that the client must accept application/json

# No bearer token
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":9,"method":"tools/list"}'
# 401

# MCP master switch off (Settings → Tunnel → MCP), then:
curl -sS -w '\n%{http_code}\n' "${MCP[@]}" \
  -d '{"jsonrpc":"2.0","id":10,"method":"tools/list"}'
# {"error":"MCP is disabled in Settings"}
# 404
```

Live catalog check — no restart should be needed:

```bash
# Add an endpoint /newtool in Settings, Save, then immediately:
curl -sS "${MCP[@]}" -d '{"jsonrpc":"2.0","id":11,"method":"tools/list"}' \
  | jq '.result.tools[].name' | grep newtool
```

Tool-name derivation and collisions:

```bash
# /github/push  → github_push
# /deploy-site  → deploy-site
# Two endpoints resolving to the same name get a _2 suffix; add /a/b and
# /a-b (both reduce to a_b) and confirm tools/list shows a_b and a_b_2.
curl -sS "${MCP[@]}" -d '{"jsonrpc":"2.0","id":12,"method":"tools/list"}' \
  | jq '[.result.tools[].name] | length as $n | {names: ., unique: (unique | length), total: $n}'
# unique == total, always
```

---

## 10. Through the tunnel (end to end)

```bash
# Settings → Tunnel → Enable tunnel = ON, Mode = Free (trycloudflare.com), Save.
# Within ~3-10s the menu bar shows a *.trycloudflare.com URL (click to copy).

TUNNEL=$(curl -sS "${AUTH[@]}" "$BASE/status" | jq -r .tunnel_url)
echo "$TUNNEL"

# Unauthenticated liveness works from anywhere
curl -sS "$TUNNEL/health"
# {"ok":true}

# A real end-to-end run: public URL → cloudflared → localhost → your shell
curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"from":"the internet"}' "$TUNNEL/ep1" | jq '{source, path, body}'
# {"source":"http","path":"/ep1","body":{"from":"the internet"}}

# The token is enforced over the tunnel too
curl -sS -o /dev/null -w '%{http_code}\n' -d '{}' "$TUNNEL/ep1"
# 401

# MCP over the tunnel — same URL, same token
curl -sS -X POST "$TUNNEL/mcp" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools | length'

# Menu bar → Recent should now show the runs, e.g.
#   ✓ /ep1 · 200 · 63ms
# and Settings → General → Recent runs shows source "http" vs "mcp".

# Free-mode URLs rotate: menu bar → "Restart tunnel" (⌘T) and re-read
curl -sS "${AUTH[@]}" "$BASE/status" | jq -r .tunnel_url    # a different host
```

Named mode (stable hostname) — needs a Cloudflare-managed domain and a
tunnel with a Public Hostname pointing at `localhost:7876`:

```bash
# Settings → Tunnel → Mode = Named (custom domain)
#   Tunnel token: the eyJh… connector token
#   Public hostname: hooks.yourcompany.com  (bare host; a pasted scheme is stripped)
# Save. The menu bar shows the hostname immediately — it comes from config,
# not from cloudflared's output — while cloudflared bootstraps.

curl -sS "${AUTH[@]}" "$BASE/status" | jq -r .tunnel_url
# https://hooks.yourcompany.com

curl -sS "https://hooks.yourcompany.com/health"
# {"ok":true}

# Restart the app and re-check: the URL is unchanged. That's the point.

# Edge cases:
#   - Blank token or blank hostname + Save → "Cloudflare named tunnel not
#     configured" alert with an "Open Settings" button
#   - Hostname pasted as https://hooks.yourcompany.com/ → normalized, no
#     doubled scheme in tunnel_url
#   - Switch back to Free and Save → new *.trycloudflare.com URL
```

Smart restart on Save:

```bash
# Note the current tunnel_url. Then change a NON-tunnel field (a command,
# a timeout, Max concurrent commands) and Save.
#   → tunnel stays up, URL unchanged, no listener bounce.
# Change tunnel mode / token / hostname / local API port and Save.
#   → tunnel stops and restarts; a port change also rebuilds the listener.
log show --predicate 'subsystem == "com.machook.app" && category == "app"' \
  --info --last 2m | grep "port changed"
```

### 10a. The URL is verified, not assumed

A quick tunnel can be handed a hostname Cloudflare never publishes in DNS.
cloudflared logs `Registered tunnel connection` and stays alive, so every
other signal says healthy while nothing on the internet can reach you.
Machook fetches `<url>/health` from the outside and reports what happened.

```bash
# With the tunnel on, watch the verdict resolve. It can take ~90s in the
# worst case: retries back off 1,2,3,5,8,13,21,34s.
for i in $(seq 1 12); do
  curl -sS "${AUTH[@]}" "$BASE/status" \
    | jq -r '"\(.tunnel_reachability)\t\(.tunnel_reachability_note)"'
  sleep 10
done
# checking      verifying…
# checking      verifying…
# reachable
```

Healthy path: `reachable`, and the menu bar shows the bare URL. The
important follow-up, because this is what the probe order protects:

```bash
HOST=$(curl -sS "${AUTH[@]}" "$BASE/status" | jq -r .tunnel_url | sed 's|https://||')
dscacheutil -q host -a name "$HOST"     # must have ip_address entries
curl -sS -m 15 "https://$HOST/health"   # {"ok":true} — plain curl, no tricks
```

If the second command fails with `(6) Could not resolve host` while the app
says `reachable`, the probe queried the hostname too early and macOS cached
the `NXDOMAIN`. That is a regression: each attempt must confirm the record
in public DNS before touching the system resolver.

Failure path — the record does not exist yet:

```
# unreachable   DNS: not published yet by Cloudflare
```

Confirm the app is telling the truth rather than inventing a failure:

```bash
dig +short "$HOST" @1.1.1.1            # empty = genuinely not published
dig +short cloudflare.com @1.1.1.1     # control: must answer
```

If `dig` answers but the app still says unreachable, the note must name
*this Mac* rather than Cloudflare:

```
# unreachable   DNS: resolves publicly but not on this Mac — flush your DNS cache
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
# → within 60s the state flips to reachable on its own
log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
  --info --last 10m | grep -i "reachable after all"
```

Also check the surfaces, since `/status` is not where a user looks:

```
# Menu bar:  ⚠ https://… — DNS: not published yet by Cloudflare
# Settings → Tunnel: an orange card saying the same, suggesting a named tunnel.
```

Then `⌘T` (Restart tunnel) — a new hostname is requested and the probe
starts over from `checking`. Turning the tunnel off returns the state to
`unknown`. Restart it several times in a row and check `/status` still
reports `tunnel_running: true` with a URL: a dying child's cleanup landing
after its replacement started used to reset `isRunning`, which stranded the
menu on `verifying…` for a tunnel that was working.

### 10b. Signals and leftover processes

An older build treated `pkill Machook` as a listener shutdown: the app
stayed in the menu bar with a dead port. And a force-quit left its
`cloudflared` child running against the port the next launch would use.

```bash
# 1. SIGTERM must quit the whole app, not just the listener.
open /Applications/Machook.app && sleep 5
curl -sS http://127.0.0.1:7876/health          # {"ok":true}
kill -TERM "$(pgrep -x Machook)" && sleep 3
pgrep -x Machook || echo "app exited"
log show --predicate 'subsystem == "com.machook.app" && category == "app"' \
  --info --last 2m | grep signal
#   received signal 15 — terminating cleanly

# A clean quit also takes the tunnel child with it:
pgrep -lf "Machook.app/Contents/Resources/cloudflared" || echo "no strays"
```

```bash
# 2. An orphan from a force-quit is reaped at the next launch.
#    (Tunnel must be ON so there is a child to orphan.)
open /Applications/Machook.app && sleep 8
CF=$(pgrep -f "Machook.app/Contents/Resources/cloudflared" | head -1)
kill -9 "$(pgrep -x Machook)" && sleep 3
ps -o pid,ppid= -p "$CF"        # still alive, parent is now 1 (launchd)

open /Applications/Machook.app && sleep 7
kill -0 "$CF" 2>/dev/null && echo "FAIL: orphan survived" || echo "reaped"
log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
  --info --last 2m | grep -i stray
#   reaping stray cloudflared PID 54039 from a previous run
```

The sweep must be narrow enough to be safe. If you have your own
`cloudflared` tunnels running, count them before and after — the number
must not change:

```bash
pgrep -cf "/opt/homebrew/bin/cloudflared"
```

A dev build that resolved `cloudflared` from Homebrew sweeps nothing at
all, on purpose, and says so:

```
skipping stray sweep: cloudflared at /opt/homebrew/bin/cloudflared is shared, not ours
```

```bash
# 3. cloudflared failures must survive a default log capture (no --debug).
log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
  --info --last 10m | grep -E "ERR|WRN|terminated|retrying"
```

---

## 11. Port conflicts

A busy port used to fail completely silently — the listener died inside
its detached task while the menu bar looked healthy. Now the primary is
7876, the fallback is 7877, and both outcomes are visible.

### 11a. The primary is taken → the fallback serves

```bash
osascript -e 'quit app "Machook"'; sleep 1

# Hold 7876 with something else
python3 -m http.server 7876 --bind 127.0.0.1 >/dev/null 2>&1 &
HOLDER=$!

open /Applications/Machook.app; sleep 4

log show --predicate 'subsystem == "com.machook.app" && category == "api"' \
  --info --last 1m | grep -E "unavailable|listening on"
# port 7876 unavailable, trying 7877
# listening on 127.0.0.1:7877

lsof -nP -iTCP:7877 -sTCP:LISTEN          # Machook
curl -sS http://127.0.0.1:7877/health     # {"ok":true}

# /status must admit which port it is on
curl -sS -H "Authorization: Bearer test-token" http://127.0.0.1:7877/status \
  | jq '{local_api_port, configured_api_port}'
# { "local_api_port": 7877, "configured_api_port": 7876 }

# Menu bar: "Listening on 7877 — port 7876 was busy" near the top.
# Settings → Tunnel: an orange card saying the same.
# With the tunnel on, it must point at 7877, not 7876:
log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
  --info --last 1m | grep "start() requested"
# start() requested (port=7877, mode=quick)

kill $HOLDER
```

### 11b. Both ports are taken → a loud failure

```bash
osascript -e 'quit app "Machook"'; sleep 1
python3 -m http.server 7876 --bind 127.0.0.1 >/dev/null 2>&1 & H1=$!
python3 -m http.server 7877 --bind 127.0.0.1 >/dev/null 2>&1 & H2=$!

open /Applications/Machook.app; sleep 4

log show --predicate 'subsystem == "com.machook.app" && category == "api"' \
  --info --last 1m | grep "listener failed"
# listener failed: Ports 7876 and 7877 are both in use by other apps —
# choose a different port in Settings.

# Menu bar: a "⚠ Ports 7876 and 7877 are both in use…" line at the very top.
# Settings → Tunnel: an orange warning card with the same text.
# The tunnel must NOT have started (nothing to expose):
log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
  --info --last 1m | grep "start() requested" || echo "no tunnel — correct"

kill $H1 $H2
# Then change the port in Settings → Tunnel → Advanced and Save, which
# rebuilds the listener and restarts the tunnel on whatever binds.
```

Setting **Fallback port** to `0` disables the move, which is what you want
when a named tunnel or a webhook provider has one exact port saved.

---

## 12. Settings and menu bar UX

| What to verify | Expected |
|----------------|----------|
| Menu bar → Settings…, or `⌘,` | 680×620 window, three tabs: Endpoints, Tunnel, General |
| `⌘C` / `⌘V` / `⌘X` / `⌘A` / `⌘Z` in any field | Standard behaviour (an `LSUIElement` app needs an explicit Edit menu for this) |
| Click **Save** | Green "Saved" for ~1.6 s |
| **Revert** | Fields snap back to the persisted config |
| Endpoint with an empty path or command | Inline red validation text in the row; Save refused with that message |
| Two endpoints on the same path | Save refused: "Two endpoints both claim /x" |
| Command containing `{{request.body.id}}` | "Unsupported placeholder {{request.body.id}} — only {{request}} is available"; **Done** and **Test** disabled |
| Timeout of `0` or `5000` | "Timeout must be between 1 and 3600 seconds" |
| Working directory that doesn't exist | "Working directory does not exist" |
| Endpoint on `/health`, `/status`, or `/mcp` | "… is reserved by Machook itself" |
| MCP argument schema that isn't a JSON object | "MCP input schema must be a JSON object" |
| Path typed as `ep1` or `/ep1/` | Normalized to `/ep1` on Save |
| Type `99999` in Local API port | Clamped into 1024–65535 |
| Tunnel ON with an empty bearer token | Orange warning card, and Save raises "Publish endpoints without a token?" with a destructive "Publish anyway" |
| Endpoint editor → **Test** | Runs the unsaved draft; shows `exit 0 · 34 ms` plus stdout/stderr, or "(no output)" |
| Menu with a live tunnel | URL line is clickable and copies |
| Menu while the URL is being probed | `<url> — verifying…`, tooltip says it is being checked |
| Menu with a tunnel that never answered | `⚠ <url> — <reason>`; still copyable, tooltip explains why |
| Reachability resolving while the menu is closed | The line updates on its own — the verdict can land 90 s after launch, so the menu is redrawn from an observer rather than only on open |
| Menu with >8 enabled endpoints | Shows 8 rows plus "… and N more" |
| Menu → Restart tunnel (`⌘T`) | Tunnel stops and comes back (new URL in free mode) |
| Settings → General → Launch at login | Toggle sticks; reverts itself if the system refuses |
| Settings → General → Recent runs → Clear | Empties the list (it is in-memory only and resets on relaunch anyway) |

---

## 13. Build and release pipeline (smoke only)

```bash
make clean
make build       # debug
make release     # release
make app         # signed bundle + self-containment assertions
ls -la Machook.app/Contents/MacOS/Machook

# Signature
codesign -dv --verbose=4 Machook.app 2>&1 | head -10
spctl --assess --type execute --verbose=4 Machook.app

# The bundler's own invariants (it should die on either of these):
#   - `Bundle.module` used anywhere in src/Sources
#   - Machook_Machook.bundle referenced from the built binary
#   - build-machine absolute paths embedded in the binary

# cloudflared is bundled for release builds
ls -lh Machook.app/Contents/Resources/cloudflared

# Version came from git, not by hand
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Machook.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Machook.app/Contents/Info.plist
```

Full CI (notarization, DMG, appcast) needs real Apple Developer ID and
Sparkle secrets in the repo settings; push a `v0.x.y` tag and watch
GitHub Actions. See [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md).

---

## 14. Reporting issues

```bash
# Recent logs, all categories
log show --predicate 'subsystem == "com.machook.app"' --info --last 5m > machook.log

# Runtime snapshot
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7876/status | jq

# Config — SANITIZE bearerToken and tunnelToken before sharing
defaults export com.machook.app - | python3 -c '
import plistlib, sys
print(plistlib.load(sys.stdin.buffer)["machook.config.v1"].decode())' | jq \
  '.bearerToken = "REDACTED" | .tunnelToken = "REDACTED"'

# Version
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/Machook.app/Contents/Info.plist

# Unit test result
(cd src && swift test 2>&1 | tail -20)
```

Include the exact `curl` command, the full response with headers
(`curl -i`), and the `runner`/`api` category log lines for the same
timestamp.
