#!/usr/bin/env bash
# Publish the webview (index, per-run pages, dashboards) AND the run bundles
# to a GitHub Pages repo -- the git-backed store proof of concept (Q2's
# lean: git for the small canonical artifacts, pkgeval-reports style).
#
#   scripts/publish_pages.sh [interval-seconds]     # loop (a screen window)
#   scripts/publish_pages.sh once                   # single sync, then exit
#
# A poller like the others: rsync the webview root (which already contains
# everything -- runs/ is the symlinked bundle store, dashboards/ the built
# sites) into a checkout of the pages repo, commit when anything changed,
# push.  Nothing else in the service knows this exists: the LAN webview
# stays the live view (Pages lags a CDN cache by minutes), this is the
# shareable, durable face that PR comments can link.
#
# Requirements: gh auth (push credentials), the repo existing with Pages
# enabled on main.  Set BENCH_BASE_URL to the Pages URL in server.env if
# acknowledgement links should point here rather than at the LAN webview.
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
  # bundles are real files in the repo (the git-backed store).
  rsync -a --delete --copy-links --exclude .git --exclude README.md \
    "$STATE/webview/" "$DIR/"
  # Without this, Pages' Jekyll pass silently drops the dashboard assets
  # (everything under _observablehq/).
  touch "$DIR/.nojekyll"
  # Pages has no directory listing, so the run pages' "bundle" links would
  # 404: give each published bundle a generated index.html (deterministic, so
  # an unchanged bundle produces no git diff).  Only the PUBLISHED copy gets
  # these; the store itself stays free of presentation files.
  python3 - "$DIR" <<'PYEOF'
import os, sys, html
runs = os.path.join(sys.argv[1], "runs")
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
