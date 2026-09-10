# Troubleshooting

Symptom → cause → fix. Add to this file whenever you hit something
non-obvious.

Two commands solve most of it. First, the log:

```bash
log stream --predicate 'subsystem == "com.machook.app"' --info
```

Second, the runtime snapshot:

```bash
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7876/status | jq
```

If `/status` answers, the listener is alive and the problem is downstream
of it. If it doesn't, start at the next section.

---

## Nothing responds at all

### `curl: (7) Failed to connect to 127.0.0.1 port 7876`

**Cause 1 — you're knocking on the primary port while Machook is on the
fallback.** Machook tries `localAPIPort` (7876) and then `fallbackAPIPort`
(7877). If something already held 7876 at launch, it is serving on 7877 and
a request to 7876 reaches whatever squatted there — or nothing at all.

```bash
log show --predicate 'subsystem == "com.machook.app" && category == "api"' \
  --info --last 5m | grep -E "listening on|unavailable"
# port 7876 unavailable, trying 7877
# listening on 127.0.0.1:7877
```

The bound port is never a mystery: the menu bar carries a
`Listening on 7877 — port 7876 was busy` line, the Tunnel tab shows a
warning card saying the same, and `/status` reports it.

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7877/status | jq .local_api_port
```

Either call the port it actually bound, or free the primary and save the
config again to move it back.

**Cause 2 — both ports are taken.** Then there is no listener at all, and
the failure is reported in three places:

```bash
log show --predicate 'subsystem == "com.machook.app" && category == "api"' \
  --info --last 5m | grep "listener failed"
# listener failed: Ports 7876 and 7877 are both in use by other apps —
# choose a different port in Settings.
```

- Menu bar: a `⚠ Ports 7876 and 7877 are both in use…` line at the very
  top of the menu, above everything else.
- Settings → **Tunnel** tab: an orange warning card with the same text.
- The tunnel is not started at all, rather than being pointed at a dead
  port.

Fix: find the squatters and stop them, or move Machook:

```bash
lsof -nP -iTCP:7876 -sTCP:LISTEN
lsof -nP -iTCP:7877 -sTCP:LISTEN
```

Then Settings → Tunnel → **Advanced** → Local API port (and Fallback port)
→ free ports → **Save**. A port change rebuilds the listener, so it takes
effect immediately with no relaunch, and the tunnel is restarted against
whichever port binds:

```bash
log show --predicate 'subsystem == "com.machook.app" && category == "app"' \
  --info --last 2m | grep "ports changed"
```

Setting the fallback to `0` switches it off, which is what you want when a
named tunnel or a webhook provider has one exact port saved and you would
rather see a loud failure than a quiet move.

If you are using a named tunnel, update the Public Hostname's **Service**
in the Cloudflare dashboard to the new port too, or cloudflared will
happily accept traffic and route it to a port nothing is listening on.

**Cause 3 — the port needs privileges.** Ports below 1024 need elevated
privileges; the log says
`Port 80 needs elevated privileges — choose a port above 1024 in Settings.`
The Settings stepper already clamps to 1024–65535, so this only happens
with a hand-seeded config.

**Cause 4 — the app isn't running.** `LSUIElement` means no Dock icon, so
"I can see it" is not evidence.

```bash
pgrep -lf Machook
open /Applications/Machook.app
```

**Cause 5 — you're calling from another machine.** The listener binds
`127.0.0.1` only, deliberately. Nothing on your LAN can reach it. Remote
access goes through the tunnel URL, not the local port.

### The menu bar icon never appeared

If the process is running but there is no glyph, check the `app` category
log and `~/Library/Logs/DiagnosticReports/Machook-*.ips`. Historically
the cause here was a resource-loading `fatalError` before the first draw,
invisible because `LSUIElement` suppresses the crash dialog.
`create-app-bundle.sh` now fails the build if `Bundle.module` is used in
`src/Sources` or linked into the binary, so a bundle produced by
`make app` cannot regress into it. If you built the bundle some other
way, run `make app`.

### The app quits silently a second after launch

Almost always Sparkle. It aborts hard when `SUPublicEDKey` is not a valid
key, which is why `AppDelegate` skips the updater entirely while that
value is blank.

```bash
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  /Applications/Machook.app/Contents/Info.plist
log show --predicate 'subsystem == "org.sparkle-project.Sparkle"' --info --last 5m
```

Blank is fine (no auto-updates in dev builds). A malformed non-blank value
is the bug — clear it, or set a real key from
`scripts/sparkle-keygen.sh`.

### The app is running, the icon is there, and the port is dead

The menu bar shows a warning line, and Settings repeats it:

```
The HTTP listener on port 7876 stopped on its own. Quit and reopen Machook
to start serving again.
```

Something stopped the listener out from under the app. The usual cause is a
signal Machook did not handle — an older build treated `pkill Machook` as a
`SIGTERM` its HTTP service absorbed, shutting down the listener while the
menu bar app carried on looking healthy. Current builds route `SIGTERM` and
`SIGINT` to a normal quit, so the whole app exits:

```bash
log show --predicate 'subsystem == "com.machook.app" && category == "app"' \
  --info --last 5m | grep signal
#   received signal 15 — terminating cleanly
```

If you see the warning anyway, quit and reopen. If the app will not quit,
`kill -9` it and reopen — the next launch also cleans up any `cloudflared`
left behind (below).

### A `cloudflared` from an earlier run is still going

`kill -9` on the app leaves its tunnel child reparented to launchd, holding
a tunnel that points at the port your next launch will serve. Machook sweeps
these at startup:

```bash
log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
  --info --last 2m | grep -i stray
#   reaping stray cloudflared PID 54039 from a previous run
```

The sweep only matches the exact `cloudflared` path inside the running
`Machook.app` bundle, so your own Homebrew tunnels and other apps' tunnels
are never candidates. The flip side: a **dev build** that falls back to
`/opt/homebrew/bin/cloudflared` shares that path with everything else on the
machine, so nothing is swept and the log says so:

```
skipping stray sweep: cloudflared at /opt/homebrew/bin/cloudflared is shared, not ours
```

Clean up by hand in that case:

```bash
pgrep -lf "cloudflared tunnel .*localhost:7876"
```

---

## 401 Unauthorized

### Every request returns 401, including ones that used to work

The token is compared byte-for-byte against `Bearer <token>`. Check, in
order:

1. **The header form.** It must be `Authorization: Bearer <token>` —
   `Bearer` capitalized, exactly one space, no quotes around the token.
2. **Trailing whitespace in Settings.** The configured token is *not*
   trimmed. A trailing space pasted into the field is part of the secret.
   Re-type it.
3. **A shell that isn't expanding your variable.** `-H 'Authorization:
   Bearer $TOKEN'` in single quotes sends the literal `$TOKEN`. Use double
   quotes.
4. **You changed the token in Settings but not in the caller.** Token
   changes are live: no restart, and no grace period for the old value.

```bash
log show --predicate 'subsystem == "com.machook.app" && category == "api"' \
  --info --last 5m | grep "rejected unauthorized"
# rejected unauthorized POST /deploy
```

### `/health` works but everything else is 401

That is the design. `/health` is the only unauthenticated route, so an
uptime checker never needs the secret. `/status`, `/mcp`, and every
endpoint are gated.

### A path that doesn't exist returns 401 instead of 404

Also by design. The auth middleware runs **before** route matching, so an
unauthenticated caller cannot enumerate your endpoints. To see real 404s
you must present a valid token.

### Requests succeed with no token at all

The bearer token is empty, which disables auth entirely. That is only safe
on localhost. If the tunnel is also on, anyone who learns the URL can run
your commands — Settings shows an orange card and makes you confirm a
destructive-styled "Publish anyway" alert, but it does not stop you. Set a
token: Settings → **Tunnel** → Bearer token.

---

## 404 on an endpoint I just added

```bash
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7876/status \
  | jq '{endpoints_total, endpoints_enabled}'
```

- **`endpoints_total` didn't go up** → the endpoint was never saved. The
  editor's **Done** button is disabled while `validationError()` is
  non-nil, and **Save** in the main window refuses on the first invalid
  rule or a duplicate path, showing the reason in the save bar. Read that
  message.
- **Total went up, enabled didn't** → it is switched off. A disabled
  endpoint answers `503 {"error":"Endpoint /off is disabled"}`, not 404,
  which is exactly how you tell the two apart.
- **Both went up, still 404** → the path isn't what you think it is.

Matching is **exact after normalization**: no prefixes, no wildcards, no
patterns. `normalizePath` collapses a missing leading slash, a trailing
slash, a pasted query string, surrounding whitespace, and even a full
pasted URL, so all of `ep1`, `/ep1/`, `/ep1?x=1`, and
`https://x.trycloudflare.com/ep1` become `/ep1` — but `/ep1/deploy` is a
different endpoint from `/ep1`, and case matters. Re-open the endpoint and
read the path back; the main window shows the normalized value after
Save.

Other 404 sources:

| Response | Meaning |
|----------|---------|
| `{"error":"No endpoint configured for /x"}` | Path lookup missed |
| `{"error":"MCP is disabled in Settings"}` on `/mcp` | The MCP master switch is off (Settings → Tunnel → MCP) |
| An HTML 404 through the tunnel | Cloudflare answered, not Machook — the tunnel is pointed at the wrong local port, or its Public Hostname is misconfigured |

Reserved paths cannot be claimed at all: `/health`, `/status`, and `/mcp`
belong to the server, and the editor says
`/status is reserved by Machook itself`.

---

## 405 Method Not Allowed

```json
{"error":"/ep2 accepts POST, GET"}
```

The rule's method list doesn't include your verb. A new endpoint defaults
to **POST only**. Fix it in the editor: the method buttons are a toggle
set, and turning **all of them off** means "accept any method". Matching
is case-insensitive, so `post` and `POST` are the same thing.

Only `GET`, `POST`, `PUT`, `PATCH`, and `DELETE` reach endpoint dispatch.
Anything else (`HEAD`, `OPTIONS`, custom verbs) has no route at all.

---

## The command works in Terminal but not through Machook

This is the single most common report, and it is almost always `PATH`.

A GUI-launched app inherits a minimal environment — not your interactive
shell's. Machook's default is a **login shell** (`zsh -lc`) precisely so
your profile is sourced and Homebrew, `pyenv`, `nvm`, `rbenv` shims
resolve. Diagnose it by asking the runtime, not by assuming:

```bash
# Point a scratch endpoint at:  echo "$PATH"; command -v python3; command -v node
curl -sS -H "Authorization: Bearer $TOKEN" -d '{}' http://127.0.0.1:7876/probe
```

| What you see | Fix |
|--------------|-----|
| A short `PATH` without `/opt/homebrew/bin` | Settings → **General** → Login shell = ON |
| `command -v python3` empty even with login shell on | Your `PATH` export lives in a file a login `zsh` doesn't read (e.g. `.zshrc` only applies to interactive shells). Either move it to `.zprofile` or use absolute paths in the command |
| Everything resolves, but the command still fails | See the next causes below |

Other reasons a working command fails here:

- **Relative paths.** The working directory is the rule's
  `workingDirectory`, or your home folder when it is blank — not the
  directory you happened to be in. Use `~/projects/site` in the field (it
  is tilde-expanded) or absolute paths in the command. A directory that
  does not exist is a save-time and request-time error:
  `500 {"error":"Endpoint misconfigured: Working directory does not exist"}`.
- **Interactive-only tooling.** No TTY is attached. Tools that page
  output, prompt, or colorize by TTY detection behave differently; add
  `--no-pager`, `--yes`, `--quiet` as appropriate.
- **Secrets from your shell profile.** Environment variables exported only
  in `.zshrc` won't be there. Read them from a file in the script, or
  export them from `.zprofile`.
- **Speed.** A login shell costs a few hundred milliseconds per request.
  If every command uses absolute paths, turn Login shell off and get it
  back.

Confirm which shell actually ran:

```bash
log show --predicate 'subsystem == "com.machook.app" && category == "runner"' \
  --info --last 5m | grep "^.*run /"
# run /deploy via /bin/zsh
```

---

## 500 with a message I didn't write

| Body | Cause | Fix |
|------|-------|-----|
| `{"error":"Command exited 7","stderr":"…","exit_code":7}` | Your command failed. `stderr` is the first place to look; when stderr is empty, stdout is reported instead | Fix the script. Reproduce with the editor's **Test** button |
| `{"error":"Endpoint misconfigured: Working directory does not exist"}` | A rule that was valid at save time got broken by its surroundings | Recreate the directory or edit the rule. Rules are re-validated per request rather than handing a doomed command to the shell |
| `{"error":"Endpoint misconfigured: Unsupported placeholder {{request.body.id}} — only {{request}} is available"}` | Only `{{request}}` exists. Normally the editor blocks this before it can be saved | Read the field out of the envelope in your script (`jq -r .body.id "$1"`) |
| `{"error":"Could not stage the request file: …"}` | The envelope could not be written | Check free space and that `$TMPDIR/machook/requests` is writable |
| `{"error":"Could not start the command: …"}` | The shell itself could not be spawned | Check Settings → General → Shell points at a real executable (`/bin/zsh`, `/bin/bash`) |

`X-Machook-Exit-Code` and `X-Machook-Duration-Ms` are on every endpoint
response, so `curl -i` tells you whether the command ran at all.

---

## 504 — timed out

```json
{"error":"Command timed out after 1022 ms","exit_code":15,"stderr":"…"}
```

Exit code 15 is `SIGTERM`. At the deadline the child gets SIGTERM, then
SIGKILL two seconds later if it ignored it.

- **Raise the limit** per endpoint: editor → Timeout (1–3600 seconds).
- **Or make the endpoint asynchronous.** A webhook provider gives you
  seconds, not minutes. Have the command hand the envelope to a
  background job and exit immediately:
  `cp "$1" ~/queue/ && echo '{"accepted":true}'`. That also frees the
  concurrency slot.

Two subtleties:

- **Only the direct child is signalled.** `zsh -c` execs a single simple
  command, so for the common one-command template that child *is* your
  script — but a script that backgrounds work of its own can leave a
  grandchild running after a 504. `kill(-pid)` is deliberately not used,
  because `Process` puts the child in Machook's own process group and a
  negative pid would signal Machook too. If you background work, detach
  it properly (`nohup … &`, `disown`, or `launchctl`).
- **A grandchild holding stdout delays the response.** After the child is
  reaped, Machook waits up to 3 more seconds for the pipes to hit EOF,
  then logs `output pipes still open after exit; returning partial output`
  and answers with what it has. Redirect a background child's output:
  `mytool >/dev/null 2>&1 &`.

If the timeout is right but the request never returns at all, see the
stdin section below.

---

## Output is cut off

The response carries `X-Machook-Truncated: true` whenever stdout or
stderr hit the cap. The cap is per stream, per run:
Settings → **General** → Max captured output (KB), default 1024.

The command still runs to completion — output past the cap is discarded
but still drained, because stopping the read would leave the child blocked
on a full pipe and it would never exit. So a truncated response never
means a truncated *run*.

If you need the full output, write it to a file in the script and return a
summary. That is cheaper than raising the cap for every request.

---

## `{{request}}` — file missing, empty, or unreadable

### "No such file or directory" inside the script

The envelope is deleted in a `defer` as soon as the command exits, so any
background work that reads it later finds nothing. Copy it first:

```bash
cp "$1" /tmp/my-job-$$.json   # then hand the copy to the background job
```

### The path is empty, or I see the literal text `{{request}}`

`{{request}}` must appear in the **Command** field of the endpoint, and it
must not be quoted — Machook quotes it for you, and a matched pair of
quotes around the placeholder is absorbed. If your command doesn't
reference it at all, the file is still written; read
`$MACHOOK_REQUEST_FILE` instead:

```bash
payload="${1:-$MACHOOK_REQUEST_FILE}"
jq -r '.body.ref' "$payload"
```

### I want to look at a real envelope

Settings → **General** → **Keep request files** = ON, then:

```bash
DIR="$(getconf DARWIN_USER_TEMP_DIR)machook/requests"
ls -lt "$DIR" | head
jq . "$DIR"/$(ls -t "$DIR" | head -1)

log show --predicate 'subsystem == "com.machook.app" && category == "runner"' \
  --info --last 5m | grep "kept request envelope"
```

Turn it back off when you're done: payloads routinely carry API tokens and
signatures, which is why the directory is `0700`, the files are `0600`,
and they live under the per-user temp directory rather than
world-readable `/tmp`. Leftovers older than 6 hours are swept at launch.

### `body` is `null` but I definitely sent a body

`body` is the *parsed* payload and is `null` when the payload isn't JSON.
`body_raw` always holds the text as sent (form-encoded, XML, plain text),
and a non-UTF-8 payload appears as `body_base64` instead of `body_raw`.
Check `body_bytes` to confirm anything arrived at all.

### `headers.authorization` is missing

Deliberate. The `Authorization` header is stripped before the envelope is
written — the script has no use for Machook's own bearer token and it
would otherwise be written to disk on every request. If you need to verify
a provider signature, those live in their own headers (`x-hub-signature-256`,
`stripe-signature`) and are all present.

---

## The script hangs and every request times out

The classic cause is reading stdin. Machook attaches `/dev/null`, not a
pipe, exactly so `cat`, `read`, and `while read line` return immediately
instead of blocking forever on a descriptor nobody will ever write to.

So if a request hangs until the timeout, it is your command waiting on
something else:

- A tool prompting for confirmation → add its non-interactive flag.
- `ssh`/`scp` waiting on a host-key prompt or a passphrase → use
  `-o BatchMode=yes` and a key already in the agent (note the GUI session
  may not have your agent socket).
- `git push` over HTTPS waiting on credentials → use SSH or a credential
  helper that doesn't prompt.
- A lock file or a network call with no timeout of its own.

Confirm which side is stuck:

```bash
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7876/status | jq .active_runs
ps -ax -o pid,etime,command | grep -v grep | grep zsh
```

`active_runs` staying above zero means the child is alive and Machook is
waiting on it.

---

## 503 Service Unavailable

Two different meanings, and the body disambiguates:

| Body | Cause | Fix |
|------|-------|-----|
| `{"error":"Endpoint /off is disabled"}` | The rule exists but its switch is off | Toggle it on in Settings → Endpoints and Save |
| `{"error":"Too many commands already running (limit 4)"}` | Every concurrency slot is busy | See below |

The concurrency budget exists so a provider retrying in a loop cannot
fork-bomb the Mac. When you hit it:

1. Check what's holding the slots: `/status` → `active_runs`, and the
   `runner` log.
2. Make the commands finish faster, or return immediately and do the work
   in the background — a long-running endpoint holds its slot for its
   whole duration.
3. Only then raise Settings → **General** → Max concurrent commands
   (1–64). Every slot is a real process, so this is a real resource
   decision.

---

## 413 — request body too large

```json
{"error":"Request body exceeds 10 MB"}
```

Settings → **General** → Max request body (MB), 1–1024. Note this governs
endpoint dispatch only; `POST /mcp` has its own fixed 1 MB limit for the
JSON-RPC envelope, so a huge base64 argument in a tool call will fail
regardless of this setting.

---

## The tunnel won't connect

### The toggle is on but no URL appears

```bash
log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
  --info --debug --last 5m
```

**`start() failed: cloudflared binary not found in bundle or on PATH`** —
you get an alert with a "Copy install command" button. Lookup order:

```
1. Machook.app/Contents/Resources/cloudflared   (bundled by release builds)
2. /opt/homebrew/bin/cloudflared                (Apple Silicon Homebrew)
3. /usr/local/bin/cloudflared                   (Intel Homebrew)
4. /usr/bin/cloudflared
5. /usr/bin/which cloudflared
```

```bash
brew install cloudflared
```

Then Restart tunnel from the menu (`⌘T`), or toggle it off and on.

**`failed to launch cloudflared: …`** — the binary was found but would not
execute. Usually one of:

- **Not executable.** `ls -l` it; the bundler `chmod +x`es its copy, a
  hand-placed one might not be.
- **Wrong architecture.** Released bundles ship a universal `cloudflared`
  covering both slices, but a dev build copies whatever is on your `PATH`,
  which may be thin. Check with `lipo -archs` — if it lacks your Mac's
  architecture, rebuild with `make app` to fetch a merged copy.
- **Blocked by Gatekeeper.** A dev bundle copies whatever `cloudflared`
  is on your `PATH` into `Contents/Resources` and signs it with the same
  identity as the app; if you replaced that file *after* signing, the
  bundle's signature no longer covers it and macOS can refuse to run it.
  Fix by rebuilding (`make app`), or by deleting the bundled copy so the
  Homebrew one on `PATH` is used:

  ```bash
  file "/Applications/Machook.app/Contents/Resources/cloudflared"
  codesign -dv --verbose=4 "/Applications/Machook.app/Contents/Resources/cloudflared"
  spctl --assess --type execute -vv "/Applications/Machook.app/Contents/Resources/cloudflared"
  ```

**cloudflared spawns and exits within ~40 ms, status 0.** The signature is
unmistakable in the log:

```
start() requested (port=7876, mode=named)
spawning cloudflared: tunnel run --no-autoupdate
cloudflared spawned, PID 16253
cloudflared exited (status=0, reason=1)          ← ~40ms later
```

The connector token is not in that line because it is passed through the
`TUNNEL_TOKEN` environment variable: argv is readable by every process on the
machine via `ps`, and the token alone is enough to publish traffic through
your tunnel.

`--no-autoupdate` is a `tunnel` subcommand flag, not a `run` flag. Placed
after `run`, cloudflared rejects the CLI, prints help, and exits cleanly.
The current argv is `tunnel --no-autoupdate run --token …`; if you see the
other order, you are on an old build. Reproduce by hand with the argv from
the log (substituting your real token) to see cloudflared's own
complaint.

**Network can't reach Cloudflare's edge.** Take Machook out of it:

```bash
cloudflared tunnel --url http://127.0.0.1:7876
```

### `Couldn't resolve the hostname` / `curl: (6) Could not resolve host`

The menu shows a `*.trycloudflare.com` URL, cloudflared logged
`Registered tunnel connection`, and nothing on the internet can reach it.
The URL was never in DNS.

Quick tunnels are assigned a hostname before the record is published, and
occasionally Cloudflare never publishes it. cloudflared has no idea: from
its side the connection to the edge is up and healthy, which is why the app
used to show the URL as if it worked.

Machook now checks. Within about 90 seconds of a URL appearing it fetches
`<url>/health` from the outside and reports what it found:

```bash
curl -s http://127.0.0.1:7876/status | python3 -m json.tool | grep reach
#   "tunnel_reachability": "unreachable",
#   "tunnel_reachability_note": "hostname is not in DNS — Cloudflare never published it",
```

The menu bar line and Settings show the same warning. Confirm it yourself:

```bash
dig +short your-hostname.trycloudflare.com @1.1.1.1   # empty = NXDOMAIN
dig +short trycloudflare.com @1.1.1.1                 # control: should answer
```

An empty answer for your hostname while the control resolves means the
record was never published, and no amount of restarting the app changes
that. What to do:

1. **Restart tunnel** (`⌘T`) to request a different hostname. It often works
   on the next attempt.
2. If it keeps happening, switch to a **named tunnel** on a hostname you
   own: Settings → **Tunnel** → Mode → **Named (custom domain)**. The DNS
   record is one you created, so it cannot silently fail to exist.

Other verdicts you may see in that field:

| Note | Meaning |
|---|---|
| `Cloudflare has no connector for this hostname (1033)` | DNS resolves, the edge has no tunnel registered. Restart the tunnel. |
| `tunnel is up but nothing answered locally (502)` | The tunnel works; our own listener is down or on another port. Check `local_api_port` in `/status`. |
| `blocked by Cloudflare Access (403)` | An Access policy is challenging the request. Add a service-token bypass for the webhook path. |
| `this Mac is offline` | No route to the internet from here. |
| `timed out` / `cannot connect` / `TLS failed` | Transport-level failure to Cloudflare's edge; usually local network or a captive portal. |

### The quick-tunnel URL changed after a restart

Working as designed. `*.trycloudflare.com` URLs are ephemeral: cloudflared
gets a new random hostname every time the process starts, including when
you use **Restart tunnel** or change any tunnel field.

If whatever is calling you can't follow a rotating URL — a webhook
provider with the address saved in its dashboard, an MCP client with it in
a config file, a cron job — switch to a named tunnel: Settings → **Tunnel**
→ Mode → **Named (custom domain)**. That is the entire reason the mode
exists.

### Named tunnel: Settings shows the hostname but nothing routes

Named mode pre-populates the URL from your config rather than waiting for
cloudflared, because the hostname is decided on the Cloudflare side. So a
hostname in the menu bar proves only that you typed it in — not that it
resolves.

```bash
dig +short hooks.yourcompany.com
# Expected: <tunnel-uuid>.cfargotunnel.com.
curl -sS https://hooks.yourcompany.com/health
```

Check in this order:

1. **Both fields filled?** Named mode with an empty token or hostname
   never spawns cloudflared at all — you get the "Cloudflare named tunnel
   not configured" alert with an "Open Settings" button, and the log says
   `named tunnel selected but token or hostname is empty`.
2. **Public Hostname configured in the dashboard?** The connector token
   authorizes cloudflared to *serve*; it cannot create DNS records or
   routes. Zero Trust → Networks → Tunnels → your tunnel → **Public
   Hostnames** → Add: your subdomain, your domain, service type `HTTP`,
   URL `localhost:<your local API port>`. Cloudflare creates the proxied
   CNAME for you. If it refuses because "a record with that host already
   exists", delete the conflicting DNS record (or the Worker / Pages /
   Email Routing binding) first.
3. **Port match?** The Public Hostname's service port must equal
   Settings → Tunnel → Advanced → Local API port. A mismatch looks like
   "tunnel is up, requests time out" — Cloudflare answers, Machook never
   sees the request.
4. **Token still valid?** Rotating the token in the dashboard invalidates
   the old one immediately. Re-copy it from Configure → Install and run a
   connector.
5. **Did it register?** Look for cloudflared's own line — this is the
   readiness signal Machook watches for in named mode:

   ```bash
   log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
     --info --debug --last 5m | grep -E "Registered tunnel connection|failed to register"
   ```

6. **Try the token by hand.** If `cloudflared tunnel run --token <token>`
   also fails to register, the problem is on the Cloudflare side.

Pasting the hostname with a scheme or a trailing slash is fine —
`normalizeHostname` strips `http://`, `https://`, and trailing slashes, so
`tunnel_url` is always `https://<bare-host>`.

### The tunnel URL is right but every request 404s with Cloudflare's page

Cloudflare is answering, not Machook. Either the Public Hostname points at
the wrong local port, or the tunnel connector is down. Compare
`/status`'s `tunnel_running` (Machook's view of its child process) with
the connector status in the Cloudflare dashboard.

---

## MCP: the client sees no tools

Work down the list; each step eliminates one layer.

```bash
MCP=(-X POST http://127.0.0.1:7876/mcp
     -H "Authorization: Bearer $TOKEN"
     -H 'Content-Type: application/json' -H 'Accept: application/json')
curl -sS "${MCP[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq
```

| Result | Cause | Fix |
|--------|-------|-----|
| `404 {"error":"MCP is disabled in Settings"}` | Master switch off | Settings → **Tunnel** → MCP → "Expose endpoints as MCP tools" |
| `401` | No or wrong bearer token | MCP uses the same token as everything else |
| An error about accepting `application/json` | Missing `Accept` header | The SDK's validator requires it explicitly; `curl` does not send it by default. A real MCP client does |
| An error about content type | Missing `Content-Type: application/json` | Add it |
| `result.tools` is `[]` | No endpoint qualifies | See below |
| Tools listed here but not in your client | Client-side config | See below |

An endpoint appears in `tools/list` only when **all** of these hold — the
catalog is rebuilt from live config on every call, so there is nothing to
restart:

- the endpoint is enabled,
- its "Expose as a tool" switch is on,
- and `validationError()` is nil (a broken rule is dropped from the
  catalog rather than failing at call time).

`Settings → Tunnel → MCP → Tools published` shows the same count that
`/status` reports as `mcp_tools`; compare it against
`endpoints_enabled`.

### `tools/call` says `Unknown tool: x`

The name isn't in the live catalog. Either the endpoint is excluded for
one of the three reasons above, or the name isn't what you assumed.
Default names drop the leading slash and collapse anything outside
`[A-Za-z0-9_-]` to a single `_` (`/github/push` → `github_push`), and two
endpoints resolving to the same name get a `_2` suffix — so a collision
can rename the one you meant to call. Read the truth from `tools/list`
rather than guessing, or set an explicit **Tool name** in the editor.

### The client asks for approval on every call

Unannotated MCP tools are treated as potentially destructive, which is the
correct default for "runs an arbitrary shell command". For endpoints that
only report something, turn on **Read-only** in the editor's MCP section;
that adds the read-only hints and well-behaved clients stop gating them.

### The model passes arguments and the script sees nothing

Tool arguments arrive as the envelope's **`body`**, with `source` set to
`"mcp"` and `method` to `"MCP"`. There are no query parameters and no
headers on an MCP call. Read `jq -r '.body.whatever' "$1"`.

### The client connects but times out on big payloads

`POST /mcp` collects at most 1 MB, independent of the Max request body
setting. Base64 arguments hit that quickly.

---

## Gatekeeper on first launch

### "Machook cannot be opened because the developer cannot be verified"

A build that wasn't signed with a Developer ID and notarized — a local
`make app` on a machine with no signing identity falls back to ad-hoc
signing. Either build with an identity:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
```

or approve it once: right-click the app → **Open** → Open, or System
Settings → Privacy & Security → "Open Anyway".

### "Machook is damaged and can't be opened"

Usually the quarantine flag plus a signature that no longer matches
because something in the bundle was edited after signing.

```bash
xattr -l /Applications/Machook.app
xattr -dr com.apple.quarantine /Applications/Machook.app
codesign --verify --deep --strict --verbose=2 /Applications/Machook.app
spctl --assess --type execute -vv /Applications/Machook.app
```

If `codesign --verify` fails, rebuild rather than patching:
`make clean && make app`. Official release ZIPs are notarized and stapled,
so `spctl` should report `source=Notarized Developer ID`.

---

## Settings changes seem to be ignored

Most of the config is read live, per request. If a change didn't take
effect, one of these applies:

| Changed | When it applies |
|---------|-----------------|
| Endpoint table, commands, timeouts, methods, MCP flags | Next request — resolved from live config, not registered at boot |
| Bearer token, execution limits, shell, login shell, keep-request-files | Next request |
| Local API port | Immediately, by rebuilding the listener |
| Tunnel enabled / mode / token / hostname | Immediately, by restarting cloudflared |

So "nothing changed" almost always means **the Save didn't happen**. Look
at the save bar: it shows a red message with the reason (an invalid rule,
or `Two endpoints both claim /x`) instead of the green "Saved".

Two more gotchas:

- **`⌘V` not pasting.** An `LSUIElement` app has no default main menu, so
  `installMainMenu()` installs App and Edit submenus to bind
  `⌘C/⌘V/⌘X/⌘A/⌘Z`. If they no-op, you are on a build where that is
  broken or the window isn't key — click into the field first.
- **You seeded `UserDefaults` while the app was running.** The config is
  read once, when the store is first touched; and the next **Save**
  rewrites the whole blob from what the Settings window is showing, so
  your seeded values disappear. Quit the app, seed, relaunch.

---

## Where things live

| What | Where |
|------|-------|
| Settings | `UserDefaults` domain `com.machook.app`, key `machook.config.v1` (a JSON blob) — `~/Library/Preferences/com.machook.app.plist` |
| Request envelopes | `$TMPDIR/machook/requests/` (`getconf DARWIN_USER_TEMP_DIR`), mode `0700`, files `0600`, deleted after each run |
| Recent runs | Memory only, last 100, cleared on relaunch |
| App bundle | `/Applications/Machook.app`, or `./Machook.app` for a dev build |
| Bundled cloudflared | `Machook.app/Contents/Resources/cloudflared` (release builds) |
| Login item | Registered via `SMAppService`; System Settings → General → Login Items |
| Build artifacts | `src/.build/` (gitignored) |
| Crash reports | `~/Library/Logs/DiagnosticReports/Machook-*.ips` |

Read the config as JSON (the value is `Data`, so `defaults read` prints an
unhelpful hex summary):

```bash
defaults export com.machook.app - | python3 -c '
import plistlib, sys
print(plistlib.load(sys.stdin.buffer)["machook.config.v1"].decode())' | jq .
```

Reset everything:

```bash
osascript -e 'quit app "Machook"'; sleep 1
defaults delete com.machook.app
open /Applications/Machook.app
```

---

## Logs

Five categories, one subsystem:

```bash
# Live
log stream --predicate 'subsystem == "com.machook.app"' --info

# Last 5 minutes, everything
log show --predicate 'subsystem == "com.machook.app"' --info --last 5m

# Per category
log show --predicate 'subsystem == "com.machook.app" && category == "app"'    --info --last 5m
log show --predicate 'subsystem == "com.machook.app" && category == "api"'    --info --last 5m
log show --predicate 'subsystem == "com.machook.app" && category == "runner"' --info --last 5m
log show --predicate 'subsystem == "com.machook.app" && category == "mcp"'    --info --last 5m

# cloudflared's own stderr is logged at debug level, so it needs --debug
log show --predicate 'subsystem == "com.machook.app" && category == "tunnel"' \
  --info --debug --last 5m
```

| Category | What lands there |
|----------|------------------|
| `app` | Boot, port changes, login-item failures |
| `api` | Listener start/stop and bind failures, rejected auth, one line per request: `/deploy → 200 in 63ms` |
| `runner` | `run /deploy via /bin/zsh`, timeout escalation, kept/swept envelopes, pipes still open after exit |
| `mcp` | `tool deploy → 200 in 63ms`, tool errors |
| `tunnel` | Spawn argv (token redacted), URL resolution, registration, process exit status |

Payload contents are never logged, and the connector token is redacted at
the one place it would otherwise appear. Paths, statuses, and durations are
marked public so they are readable without a debugger attached.
