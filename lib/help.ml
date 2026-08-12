(* `/bench help`, generated -- never hardcoded.

   The benchmark-set table comes from the base config and the sweepable
   parameters from the contract's vocab.json, so the help text cannot drift from
   what the service will actually accept.  That matters here more than usual:
   the tags moved once already (the input-size ladder), and stale help is how a
   user ends up filing a bug against a working service. *)

let render ~(facts : Facts.t) ~sweepable ~machines ~cap_seconds ~default_machine
    =
  let b = Buffer.create 2048 in
  let add fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  add "### `/bench` usage\n\n```\n";
  add "/bench                      # default set, %d iterations\n"
    Request.default_iterations;
  add "/bench vs=trunk             # choose the baseline\n";
  add "/bench vs=5.4.1,trunk       # compare more than two runtimes\n";
  add "/bench tag=small            # a different benchmark set (see below)\n";
  add "/bench iterations=5         # more repetitions\n";
  add "/bench sweep=s:262144,524288;o:80,120\n";
  add "/bench cancel               # stop my queued or running request\n";
  add "/bench help\n";
  add "```\n\n";

  add
    "The baseline defaults to this PR's merge base, so a bare `/bench` answers \
     \"does this PR change performance?\". `vs=` overrides it.\n\n";

  let sets =
    List.filter_map
      (fun alias ->
        let tag = Tag_alias.resolve alias in
        match Facts.find_tag facts tag with
        | Some t -> Some (alias, t)
        | None -> None)
      Tag_alias.documented
  in
  add "**Benchmark sets** (`tag=`)\n\n| tag | programs | |\n|---|---|---|\n";
  List.iter
    (fun (alias, (t : Facts.tag)) ->
      add "| `%s` | %d | %s |\n" alias t.programs
        (if alias = "default" then "one rung per tool — the default"
         else if t.gap then "_no benchmarks yet_"
         else ""))
    sets;

  add "\n**Sweepable GC parameters** (`sweep=`)\n\n";
  add "| parameter | meaning | unit |\n|---|---|---|\n";
  List.iter
    (fun (d : Vocab.dim) ->
      add "| `%s` | `%s` | %s |\n" d.modifier d.dimension d.unit_)
    (List.sort
       (fun (a : Vocab.dim) b -> compare a.modifier b.modifier)
       sweepable);
  add
    "\nSemicolons separate parameters, commas separate values. Every value is \
     another config crossed with every runtime, so sweeps get expensive fast.\n\n";

  add "**Iterations** — %d by default, %d at most. Each iteration re-runs every\n"
    Request.default_iterations Request.max_iterations;
  add "benchmark on every runtime; base and candidate are interleaved so machine\n";
  add "drift cancels out.\n\n";

  add
    "**Cost limit** — a request estimated over %s is refused; the estimate is \
     shown when a run is accepted.\n\n"
    (Cost.human cap_seconds);

  (match machines with
  | [] | [ _ ] -> ()
  | ms ->
    add "**Machines** — `machine=` selects one of: %s (default `%s`).\n\n"
      (String.concat ", " (List.map (fun m -> "`" ^ m ^ "`") ms))
      default_machine);

  add
    "Measurement always attaches `%s` (perf plus olly). Runs are serialised: one \
     at a time per machine, so a queued request may wait.\n"
    Request.perf_modifier;
  Buffer.contents b
