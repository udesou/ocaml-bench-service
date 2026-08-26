#!/usr/bin/env bash
# Serve the public runs index (§10): a static page over <state>/webview/.
#
#   scripts/webview.sh [port]        # default 8080
#
# No sudo, no nginx: python3's http.server is enough for the prototype --
# the §10 model is "any static file host over the store's public files", and
# until API C exists the state directory IS the store-in-waiting.  The page
# polls runs.json, which bench-serve rewrites on every state change; this
# script only copies the page in and serves the directory read-only.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${BENCH_STATE_DIR:-$HOME/.ocaml-bench-service}"
PORT="${1:-8080}"

mkdir -p "$STATE/webview"
cp "$ROOT/webview/index.html" "$STATE/webview/index.html"
[ -f "$STATE/webview/runs.json" ] \
  || printf '{"generated_at":null,"runs":[]}\n' > "$STATE/webview/runs.json"

echo "webview: serving $STATE/webview on http://0.0.0.0:$PORT/"
exec python3 -m http.server "$PORT" --directory "$STATE/webview" --bind 0.0.0.0
