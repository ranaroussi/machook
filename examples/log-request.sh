#!/usr/bin/env bash
#
# Sample Machook endpoint: record the incoming request, then answer it.
#
# Wire it up in Settings → Endpoints with a command like:
#
#     bash ~/Projects/machook/examples/log-request.sh {{request}}
#
# Machook replaces `{{request}}` with the path to a JSON file describing the
# request — method, path, query, headers, parsed body, raw body. The file is
# mode 0600 in a 0700 directory, and Machook deletes it as soon as this script
# exits, so anything worth keeping has to be copied out *now*. That is most of
# what this sample demonstrates.
#
# The contract this script is written against:
#
#   stdout    → the HTTP response body (JSON here, so Machook sniffs
#               application/json and MCP clients get structured content)
#   stderr    → discarded on success; returned as the body on a failing exit
#   exit 0    → 200
#   exit != 0 → 500, with stderr as the body
#
# Add `?fail=1` to any request to exercise that failure path on purpose.
#
# Overridable via the environment (set these in the endpoint's command if you
# want, e.g. `MACHOOK_LOG_DIR=/tmp/hooks bash …/log-request.sh {{request}}`):
#
#   MACHOOK_LOG_DIR         where to write   (default ~/Library/Logs/machook)
#   MACHOOK_LOG_MAX_BYTES   rotate above this size (default 5 MiB)
#
set -euo pipefail

# Machook passes the envelope path as the first argument, and also exports it
# as MACHOOK_REQUEST_FILE. Accept either so the script still works if you
# forget the `{{request}}` placeholder in the command template.
REQUEST_FILE="${1:-${MACHOOK_REQUEST_FILE:-}}"

LOG_DIR="${MACHOOK_LOG_DIR:-$HOME/Library/Logs/machook}"
LOG_FILE="$LOG_DIR/requests.log"
MAX_LOG_BYTES="${MACHOOK_LOG_MAX_BYTES:-5242880}"

if [ -z "$REQUEST_FILE" ]; then
    echo "log-request.sh: no request file — pass {{request}} as the first argument" >&2
    exit 64
fi
if [ ! -f "$REQUEST_FILE" ]; then
    # Reachable if the endpoint's command quotes the placeholder oddly, or if
    # something else already cleaned up the staging directory.
    echo "log-request.sh: request file not found: $REQUEST_FILE" >&2
    exit 66
fi

# The envelope carries the caller's request headers, which for a real webhook
# means signatures and sometimes tokens. Machook stages it as 0600 in a 0700
# directory; a log that copies it out has no business being more readable than
# the thing it copied. umask covers files this script creates, and the explicit
# modes fix up a log directory that already exists from an earlier run.
umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true

# A webhook endpoint gets hit as often as whoever is calling it decides to, so
# an append-only log needs *some* bound. One generation is enough to keep the
# last few thousand requests without growing without limit.
if [ -f "$LOG_FILE" ]; then
    log_size="$(wc -c < "$LOG_FILE" | tr -d ' ')"
    if [ "$log_size" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
fi

# python3 is used only for pretty-printing and field extraction. It ships with
# the Xcode command line tools rather than a bare macOS, so every use below
# degrades to something sensible when it is missing.
if command -v python3 >/dev/null 2>&1; then
    HAVE_PYTHON=1
else
    HAVE_PYTHON=0
fi

{
    printf '===== %s =====\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [ "$HAVE_PYTHON" = 1 ]; then
        python3 -m json.tool "$REQUEST_FILE" || cat "$REQUEST_FILE"
    else
        cat "$REQUEST_FILE"
    fi
    printf '\n'
} >> "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

# Deliberate-failure hook, so you can see the 500 + stderr mapping without
# editing this file. Checked before writing stdout because a failing exit
# discards stdout entirely.
if [ "$HAVE_PYTHON" = 1 ]; then
    FAIL="$(python3 -c '
import json, sys
q = json.load(open(sys.argv[1])).get("query") or {}
print(q.get("fail", ""))
' "$REQUEST_FILE" 2>/dev/null || true)"
    if [ -n "${FAIL:-}" ]; then
        echo "log-request.sh: failing on purpose (fail=$FAIL). Request was still logged to $LOG_FILE." >&2
        exit 3
    fi
fi

# The response. Echoing a summary rather than the whole envelope keeps request
# headers — which can carry sender-side tokens and signatures — out of the HTTP
# response, while the full record is still on disk for you to inspect.
if [ "$HAVE_PYTHON" = 1 ]; then
    python3 - "$REQUEST_FILE" "$LOG_FILE" <<'PY'
import json, sys

envelope = json.load(open(sys.argv[1]))
print(json.dumps({
    "ok": True,
    "logged_to": sys.argv[2],
    "id": envelope.get("id"),
    "source": envelope.get("source"),
    "received_at": envelope.get("received_at"),
    "method": envelope.get("method"),
    "path": envelope.get("path"),
    "query": envelope.get("query"),
    "header_count": len(envelope.get("headers") or {}),
    "body_bytes": envelope.get("body_bytes"),
    "body": envelope.get("body"),
}, indent=2))
PY
else
    printf '{"ok":true,"logged_to":"%s","envelope_bytes":%s}\n' \
        "$LOG_FILE" "$(wc -c < "$REQUEST_FILE" | tr -d ' ')"
fi
