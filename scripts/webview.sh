#!/usr/bin/env bash
# Serve the runs index: python3's http.server over <state>/webview/.
#
#   scripts/webview.sh [port]        # default 8080
#
# The page polls runs.json, which bench-serve rewrites on every state change.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${BENCH_STATE_DIR:-$HOME/.ocaml-bench-service}"
PORT="${1:-8080}"

mkdir -p "$STATE/webview" "$STATE/runs" "$STATE/webview/dashboards"
cp "$ROOT/webview/index.html" "$STATE/webview/index.html"
cp "$ROOT/webview/run.html" "$STATE/webview/run.html"
[ -f "$STATE/webview/runs.json" ] \
  || printf '{"generated_at":null,"runs":[]}\n' > "$STATE/webview/runs.json"
# The per-run pages read the run bundles; the bundle directory is the store in
# v1, so publishing it is a symlink (http.server follows symlinks).
[ -e "$STATE/webview/runs" ] || ln -s ../runs "$STATE/webview/runs"

echo "webview: serving $STATE/webview on http://0.0.0.0:$PORT/"
exec python3 -m http.server "$PORT" --directory "$STATE/webview" --bind 0.0.0.0
