# The PR bot

A GitHub Actions workflow that turns `/bench` comments on the fork's pull
requests into API A submissions, and posts the server's markdown back. It is
deliberately a *thin* client (Q13): no grammar, no rendering, no policy — the
allowlist decision, the resolution of the PR head and merge base, and every
message all come from the server.

## Setup

1. **Run the server somewhere GitHub's runners can reach** (Q3 — host still
   to be decided):

   ```sh
   bench-serve --service-config service.json \
     --listen tcp:0.0.0.0:7000 --public-address tcp:bench.example.org:7000
   ```

   At startup it writes `<state>/caps/bot.cap` (and one `<login>.cap` per
   configured user). The public address is baked into the capability files,
   so set it before distributing them.

2. **Give the fork the bot capability**: repository secret `BENCH_BOT_CAP` =
   `base64 -w0 bot.cap`. This file *is* the bot's access — treat it like a
   token. It only lets the holder submit-as-commenter; the commenter must
   still be on the server's allowlist.

3. **Host a prebuilt `bench-cli`**: `dune build bin/bench_cli.exe`, upload the
   binary (e.g. as a release asset of this repository), and set the repository
   variable `BENCH_CLI_URL` to its URL. The Action downloads it per run — a
   capnp client can't be curl (Q15), so the binary stands in.

4. **Copy `bench.yml` into the fork** as `.github/workflows/bench.yml`.

## What the bot sends

Everything the webhook and one `gh api` call know: repo, PR number and URL,
comment id and URL, the commenter's login (verified by GitHub), the PR head
sha at comment time, and the target branch. The server still resolves the
merge base itself (`pr_context` in the architecture document, §5.3).

## v1 reporting

One reply comment per `/bench` command, carrying whatever the server said —
acknowledgement with links, "these results already exist", help text, or a
refusal. The **final** comment (summary when the run completes) needs the run
execution side (API B) and is not wired yet; `bench-cli status <run-id>`
answers in the meantime.
