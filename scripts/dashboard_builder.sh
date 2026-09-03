#!/usr/bin/env bash
# Build a per-run dashboard for every finished run that lacks one (§10).
#
#   scripts/dashboard_builder.sh [interval-seconds]
#
# A foreground poller like the bot: scans the webview's runs.json, and for
# each run that is done, has contract measurements, and has no dashboard yet,
# runs the ocaml-bench-dashboard build (BENCH_RUN_DIR=<bundle> npm run build,
# a fully static site with relative asset paths) and publishes dist/ under
# <state>/webview/dashboards/<run_id>/.  The per-run page links it as soon as
# it exists.
#
# A failed build leaves dashboards/<run_id>.failed with the log and is not
# retried until that file is removed -- a broken run must not wedge the
# builder in a loop.
#
# v0.1 builds from the WORKING dashboard checkout; the dashboard PIN (bump)
# deciding when existing dashboards are rebuilt is future work, so the pin
# commit is recorded next to each build for that day.
#
# Env: BENCH_STATE_DIR (default ~/.ocaml-bench-service)
#      DASHBOARD_REPO  (default ~/ocaml-bench-dashboard; needs `npm install`
#                       and bin/ingest built once, per its README)

set -euo pipefail
STATE="${BENCH_STATE_DIR:-$HOME/.ocaml-bench-service}"
REPO="${DASHBOARD_REPO:-$HOME/ocaml-bench-dashboard}"
INTERVAL="${1:-30}"

command -v node >/dev/null || { echo "dashboards: node not installed"; exit 1; }
command -v python3 >/dev/null || { echo "dashboards: python3 not installed"; exit 1; }
[ -d "$REPO/node_modules" ] \
  || { echo "dashboards: $REPO has no node_modules (run npm install there)"; exit 1; }
[ -x "$REPO/bin/ingest" ] \
  || { echo "dashboards: $REPO/bin/ingest missing (build it per its README)"; exit 1; }

OUT="$STATE/webview/dashboards"
mkdir -p "$OUT"
echo "dashboards: watching $STATE/webview/runs.json (every ${INTERVAL}s, repo $REPO)"

# run_ids that are done, newest first
done_runs() {
  python3 - "$STATE/webview/runs.json" <<'EOF'
import json, sys
try:
    runs = json.load(open(sys.argv[1]))["runs"]
except Exception:
    runs = []
for r in runs:
    if r.get("state") == "done":
        print(r["run_id"])
EOF
}

while true; do
  for run in $(done_runs); do
    bundle="$STATE/runs/$run"
    [ -f "$bundle/contract/manifest.json" ] || continue   # nothing to show
    if [ -e "$OUT/$run/index.html" ]; then
      # a continued run updates its contract in place: rebuild if newer
      [ "$bundle/contract/manifest.json" -nt "$OUT/$run/index.html" ] || continue
      rm -rf "$OUT/$run"
    fi
    [ -e "$OUT/$run.failed" ] && continue                 # operator retries
    echo "dashboards: building $run"
    if (cd "$REPO" && BENCH_RUN_DIR="$bundle" npm run build) \
         > "$OUT/$run.log" 2>&1; then
      rm -rf "$OUT/$run.tmp"
      cp -r "$REPO/dist" "$OUT/$run.tmp"
      # the pin this was built from, for the future rebuild-on-bump logic
      python3 - "$STATE/pins.json" <<EOF > "$OUT/$run.tmp/.built.json" || true
import json, sys, datetime
pins = {p["component"]: p for p in json.load(open(sys.argv[1]))["pins"]}
d = pins.get("dashboard", {})
print(json.dumps({"dashboard_commit": d.get("commit"),
                  "dashboard_version": d.get("version"),
                  "built_at": datetime.datetime.utcnow()
                      .strftime("%Y-%m-%dT%H:%M:%SZ")}))
EOF
      mv "$OUT/$run.tmp" "$OUT/$run"
      rm -f "$OUT/$run.log"
      echo "dashboards: published $run"
    else
      mv "$OUT/$run.log" "$OUT/$run.failed"
      echo "dashboards: BUILD FAILED for $run (see dashboards/$run.failed)"
    fi
  done
  sleep "$INTERVAL"
done
