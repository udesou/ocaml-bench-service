# Deploying the request server

The service's front half is three pieces in three places:

| piece | where it lives | needs |
|---|---|---|
| `bench-serve` (the server) | any host -- a laptop today, a VPS later | git, opam, python3+PyYAML, capnp; clones of running-ng and ocaml-bench-dashboard; node >= 18 for the per-run dashboard builds (skipped with a warning without it) |
| the PR bot ([bot/](../bot/)) | the ocaml/ocaml **fork**'s Actions | `BENCH_BOT_CAP` secret + a prebuilt `bench-cli` URL |
| `bench-cli` | anywhere | a `.cap` file |
| `bench-agent` | the bench machine | its `agent-<machine>.cap`; `scripts/agent-setup.sh` provisions the rest |

The server validates, resolves, queues, and **acknowledges**; the run
directories it writes under `<state>/runs/` are the queue the agent drains,
and grow into each run's permanent bundle as the agent uploads artifacts and
the server renders the report.

## Standing the server up (laptop or VPS, same steps)

```sh
scripts/server-setup.sh              # prerequisites, sibling clones, build
cp service.example.json service.json # allowlist, admins, machines
cp server.env.example server.env     # the deployment's address
scripts/start_server.sh              # server, webview, bot, dashboards,
                                     # pages: one screen session ("bench";
                                     # also: stop|status)
```

(Or run the pieces by hand -- `scripts/serve.sh`, `scripts/webview.sh 8080`,
`bot/poll.sh <owner/repo>` -- each in its own window: all three are foreground
processes.)

Set `BENCH_BASE_URL` in `server.env` to where the webview is served
(the Pages URL, or `http://host:8080` for LAN-only use): acknowledgement and
completion links then land on each run's own page.

On start, `bench-serve` prints the capability files it wrote:
`<state>/caps/<login>.cap` for every configured login, and `bot.cap`.
**A `.cap` file is both address book and key**: it embeds the server's public
address, the fingerprint of its secret key, and an unguessable service id.
Sending someone their file is granting access; there are no accounts or
passwords anywhere else.

macOS notes (learned by deploying there -- arm64 builds everything cleanly):

- `brew install capnp pkg-config gmp` -- Homebrew's formula is **`capnp`**;
  `capnproto` is the Debian/apt name.
- Homebrew's python refuses `pip install` (PEP 668): put PyYAML in a venv and
  expose a **wrapper script** at `~/.local/bin/python3` that execs the venv's
  python (a symlink loses the venv's site-packages). Every script here puts
  `~/.local/bin` first on PATH.
- **AirPlay Receiver owns port 7000** on modern macOS: use another port
  (`server.env` is where that lives).
- `BENCH_PUBLIC_ADDRESS` needs a literal IPv4 address or a real DNS name -- an
  mDNS `.local` name resolves IPv6-first and the client stops at the first
  unroutable address. Bind `tcp:[::]:PORT` for dual-stack listening.

## The drop-in / drop-out property

What makes the server movable is that its *identity* is two files, not a
machine:

- `<state>/secret-key.pem` -- the vat key. Capability files pin its
  fingerprint, so keeping this file keeps every issued `.cap` trusted.
- `service.json` + `server.env` -- policy and address.

**Give `BENCH_PUBLIC_ADDRESS` a DNS name from day one** (dynamic DNS pointing
at the laptop is fine). Then moving the service to a new host is:

```sh
# on the new host
scripts/server-setup.sh
rsync -a old:/home/you/.ocaml-bench-service/ ~/.ocaml-bench-service/  # queue + key
scp old:…/service.json old:…/server.env .
scripts/serve.sh          # same name, same key -> every .cap still works
```

…plus repointing the DNS record. Zero lines change; nothing is re-issued. If
you *don't* use a stable name, a move additionally means re-issuing the `.cap`
files (the daemon rewrites them at startup with the current address) and
updating the fork's `BENCH_BOT_CAP` secret.

A laptop behind home NAT needs one reachable TCP port for the GitHub Action
to connect: a router port-forward to `BENCH_LISTEN`, or a TCP tunnel. (For
CLI-only use on your own machines, a VPN address like a tailnet name works --
but GitHub's runners must be able to reach whatever address goes into
`bot.cap`, so the bot needs the public route.)

## Connecting a bench machine

The server writes `agent-<machine>.cap` for every machine in `service.json`.
The file is the machine's identity, exactly as `<login>.cap` is a user's: it
can claim and report that machine's work, and nothing else (never submit,
never admin), so it is safe to live on a host that executes PR code.

```sh
# on the bench machine, in this repo
scripts/agent-setup.sh           # prereq checks, private clones, build
scp server:~/.ocaml-bench-service/caps/agent-<machine>.cap .
until BENCH_AGENT_CAP=agent-<machine>.cap \
  ./_build/default/bin/bench_agent.exe; do sleep 5; done
```

On a truly bare machine, run running-ng's `install_deps_linux.sh` first: it
installs the heavy prerequisites (opam itself, C libraries, perf) that
`agent-setup.sh` only checks for.

The agent keeps its own clones under `~/.bench-agent` and never touches
personal checkouts; `agent-setup.sh` seeds them from local donor checkouts
when present (fast, and it copies macro-benches' gitignored vendored trees)
or from the canonical URLs otherwise. macro-benches' own `make setup`
(vendoring, patches, a test build) is the agent's job, not the script's: it
runs supervised on the first claim and again whenever a bump moves the
benches pin, dropping the vendored trees first when the lock file changed.

The agent polls (`--interval`, default 5 s), and exits on a broken
connection, hence the supervisor loop. `--once` processes a single
assignment and exits, which is the smoke test: submit a run, watch the agent
claim and finish it, see the webview row go `queued -> running -> done`.

## Publishing to GitHub Pages (the shareable face)

`scripts/publish_pages.sh` syncs the whole webview root -- index, per-run
pages, run bundles, dashboards -- into a GitHub repo and pushes; with Pages
enabled on that repo's main branch, everything is served publicly, and the
repo doubles as the results archive. Setup, once:

```sh
gh repo create <user>/ocaml-bench-results --public   # Pages on private needs Pro
# seed main (a README is enough), then:
gh api -X POST repos/<user>/ocaml-bench-results/pages \
  -f "source[branch]=main" -f "source[path]=/"
```

Then in `server.env`: `BENCH_PAGES_REPO=<user>/ocaml-bench-results`, and set
`BENCH_BASE_URL` to the Pages URL so acknowledgement and completion links
point somewhere PR readers can actually reach. `start_server.sh` runs the
publisher as its fifth window. Pages sits behind a CDN cache (minutes), so
the LAN webview stays the live view; this is the durable one.

## Wiring the fork

Once the server is reachable (see [bot/README.md](../bot/README.md) for
detail):

1. `base64 -w0 <state>/caps/bot.cap` → fork secret `BENCH_BOT_CAP`.
2. Build `bench-cli` for the runners (`dune build bin/bench_cli.exe`, a Linux
   x86-64 build), host the binary (e.g. a GitHub release of this repo), set
   the fork variable `BENCH_CLI_URL`.
3. Copy [bot/bench.yml](../bot/bench.yml) to the fork's
   `.github/workflows/bench.yml`.

`/bench …` on a fork PR then round-trips: comment → Action → capnp → server
→ queued run + acknowledgement comment (or a refusal / help text -- everything
the server returns is postable verbatim).

## Using the CLI from anywhere

Copy your `<login>.cap` to the machine and either pass `--cap` or set
`BENCH_CAP`:

```sh
export BENCH_CAP=~/me.cap
bench-cli submit "/bench tag=small invocations=1 vs=5.4.1,trunk"
bench-cli list
```

The file is the identity -- guard it like a token, and ask an admin to remove
your login from `service.json` if it leaks (a restart then invalidates it).
