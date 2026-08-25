# Deploying the request server

The service's front half is three pieces in three places:

| piece | where it lives | needs |
|---|---|---|
| `bench-serve` (the server) | any host — a laptop today, a VPS later | git, opam, python3+PyYAML, capnp; clones of running-ng and ocaml-bench-dashboard |
| the PR bot ([bot/](../bot/)) | the ocaml/ocaml **fork**'s Actions | `BENCH_BOT_CAP` secret + a prebuilt `bench-cli` URL |
| `bench-cli` | anywhere | a `.cap` file |

Nothing that executes benchmarks is involved yet: the server validates,
resolves, queues, and **acknowledges** — the run directories it writes under
`<state>/runs/` are the hand-off point for the future bench agent (API B).

## Standing the server up (laptop or VPS, same steps)

```sh
scripts/server-setup.sh              # prerequisites, sibling clones, build
cp service.example.json service.json # allowlist, admins, machines
cp server.env.example server.env     # the deployment's address
scripts/serve.sh
```

On start, `bench-serve` prints the capability files it wrote:
`<state>/caps/<login>.cap` for every configured login, and `bot.cap`.
**A `.cap` file is both address book and key**: it embeds the server's public
address, the fingerprint of its secret key, and an unguessable service id.
Sending someone their file is granting access; there are no accounts or
passwords anywhere else.

macOS notes: `brew install capnproto pkg-config gmp`, and opam/python as
usual. The server side has no Linux dependency (it only runs git, python and
file IO) — but it has only been exercised on Linux so far, so run
`make test && make live` after setup.

## The drop-in / drop-out property

What makes the server movable is that its *identity* is two files, not a
machine:

- `<state>/secret-key.pem` — the vat key. Capability files pin its
  fingerprint, so keeping this file keeps every issued `.cap` trusted.
- `service.json` + `server.env` — policy and address.

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
CLI-only use on your own machines, a VPN address like a tailnet name works —
but GitHub's runners must be able to reach whatever address goes into
`bot.cap`, so the bot needs the public route.)

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
→ queued run + acknowledgement comment (or a refusal / help text — everything
the server returns is postable verbatim).

## Using the CLI from anywhere

Copy your `<login>.cap` to the machine and either pass `--cap` or set
`BENCH_CAP`:

```sh
export BENCH_CAP=~/me.cap
bench-cli submit "/bench tag=small invocations=1 vs=5.4.1,trunk"
bench-cli list
```

The file is the identity — guard it like a token, and ask an admin to remove
your login from `service.json` if it leaks (a restart then invalidates it).
