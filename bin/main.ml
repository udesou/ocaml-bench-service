(* bench-gen -- the request-generation command line.

     parse   a /bench comment                    -> JSON (no side effects)
     spec    a /bench comment + pinned variants  -> run spec (+ optional --check)
     help    render /bench help from live facts
     vocab   the API A vocabulary (machines, families, tags, sweepable) as JSON
     authz   test the trigger allowlist and roles

   Ref resolution (trunk -> sha) is deliberately absent: it belongs to the
   server, needs the network, and would make this untestable.  `spec` therefore
   takes variants already pinned to a version or a sha -- which is also why the
   run specs it writes carry `run_key: null`: the §8.1 key hashes resolved shas
   and the machine's environment fingerprint, and only the server has both. *)

open Bench_service

let home = try Sys.getenv "HOME" with Not_found -> "."

let default_base_config =
  Filename.concat home "running-ng/src/running/config/base/ocaml/macro_base.yml"

let default_vocab =
  Filename.concat home "ocaml-bench-dashboard/schema/json/vocab.json"

type opts = {
  comment : string;
  base_config : string;
  vocab : string;
  running_ng_src : string;
  helper : string;
  service_config : string option;
  macro_bench_dir : string;
  log_dir : string;
  machine : string option;
  request_id : string;
  out_dir : string option;
  opamroot : string option;
  pr_url : string option;
  requested_by : string option;
  login : string option;
  association : string option;
  cell_seconds : float option;
  cap_seconds : float option;
  variants : Variant.t list;
  baseline : string option;
  check : bool;
  format : string;
  running_ng_dir : string;
  running_ng_ref : string;
  macro_benches_ref : string;
}

let default_opts () =
  {
    comment = "";
    base_config = default_base_config;
    vocab = default_vocab;
    running_ng_src = Filename.concat home "running-ng/src";
    helper = Filename.concat (Sys.getcwd ()) "scripts/rng_helper.py";
    service_config = None;
    macro_bench_dir = Filename.concat home "macro-benches";
    log_dir = Filename.concat home "bench-runs";
    machine = None;
    request_id = "req-unset";
    out_dir = None;
    opamroot = None;
    pr_url = None;
    requested_by = None;
    login = None;
    association = None;
    cell_seconds = None;
    cap_seconds = None;
    variants = [];
    baseline = None;
    check = false;
    format = "text";
    running_ng_dir = Filename.concat home "running-ng";
    (* Pinned refs, not "whatever is checked out": that working copy moves
       between feature branches, and the run must say which code it ran. *)
    running_ng_ref = "origin/adding-ocaml-support";
    macro_benches_ref = "origin/master";
  }

let die fmt = Printf.ksprintf (fun s -> prerr_endline s; exit 2) fmt

let usage () =
  print_string
    {|bench-gen -- generate a running-ng run spec from a /bench comment

  bench-gen parse --comment "/bench invocations=3"
  bench-gen help  [--service-config service.json]
  bench-gen vocab [--service-config service.json]
  bench-gen authz --service-config service.json --login someone
  bench-gen spec  --comment "/bench" \
                  --variant version:base:5.5.0 \
                  --variant commit:pr-1234:c0f8c8ceef751fb3a99652d3d52399db3d1c2aae \
                  [--baseline base] [--out DIR] [--check]

Variants are `version:<label>:<v>` or `commit:<label>:<sha>`, optionally with a
fourth `:<configure args>` part; the first is the baseline unless --baseline
names another label.

`spec` always writes <request_id>.yml and <request_id>.runspec.json into --out;
--format json prints the run spec instead of the config. See docs/RUNSPEC.md.

Options: --base-config --vocab --running-ng-src --running-ng-dir --running-ng-ref
         --macro-benches-ref --helper --service-config --macro-bench-dir
         --log-dir --machine --request-id --opamroot --pr-url --requested-by
         --login --association --cell-seconds --cap-seconds --out --format
         --check
|};
  exit 0

let parse_args argv =
  let o = ref (default_opts ()) in
  let rec go = function
    | [] -> ()
    | flag :: rest ->
      let need () =
        match rest with v :: tl -> (v, tl) | [] -> die "%s needs a value" flag
      in
      let set f = let v, tl = need () in o := f v; go tl in
      (match flag with
      | "--comment" -> set (fun v -> { !o with comment = v })
      | "--base-config" -> set (fun v -> { !o with base_config = v })
      | "--vocab" -> set (fun v -> { !o with vocab = v })
      | "--running-ng-src" -> set (fun v -> { !o with running_ng_src = v })
      | "--helper" -> set (fun v -> { !o with helper = v })
      | "--service-config" -> set (fun v -> { !o with service_config = Some v })
      | "--macro-bench-dir" -> set (fun v -> { !o with macro_bench_dir = v })
      | "--log-dir" -> set (fun v -> { !o with log_dir = v })
      | "--machine" -> set (fun v -> { !o with machine = Some v })
      | "--request-id" -> set (fun v -> { !o with request_id = v })
      | "--out" -> set (fun v -> { !o with out_dir = Some v })
      | "--opamroot" -> set (fun v -> { !o with opamroot = Some v })
      | "--pr-url" -> set (fun v -> { !o with pr_url = Some v })
      | "--requested-by" -> set (fun v -> { !o with requested_by = Some v })
      | "--login" -> set (fun v -> { !o with login = Some v })
      | "--association" -> set (fun v -> { !o with association = Some v })
      | "--baseline" -> set (fun v -> { !o with baseline = Some v })
      | "--cell-seconds" ->
        set (fun v -> { !o with cell_seconds = Some (float_of_string v) })
      | "--cap-seconds" ->
        set (fun v -> { !o with cap_seconds = Some (float_of_string v) })
      | "--variant" ->
        set (fun v ->
            match Variant.of_cli_string v with
            | Error e -> die "%s" e
            | Ok var -> { !o with variants = !o.variants @ [ var ] })
      | "--format" -> set (fun v -> { !o with format = v })
      | "--running-ng-dir" -> set (fun v -> { !o with running_ng_dir = v })
      | "--running-ng-ref" -> set (fun v -> { !o with running_ng_ref = v })
      | "--macro-benches-ref" -> set (fun v -> { !o with macro_benches_ref = v })
      | "--check" -> o := { !o with check = true }; go rest
      | "-h" | "--help" -> usage ()
      | other -> die "unknown flag %s (try --help)" other)
  in
  go argv;
  (* Which side is the baseline decides the sign of every delta, so it is
     explicit rather than positional-by-accident. *)
  let variants =
    match !o.variants with
    | [] -> []
    | first :: _ ->
      List.map
        (fun (v : Variant.t) ->
          let is_base =
            match !o.baseline with Some l -> v.label = l | None -> v == first
          in
          Variant.with_role
            (if is_base then Variant.Baseline else Variant.Candidate)
            v)
        !o.variants
  in
  { !o with variants }

let load_service o =
  match o.service_config with
  | None -> None
  | Some path -> (
    match Service_config.of_file path with
    | Ok c -> Some c
    | Error e -> die "bad service config %s: %s" path e)

let bridge_of o =
  Bridge.default_config ~helper:o.helper ~running_ng_src:o.running_ng_src ()

let load_facts o =
  match Bridge.facts (bridge_of o) ~config:o.base_config with
  | Ok f -> f
  | Error e -> die "could not read base config facts: %s" e

let load_sweepable o =
  match Vocab.of_file o.vocab with
  | Ok d -> d
  | Error e -> die "could not read %s: %s" o.vocab e

(* Machine, dirs and budgets come from the service config when there is one, and
   from flags otherwise, so the CLI stays usable before a config exists. *)
type placement = {
  p_machine : string;
  p_macro_bench_dir : string;
  p_log_dir : string;
  p_opamroot : string option;
  p_cap : float;
  p_cell : float;
}

let resolve_placement o svc =
  match svc with
  | None ->
    {
      p_machine = Option.value o.machine ~default:"local";
      p_macro_bench_dir = o.macro_bench_dir;
      p_log_dir = o.log_dir;
      p_opamroot = o.opamroot;
      p_cap = Option.value o.cap_seconds ~default:Cost.default_cap_seconds;
      p_cell = Option.value o.cell_seconds ~default:Cost.default_cell_seconds;
    }
  | Some (c : Service_config.t) -> (
    match Service_config.resolve_machine c o.machine with
    | Error e -> print_endline e; exit 1
    | Ok m ->
      {
        p_machine = m.name;
        p_macro_bench_dir = m.macro_bench_dir;
        p_log_dir = m.log_dir;
        p_opamroot =
          (match o.opamroot with Some r -> Some r | None -> m.opamroot);
        p_cap = Option.value o.cap_seconds ~default:c.cap_seconds;
        p_cell = Option.value o.cell_seconds ~default:c.cell_seconds;
      })

let cmd_parse o =
  match Request.parse o.comment with
  | Error e -> print_endline e; exit 1
  | Ok r -> print_endline (Yojson.Safe.pretty_to_string (Request.to_json r))

let cmd_help o =
  let svc = load_service o in
  let facts = load_facts o in
  let sweepable = load_sweepable o in
  let machines, default_machine =
    match svc with
    | None -> ([], "local")
    | Some c ->
      ( Service_config.machine_names c,
        (match Service_config.default_machine c with
        | Some m -> m.name
        | None -> "none") )
  in
  let pl = resolve_placement o svc in
  print_string
    (Help.render ~facts ~sweepable ~machines ~cap_seconds:pl.p_cap
       ~default_machine)

let cmd_authz o =
  match load_service o with
  | None -> die "authz needs --service-config"
  | Some c ->
    let login = match o.login with Some l -> l | None -> die "authz needs --login" in
    let d = Authz.check c ~login ~association:o.association in
    (match Authz.auth d with
    | Some auth ->
      Printf.printf "ALLOWED (%s), role %s; bot account %s, token from $%s\n"
        (Authz.message d)
        (Api.string_of_role auth.Api.role)
        c.bot.account c.bot.token_env
    | None ->
      print_endline (Authz.message d);
      exit 1)

(* The §5.2 vocabulary: what a requester may say.  The PR bot and the CLI read
   this instead of hardcoding tags or machines. *)
let cmd_vocab o =
  let svc = load_service o in
  let facts = load_facts o in
  let sweepable = load_sweepable o in
  let machines =
    match svc with
    | None -> [ Option.value o.machine ~default:"local" ]
    | Some c -> Service_config.machine_names c
  in
  let tags = Tag_alias.vocabulary ~defined:(Facts.tag_names facts) in
  let vocab =
    {
      Api.machines;
      families = [ Api.Macro ];
      tags;
      sweepable =
        List.map
          (fun (d : Vocab.dim) ->
            { Api.param = d.modifier; dimension = d.dimension; unit_ = d.unit_ })
          sweepable;
      max_invocations = Request.max_invocations;
    }
  in
  print_endline (Yojson.Safe.pretty_to_string (Api.json_of_vocab vocab))

let cmd_spec o =
  match Request.parse o.comment with
  | Error e -> print_endline e; exit 1
  | Ok request -> (
    match request.action with
    | Request.Help -> cmd_help o
    | Request.Cancel id ->
      Printf.printf "action: cancel %s (no config generated)\n" id
    | Request.Run | Request.Rerun -> (
      if o.variants = [] then
        die
          "no --variant given: `spec` needs runtimes already resolved to a \
           version or a sha";
      let svc = load_service o in
      (* The allowlist and the admin-only keys (force=, priority=) are checked
         before any work happens when we know who asked; the CLI can omit
         --login for local testing, which skips both. *)
      (match (svc, o.login) with
      | Some c, Some login -> (
        let d = Authz.check c ~login ~association:o.association in
        match Authz.auth d with
        | None ->
          print_endline (Authz.message d);
          exit 1
        | Some auth -> (
          match Authz.vet_request auth request with
          | Ok () -> ()
          | Error e ->
            print_endline e.Api.error_markdown;
            exit 1))
      | _ -> ());
      (* `machine=` in the comment wins over the flag: the flag is an operator
         default, the comment is what the user asked for. *)
      let o =
        match request.machine with
        | Some _ as m -> { o with machine = m }
        | None -> o
      in
      let pl = resolve_placement o svc in
      let facts = load_facts o in
      let sweepable = load_sweepable o in
      (* Check the tags before asking the bridge to filter on them: running-ng's
         own message lists raw tag names and cannot suggest an alias, so ours is
         the better one to show a user. *)
      List.iter
        (fun (requested, tag) ->
          match Gen.check_tag facts ~requested tag with
          | Error e -> print_endline e.Api.error_markdown; exit 1
          | Ok () -> ())
        (Request.tag_pairs request);
      (* Program count from running-ng's own tag filter (union across tags,
         intersection with enabled benchmarks), not our approximation of it. *)
      let program_count =
        match
          Bridge.tagfilter (bridge_of o) ~config:o.base_config
            ~tags:(Request.resolved_tags request)
        with
        | Ok n -> n
        | Error errs ->
          die "tag filter failed:\n  - %s" (String.concat "\n  - " errs)
      in
      let out_dir =
        match o.out_dir with Some d -> d | None -> Filename.get_temp_dir_name ()
      in
      let config_path = Filename.concat out_dir (o.request_id ^ ".yml") in
      let ctx =
        {
          Gen.request_id = o.request_id;
          base_include = o.base_config;
          config_path;
          macro_bench_dir = pl.p_macro_bench_dir;
          log_dir = pl.p_log_dir;
          opamroot = pl.p_opamroot;
          machine = pl.p_machine;
          requested_by =
            (match o.requested_by with Some u -> Some u | None -> o.login);
          pr_url = o.pr_url;
          program_count;
          cell_seconds = pl.p_cell;
          cap_seconds = pl.p_cap;
        }
      in
      match Gen.generate ~ctx ~request ~facts ~sweepable ~variants:o.variants with
      | Error e -> print_endline e.Api.error_markdown; exit 1
      | Ok spec ->
        Util.write_file config_path spec.config_yaml;
        (* The run spec is always written, whatever --format prints: it is the
           artifact the runner consumes and the provenance record archived
           beside the results.  See docs/RUNSPEC.md. *)
        (* Sources carry shas, never refs (§6.1): pinned here from the local
           checkouts, exactly as the server does. *)
        let src name dir ref_ =
          match Resolver.local_source ~name ~dir ~ref_ () with
          | Ok s -> s
          | Error e -> die "%s" e.Api.error_markdown
        in
        let sources =
          [
            src "running-ng" o.running_ng_dir o.running_ng_ref;
            src "macro-benches" pl.p_macro_bench_dir o.macro_benches_ref;
          ]
        in
        let runspec_path =
          Filename.concat out_dir (o.request_id ^ ".runspec.json")
        in
        (* run_key: null on purpose.  The §8.1 key hashes tool versions and
           the machine's environment fingerprint, which only agent reports can
           supply; a partial key would be a wrong one. *)
        let runspec_json =
          Runspec.to_string ~ctx ~request ~spec ~variants:o.variants ~sources
            ~run_key:None
        in
        Util.write_file runspec_path runspec_json;
        if o.format = "json" then print_string runspec_json
        else begin
          print_string spec.config_yaml;
          print_newline ();
          print_endline "# --- environment ---";
          List.iter
            (fun (k, v) -> Printf.printf "export %s=%s\n" k (Filename.quote v))
            spec.env;
          Printf.printf "\n# estimate: %s\n" (Cost.explain spec.cost);
          Printf.printf "# timeout:  %s\n"
            (Cost.human (float_of_int (Runspec.timeout_seconds ~cost:spec.cost)));
          Printf.printf "# config:   %s\n" config_path;
          Printf.printf "# run spec: %s\n" runspec_path;
          List.iter (fun w -> Printf.printf "# warning: %s\n" w) spec.warnings
        end;
        if o.check then
          match Bridge.validate (bridge_of o) ~config:config_path with
          | Ok () -> print_endline "# validate(): OK"
          | Error errs ->
            List.iter (fun e -> Printf.printf "# validate() ERROR: %s\n" e) errs;
            exit 1))

let () =
  match Array.to_list Sys.argv with
  | _ :: cmd :: rest ->
    let o = parse_args rest in
    (match cmd with
    | "parse" -> cmd_parse o
    | "spec" -> cmd_spec o
    | "help" -> cmd_help o
    | "vocab" -> cmd_vocab o
    | "authz" -> cmd_authz o
    | "-h" | "--help" -> usage ()
    | other -> die "unknown command %s (try --help)" other)
  | _ -> usage ()
