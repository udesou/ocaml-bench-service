#!/usr/bin/env bash
# Start (or stop) the whole service side under ONE screen session:
#
#   scripts/start_server.sh [start|stop|status]
#
# One session named "bench", three windows -- each script is a foreground
# process that never returns, so they cannot share a shell:
#
#   serve      scripts/serve.sh              the request server (capnp)
#   webview    scripts/webview.sh            the runs index (static http)
#   bot        bot/poll.sh                   the PR comment poller (gh auth)
#   dashboards scripts/dashboard_builder.sh  per-run dashboard builds (node)
#
# Attach with `screen -r bench` (Ctrl-a d detaches, Ctrl-a " lists windows).
# Logs also land in the state dir (serve.log / webview.log / bot.log), which
# is where bump failures and internal-error incident ids (i-xxxxxx) live.
#
# Configuration comes from server.env exactly as serve.sh reads it, plus:
#   BENCH_WEBVIEW_PORT   (default 8080)
#   BENCH_BOT_REPO       (default udesou/ocaml; empty skips the bot)
#   BENCH_BOT_INTERVAL   (default 20 seconds)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION=bench

command -v screen >/dev/null || { echo "screen is not installed"; exit 1; }

# the same env file serve.sh loads, for BENCH_STATE_DIR etc.
ENV_FILE="${BENCH_ENV_FILE:-$ROOT/server.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${BENCH_STATE_DIR:=$HOME/.ocaml-bench-service}"
: "${BENCH_WEBVIEW_PORT:=8080}"
: "${BENCH_BOT_REPO:=udesou/ocaml}"
: "${BENCH_BOT_INTERVAL:=20}"

case "${1:-start}" in
stop)
  screen -S "$SESSION" -X quit 2>/dev/null \
    && echo "stopped session '$SESSION'" \
    || echo "no session '$SESSION' running"
  exit 0
  ;;
status)
  screen -ls | grep -q "\.$SESSION\b" \
    && { screen -ls | grep "\.$SESSION\b"; exit 0; } \
    || { echo "no session '$SESSION' running"; exit 1; }
  ;;
start) ;;
*)
  echo "usage: $0 [start|stop|status]"
  exit 2
  ;;
esac

if screen -ls 2>/dev/null | grep -q "\.$SESSION\b"; then
  echo "session '$SESSION' already running -- attach with: screen -r $SESSION"
  echo "(stop it first with: $0 stop)"
  exit 1
fi

mkdir -p "$BENCH_STATE_DIR"

window() {
  local title="$1" cmd="$2"
  screen -S "$SESSION" -X screen -t "$title" bash -c "cd $(printf %q "$ROOT") && $cmd"
}

# window 0 comes with the session; the rest are added to it.  -h raises
# screen's per-window history from its default 100 lines -- the tee'd logs
# in the state dir remain the authoritative record either way.
screen -h 5000 -dmS "$SESSION" -t serve bash -c \
  "cd $(printf %q "$ROOT") && scripts/serve.sh 2>&1 | tee -a $(printf %q "$BENCH_STATE_DIR")/serve.log"
window webview "scripts/webview.sh $BENCH_WEBVIEW_PORT 2>&1 | tee -a $(printf %q "$BENCH_STATE_DIR")/webview.log"

if [ -z "$BENCH_BOT_REPO" ]; then
  echo "note: BENCH_BOT_REPO empty -- bot not started"
elif gh auth status >/dev/null 2>&1; then
  window bot "bot/poll.sh $(printf %q "$BENCH_BOT_REPO") $BENCH_BOT_INTERVAL 2>&1 | tee -a $(printf %q "$BENCH_STATE_DIR")/bot.log"
else
  echo "warning: gh is not authenticated -- bot not started (run 'gh auth login', then: $0 stop && $0)"
fi

if command -v node >/dev/null 2>&1; then
  window dashboards "scripts/dashboard_builder.sh 2>&1 | tee -a $(printf %q "$BENCH_STATE_DIR")/dashboards.log"
else
  echo "warning: node not installed -- per-run dashboards not built (webview pages still work)"
fi

sleep 2
echo "session '$SESSION' up -- attach: screen -r $SESSION"
screen -S "$SESSION" -Q windows 2>/dev/null || true
echo
echo "logs: $BENCH_STATE_DIR/{serve,webview,bot}.log"
