#!/usr/bin/env bash
# Build a per-run dashboard for every finished run that lacks one: for each
# done run with contract measurements, run `BENCH_RUN_DIR=<bundle> npm run
# build` in the server's own dashboard checkout and publish dist/ under
# <state>/webview/dashboards/<run_id>/.  A failed build leaves
# dashboards/<run_id>.failed with the log and is not retried until that file is
# removed.
#
#   scripts/dashboard_builder.sh [interval-seconds]
#
# Env: BENCH_STATE_DIR (default ~/.ocaml-bench-service)
#      BENCH_GIT_DIR   (default <state>/git)
#      DASHBOARD_REPO  (default <state>/git/ocaml-bench-dashboard; needs
#                       `npm install` and bin/ingest, both done by
#                       scripts/server-setup.sh)

set -euo pipefail
STATE="${BENCH_STATE_DIR:-$HOME/.ocaml-bench-service}"
REPO="${DASHBOARD_REPO:-${BENCH_GIT_DIR:-$STATE/git}/ocaml-bench-dashboard}"
INTERVAL="${1:-30}"

command -v node >/dev/null || { echo "dashboards: node not installed"; exit 1; }
command -v python3 >/dev/null || { echo "dashboards: python3 not installed"; exit 1; }
[ -d "$REPO/node_modules" ] \
  || { echo "dashboards: $REPO has no node_modules (run scripts/server-setup.sh)"; exit 1; }
[ -x "$REPO/bin/ingest" ] \
  || { echo "dashboards: $REPO/bin/ingest missing (run scripts/server-setup.sh)"; exit 1; }
# A bin/ingest older than the checkout rejects current manifests and every build
# fails with "Unable to load measurements.json"; refuse up front and say what is
# wrong.
[ -z "$(find "$REPO/lib" "$REPO/ingest" "$REPO/dune-project" \
          -newer "$REPO/bin/ingest" -print -quit 2>/dev/null)" ] \
  || { echo "dashboards: $REPO/bin/ingest is older than the checkout it validates" \
            "against (re-run scripts/server-setup.sh to rebuild it)"; exit 1; }

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
    [ -f "$bundle/contract/manifest.json" ] || continue
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
      # the pin this was built from, for a future rebuild-on-bump
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
