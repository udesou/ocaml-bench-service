#!/usr/bin/env bash
# The polling PR bot -- the GitHub-Actions workflow's twin, for servers that
# GitHub's runners cannot reach (a machine behind a university NAT, say).
#
#   bot/poll.sh <owner/repo> [interval-seconds]
#
# It runs NEXT TO bench-serve and needs only OUTBOUND https to
# api.github.com, mirroring the agent-pull philosophy: nothing dials in.
# And it is still a THIN client (Q13): it parses nothing -- every comment
# starting with /bench goes to the server verbatim, and whatever markdown
# comes back (ack, reuse, help, refusal) is posted as the reply.
#
# Identity: replies are posted by gh's logged-in account; bot.cap asserts the
# commenter's login, which must still pass the server's allowlist -- a
# stranger commenting /bench gets the polite refusal, posted publicly.
#
# State: $STATE/bot-seen holds handled comment ids, so restarts never
# double-submit (and the server's idempotency key backstops even that).

set -uo pipefail

REPO="${1:?usage: bot/poll.sh <owner/repo> [interval-seconds]}"
INTERVAL="${2:-30}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${BENCH_STATE_DIR:-$HOME/.ocaml-bench-service}"
CAP="${BENCH_BOT_CAP_FILE:-$STATE/caps/bot.cap}"
SEEN="$STATE/bot-seen"

[ -f "$CAP" ] || { echo "no bot capability at $CAP -- is bench-serve running?"; exit 1; }
mkdir -p "$STATE"
touch "$SEEN"

SELF="$(gh api user -q .login)" || { echo "gh is not authenticated"; exit 1; }
# Only comments from now on: history is not ours to answer.
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cli() { (cd "$ROOT" && opam exec --switch=. -- dune exec --no-build bin/bench_cli.exe -- "$@"); }

echo "bot: polling $REPO every ${INTERVAL}s, replying as @$SELF, cap $CAP"

while :; do
  rows=$(gh api "repos/$REPO/issues/comments?since=$SINCE&per_page=100" \
           --jq '.[] | select(.body | startswith("/bench")) | @base64' 2>/dev/null) || rows=""
  for row in $rows; do
    field() { printf '%s' "$row" | base64 -d | jq -r "$1"; }
    id=$(field .id)
    grep -qx "$id" "$SEEN" && continue
    author=$(field '.user.login')
    if [ "$author" = "$SELF" ]; then
      echo "$id" >> "$SEEN"
      continue
    fi
    issue_url=$(field .issue_url)
    number="${issue_url##*/}"
    comment_url=$(field .html_url)
    body=$(field .body)
    # Only pull requests have compilers to measure; a /bench on a plain issue
    # is noted and skipped.
    if ! pr=$(gh api "repos/$REPO/pulls/$number" 2>/dev/null); then
      echo "bot: comment $id is on #$number, which is not a PR; ignoring"
      echo "$id" >> "$SEEN"
      continue
    fi
    head_sha=$(jq -r .head.sha <<<"$pr")
    base_ref=$(jq -r .base.ref <<<"$pr")
    pr_url=$(jq -r .html_url <<<"$pr")
    echo "bot: #$number @$author: $(printf '%s' "$body" | head -1)"
    reply=$(cli submit "$body" \
        --cap "$CAP" --as-login "$author" \
        --pr-repo "$REPO" --pr-number "$number" --pr-url "$pr_url" \
        --comment-id "$id" --comment-url "$comment_url" \
        --head-sha "$head_sha" --base-ref "$base_ref" 2>&1) || true
    reply=$(printf '%s\n' "$reply" | grep -v '^Connecting to ')
    [ -n "$reply" ] || reply="The server returned nothing; check bench-serve's log."
    if gh api "repos/$REPO/issues/$number/comments" -f body="$reply" >/dev/null; then
      echo "bot: replied on #$number"
    else
      echo "bot: FAILED to post the reply on #$number; will not retry $id"
    fi
    echo "$id" >> "$SEEN"
  done
  sleep "$INTERVAL"
done
