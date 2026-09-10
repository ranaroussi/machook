# Examples

Sample endpoint scripts. Each one is written against the same contract: Machook
hands the script a JSON file describing the request, reads stdout as the
response body, and maps the exit code to an HTTP status.

| Script | What it shows |
|--------|---------------|
| `log-request.sh` | Reading the `{{request}}` envelope, copying it somewhere durable before Machook deletes it, returning JSON, and failing on purpose to exercise the 500 path |

## Wiring one up

Menu bar icon → **Settings…** → **Endpoints** → **+**, then:

| Field | Value |
|-------|-------|
| Path | `/log` |
| Command | `bash /absolute/path/to/machook/examples/log-request.sh {{request}}` |
| Methods | `POST, GET` |
| Timeout | `30` |

Use an absolute path. Commands run through `zsh -lc` from your home directory
unless you set a working directory, so a relative path resolves somewhere you
probably did not intend.

The **Test** button in the editor runs the command against a synthetic request
and shows you stdout, stderr, and the exit code without any HTTP involved.
That is the fastest way to iterate on a script.

## Trying it

With no bearer token set, the local listener accepts unauthenticated requests
from localhost, which keeps the first test short:

```bash
curl -sS -X POST 'http://127.0.0.1:7876/log?source=test' \
  -H 'Content-Type: application/json' \
  -d '{"event":"push","repo":"machook","n":3}'
```

You get a JSON summary back, and the full record lands in
`~/Library/Logs/machook/requests.log`:

```bash
tail -40 ~/Library/Logs/machook/requests.log
```

Exercise the failure mapping:

```bash
curl -i 'http://127.0.0.1:7876/log?fail=1'      # 500, stderr as the body
```

Watch the response metadata Machook attaches:

```bash
curl -sS -D - -o /dev/null -X POST http://127.0.0.1:7876/log -d 'hi'
# X-Machook-Exit-Code: 0
# X-Machook-Duration-Ms: …
```

Once you set a bearer token in Settings (required before the tunnel will
publish), every route except `/health` needs it:

```bash
curl -sS -X POST http://127.0.0.1:7876/log \
  -H "Authorization: Bearer $TOKEN" -d '{}'
```

## The same endpoint as an MCP tool

Endpoints with MCP enabled show up as tools on `POST /mcp`, named after the
path (`/log` → `log`) unless you override the tool name:

`Accept: application/json` is not optional here. The MCP transport rejects a
request without it (`-32600 … Client must accept application/json`), which
looks like a broken server if you leave it off.

```bash
MCP=(-sS -X POST http://127.0.0.1:7876/mcp
     -H 'Content-Type: application/json' -H 'Accept: application/json')

curl "${MCP[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

curl "${MCP[@]}" -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"log","arguments":{"event":"from-mcp"}}}'
```

Tool arguments arrive as the envelope's `body`. The envelope also tells a
script how it was invoked: `source` is `"http"` or `"mcp"`, and for an MCP call
`method` is `"MCP"` rather than a real HTTP verb — so one script can serve both
without guessing.

## Writing your own

- **Read the envelope, don't trust the shell.** The command template is yours
  and is the only string Machook hands to the shell parser. Everything from the
  caller reaches you inside that JSON file, never as shell text. Keep it that
  way: read fields out of the file rather than interpolating them into further
  commands.
- **Copy anything you want to keep.** The envelope file is deleted the moment
  your command exits.
- **stdout is the response.** Debug chatter belongs on stderr, or it ends up in
  the body your caller sees.
- **Exit non-zero to signal failure.** stderr becomes the response body, so
  make the message something the caller can act on.
- **Mind the timeout.** Machook sends `SIGTERM`, then `SIGKILL` two seconds
  later, and answers `504`. Long jobs should hand off to something detached and
  return immediately.
