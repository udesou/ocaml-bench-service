#!/usr/bin/env bash
# Publish the webview (index, per-run pages, dashboards) and the run bundles to
# a GitHub Pages repo: rsync the webview root into a checkout, commit when
# anything changed, push.  The LAN webview stays the live view (Pages lags a
# CDN cache by minutes); this is the shareable, durable face PR comments link.
#
#   scripts/publish_pages.sh [interval-seconds]     # loop
#   scripts/publish_pages.sh once                   # single sync, then exit
#
# Requires gh auth and the repo with Pages enabled on main.  Set BENCH_BASE_URL
# to the Pages URL in server.env for acknowledgement links to point here.
#
# Env: BENCH_STATE_DIR   (default ~/.ocaml-bench-service)
#      BENCH_PAGES_REPO  owner/name; empty disables publishing
#      BENCH_PAGES_DIR   the checkout (default <state>/pages-repo)

set -euo pipefail
STATE="${BENCH_STATE_DIR:-$HOME/.ocaml-bench-service}"
REPO="${BENCH_PAGES_REPO:-}"
DIR="${BENCH_PAGES_DIR:-$STATE/pages-repo}"
ARG="${1:-30}"

[ -n "$REPO" ] || { echo "pages: BENCH_PAGES_REPO empty -- publishing disabled"; exit 0; }
command -v rsync >/dev/null || { echo "pages: rsync not installed"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "pages: gh is not authenticated"; exit 1; }

if ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "pages: cloning $REPO -> $DIR"
  git clone --quiet "https://github.com/$REPO.git" "$DIR"
fi

sync_once() {
  git -C "$DIR" pull --quiet --ff-only || true
  # --copy-links dereferences the webview's runs -> ../runs symlink, so the
  # bundles are real files in the repo.
  rsync -a --delete --copy-links --exclude .git --exclude README.md \
    "$STATE/webview/" "$DIR/"
  # Without .nojekyll, Pages' Jekyll pass silently drops everything under
  # _observablehq/.
  touch "$DIR/.nojekyll"
  # Two passes over the published copy only, in this order (the second reports
  # file sizes).  1. Drop execution.json's last_heartbeat_epoch: it moves on
  # every heartbeat and made this loop commit every ~30s (5,752 commits in one
  # 48h sweep); nothing published reads it.  2. Pages has no directory listing,
  # so give each bundle a deterministic index.html.
  python3 - "$DIR" <<'PYEOF'
import os, sys, html, json
runs = os.path.join(sys.argv[1], "runs")

# --- 1. de-churn the published execution.json -------------------------------
VOLATILE = ("last_heartbeat_epoch",)
for run in (sorted(os.listdir(runs)) if os.path.isdir(runs) else []):
    p = os.path.join(runs, run, "execution.json")
    try:
        with open(p) as f:
            e = json.load(f)
    except (OSError, ValueError):
        continue  # absent or mid-write: leave it alone, try again next round
    if not any(k in e for k in VOLATILE):
        continue
    for k in VOLATILE:
        e.pop(k, None)
    # sort_keys so the output cannot depend on dict order, which would
    # reintroduce exactly the churn this is removing.
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(e, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, p)

# --- 2. per-bundle index.html ----------------------------------------------
for run in (sorted(os.listdir(runs)) if os.path.isdir(runs) else []):
    d = os.path.join(runs, run)
    if not os.path.isdir(d):
        continue
    rows = []
    for dirpath, dirnames, filenames in os.walk(d):
        dirnames.sort()
        for f in sorted(filenames):
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, d)
            if rel == "index.html":
                continue
            rows.append((rel, os.path.getsize(p)))
    items = "\n".join(
        f'<li><a href="{html.escape(r)}">{html.escape(r)}</a>'
        f' <small>{s:,} B</small></li>' for r, s in rows)
    open(os.path.join(d, "index.html"), "w").write(
        f"<!doctype html><meta charset=\"utf-8\"><title>{html.escape(run)}</title>\n"
        f"<body style=\"font:14px/1.6 monospace;max-width:60rem;margin:2rem auto;padding:0 1rem\">\n"
        f"<h1>{html.escape(run)}</h1>\n"
        f"<p><a href=\"../../run.html#{html.escape(run)}\">run page</a></p>\n"
        f"<ul>\n{items}\n</ul>\n")
PYEOF
  git -C "$DIR" add -A
  if ! git -C "$DIR" diff --cached --quiet; then
    git -C "$DIR" commit --quiet -m "sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git -C "$DIR" push --quiet
    echo "pages: pushed $(git -C "$DIR" rev-parse --short HEAD)"
  fi
}

if [ "$ARG" = "once" ]; then
  sync_once
  exit 0
fi

echo "pages: publishing $STATE/webview -> $REPO every ${ARG}s"
while true; do
  sync_once || echo "pages: sync failed; retrying next round"
  sleep "$ARG"
done
