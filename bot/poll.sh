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
# Look back a little on startup so a restart does not orphan comments made
# while the bot was down; bot-seen (and the server's idempotency key behind
# it) keeps the overlap from double-posting.  Loop safety needs no author
# check: the trigger is `startswith("/bench")` and no reply the bot posts
# ever starts with that -- an author==SELF guard would break the common
# single-account setup where the operator IS the posting account.
LOOKBACK="${BENCH_BOT_LOOKBACK:-900}"
SINCE="$(date -u -d "@$(( $(date +%s) - LOOKBACK ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -v-"${LOOKBACK}"S +%Y-%m-%dT%H:%M:%SZ)"

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
        --head-sha "$head_sha" --base-ref "$base_ref" 2>&1)
    rc=$?
    # bench-cli's exit codes are the contract: 0 = outcome, 1 = a refusal
    # (both postable), >=2 = the wire or the client failed -- infrastructure
    # noise is logged here and the comment is retried next poll, NOT posted
    # to the PR and NOT marked seen.
    if [ "$rc" -ge 2 ]; then
      echo "bot: cannot serve comment $id right now (bench-cli exit $rc); will retry"
      printf '%s\n' "$reply" | sed 's/^/bot:   /'
      continue
    fi
    reply=$(printf '%s\n' "$reply" | grep -v '^Connecting to ')
    [ -n "$reply" ] || reply="The server returned nothing; check bench-serve's log."
    if gh api "repos/$REPO/issues/$number/comments" -f body="$reply" >/dev/null; then
      echo "bot: replied on #$number"
    else
      echo "bot: FAILED to post the reply on #$number; will not retry $id"
    fi
    echo "$id" >> "$SEEN"
  done

  # Completion notices: the server renders <run>/completion.md when a run
  # reaches a terminal state (the same renders-verbatim rule as replies);
  # post each one once to its PR.  completion.posted is the idempotency
  # marker; CLI-triggered runs have no PR and are marked without posting.
  for f in "$STATE"/runs/*/completion.md; do
    [ -e "$f" ] || continue
    d=$(dirname "$f")
    [ -e "$d/completion.posted" ] && continue
    pr_url=$(jq -r '.pr_url // empty' "$d/request.json" 2>/dev/null)
    if [ -z "$pr_url" ]; then
      touch "$d/completion.posted"   # a CLI run: the file itself is the record
      continue
    fi
    path="${pr_url#https://github.com/}"
    pr_repo="${path%%/pull/*}"
    number="${path##*/}"
    if gh api "repos/$pr_repo/issues/$number/comments" -f body="$(cat "$f")" >/dev/null; then
      echo "bot: completion posted for $(basename "$d") on $pr_repo#$number"
      touch "$d/completion.posted"
    else
      echo "bot: FAILED to post completion for $(basename "$d"); will retry"
    fi
  done

  sleep "$INTERVAL"
done
