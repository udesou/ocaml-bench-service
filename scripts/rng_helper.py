#!/usr/bin/env python3
"""Thin bridge from the service to running-ng's own config semantics.

The service is OCaml; running-ng is Python and owns three things we must not
reimplement (a second implementation of an implicit schema is exactly the
failure mode DATA_CONTRACT.md was written to kill):

  * ``includes:``/``overrides:`` merge semantics   -> Configuration.from_file
  * config/runtime/comparison consistency          -> Configuration.validate
  * tag block validity + tag -> program filtering   -> validate_tags,
                                                       apply_tag_filter

Every subcommand prints a single JSON object on stdout and exits 0 even when the
answer is "invalid" -- the caller distinguishes on the ``ok`` field, not on the
exit status.  A non-zero exit means the bridge itself broke (bad PYTHONPATH,
missing file), which is an operator problem, not a user problem.

Nothing here provisions a switch or touches the opam root: we never call
``resolve_class()``, which is what instantiates ``OCaml`` objects and so
triggers ``_ensure_switch``.  That is also why ``-d`` (dry run) is unusable as
a validator -- see the design doc, section 5.

Usage:
    rng_helper.py facts     --config PATH
    rng_helper.py validate  --config PATH
    rng_helper.py tagfilter --config PATH --tags a,b
"""

import argparse
import json
import os
import sys
from pathlib import Path


def _bootstrap():
    """Put running-ng's src on sys.path.  RUNNING_NG_SRC overrides."""
    src = os.environ.get("RUNNING_NG_SRC") or str(Path.home() / "running-ng" / "src")
    if not (Path(src) / "running").is_dir():
        _die(f"running-ng not found at {src!r}; set RUNNING_NG_SRC")
    sys.path.insert(0, src)


def _die(msg):
    print(json.dumps({"ok": False, "bridge_error": msg}), file=sys.stdout)
    sys.exit(2)


def _load(config_path):
    """Load a config the way running-ng does, honouring includes/overrides."""
    from running.config import Configuration

    p = Path(config_path).expanduser()
    if not p.is_file():
        _die(f"config not found: {p}")
    return Configuration.from_file(p.parent, p.name)


def _errors_of(exc):
    """running-ng raises one ValueError whose message is a bulleted list."""
    text = str(exc)
    lines = [ln.strip() for ln in text.splitlines()]
    bullets = [ln[2:].strip() for ln in lines if ln.startswith("- ")]
    return bullets if bullets else [text]


def cmd_facts(args):
    """Everything the generator needs to know about the base config.

    Emitted rather than parsed on the OCaml side so that the merge semantics
    have exactly one implementation.
    """
    cfg = _load(args.config)

    tags_raw = cfg.get("tags") or {}
    tags = []
    for name, entry in tags_raw.items():
        entry = entry or {}
        exercised = entry.get("exercised_by") or {}
        count = sum(len(v or []) for v in exercised.values())
        tags.append(
            {
                "name": name,
                "programs": count,
                "gap": bool(entry.get("gap")),
                "suites": {s: sorted(v or []) for s, v in exercised.items()},
            }
        )
    tags.sort(key=lambda t: t["name"])

    suites_raw = cfg.get("suites") or {}
    benchmarks = cfg.get("benchmarks") or {}
    suites = []
    uses_ocamlrunparam = False
    for name in sorted(suites_raw):
        spec = suites_raw[name] or {}
        programs_raw = spec.get("programs") or {}
        # `ocamlrunparam:` (running-ng #15) is a suite-level default, overridable
        # per program, merged over the config string's re/md.  Its presence means
        # the ring/domain settings have moved OUT of config strings, so a
        # generated config must not carry re-N|md-M and shadow them.
        suite_orp = spec.get("ocamlrunparam")
        prog_orp = [
            p
            for p, pspec in programs_raw.items()
            if isinstance(pspec, dict) and pspec.get("ocamlrunparam")
        ]
        if suite_orp or prog_orp:
            uses_ocamlrunparam = True
        suites.append(
            {
                "name": name,
                "programs": sorted(programs_raw),
                "enabled": sorted(benchmarks.get(name) or []),
                "ocamlrunparam": suite_orp,
                "programs_with_ocamlrunparam": sorted(prog_orp),
            }
        )

    modifiers = []
    for name in sorted(cfg.get("modifiers") or {}):
        spec = (cfg.get("modifiers") or {})[name] or {}
        modifiers.append({"name": name, "type": spec.get("type")})

    print(
        json.dumps(
            {
                "ok": True,
                "invocations": cfg.get("invocations"),
                "schema_version": cfg.get("schema_version"),
                "compress_logs": cfg.get("compress_logs"),
                "uses_ocamlrunparam": uses_ocamlrunparam,
                "tags": tags,
                "suites": suites,
                "modifiers": modifiers,
            },
            indent=None,
            sort_keys=False,
        )
    )


def cmd_validate(args):
    """validate() + validate_tags() on a generated config.  No side effects."""
    cfg = _load(args.config)
    errors = []
    for check in ("validate", "validate_tags"):
        try:
            getattr(cfg, check)()
        except ValueError as e:
            errors.extend(f"{check}: {m}" for m in _errors_of(e))
        except Exception as e:  # a bug in the config shape, not a rule breach
            errors.append(f"{check}: {type(e).__name__}: {e}")
    print(json.dumps({"ok": not errors, "errors": errors}))


def cmd_tagfilter(args):
    """Resolve tags -> kept programs using running-ng's own intersection rules.

    This is what the cost model counts, so it must be running-ng's answer and
    not our approximation of it.
    """
    cfg = _load(args.config)
    names = [t for t in (args.tags or "").split(",") if t]
    try:
        cfg.apply_tag_filter(names)
    except ValueError as e:
        print(json.dumps({"ok": False, "errors": _errors_of(e)}))
        return
    kept = {s: sorted(p) for s, p in (cfg.get("benchmarks") or {}).items() if p}
    print(
        json.dumps(
            {
                "ok": True,
                "errors": [],
                "kept": kept,
                "total": sum(len(v) for v in kept.values()),
            }
        )
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("facts", help="dump base-config facts as JSON")
    p.add_argument("--config", required=True)
    p.set_defaults(fn=cmd_facts)

    p = sub.add_parser("validate", help="run validate() + validate_tags()")
    p.add_argument("--config", required=True)
    p.set_defaults(fn=cmd_validate)

    p = sub.add_parser("tagfilter", help="resolve tags to kept programs")
    p.add_argument("--config", required=True)
    p.add_argument("--tags", required=True)
    p.set_defaults(fn=cmd_tagfilter)

    args = ap.parse_args()
    _bootstrap()
    args.fn(args)


if __name__ == "__main__":
    main()
