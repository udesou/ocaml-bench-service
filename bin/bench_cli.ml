(* bench-cli -- the thin client of API A.

     submit "<command>"   send a /bench command; prints the acknowledgement
     status <run-id>      one run's state
     list                 the runs index (newest first)
     cancel <run-id>      cancel a queued run (owner or admin)
     help                 the /bench reference, served by the server
     vocab                machines, families, tags, sweepable params

   Thin means thin: this binary parses NOTHING of the /bench grammar and
   renders NOTHING itself -- it builds an API A `submit` payload, hands it to
   the server, and prints whatever markdown comes back (Q13: the grammar lives
   in the server; there is no offline mode).

   The server it talks to is IN-PROCESS for now, instantiated from the same
   service.json and backed by the file queue under --state-dir.  When the
   transport lands (capnp, Q15) this file keeps its interface and loses the
   instantiation. *)

open Bench_service

let home = try Sys.getenv "HOME" with Not_found -> "."

type opts = {
  service_config : string;
  login : string;
  state_dir : string;
  base_url : string;
  base_config : string;
  vocab_file : string;
  running_ng_src : string;
  running_ng_dir : string;
  running_ng_ref : string;
  macro_benches_ref : string;
  helper : string;
  mine : bool;
  limit : int;
}

let default_opts () =
  {
    service_config = "service.json";
    login = (try Sys.getenv "USER" with Not_found -> "");
    state_dir = Filename.concat home ".ocaml-bench-service";
    base_url = "http://localhost";
    base_config =
      Filename.concat home "running-ng/src/running/config/base/ocaml/macro_base.yml";
    vocab_file = Filename.concat home "ocaml-bench-dashboard/schema/json/vocab.json";
    running_ng_src = Filename.concat home "running-ng/src";
    running_ng_dir = Filename.concat home "running-ng";
    running_ng_ref = "origin/adding-ocaml-support";
    macro_benches_ref = "origin/master";
    helper = Filename.concat (Sys.getcwd ()) "scripts/rng_helper.py";
    mine = false;
    limit = 25;
  }

let die fmt = Printf.ksprintf (fun s -> prerr_endline s; exit 2) fmt

let usage () =
  print_string
    {|bench-cli -- submit and watch benchmark runs (a thin API A client)

  bench-cli submit "/bench tag=small invocations=1 vs=5.5.0,<sha>"
  bench-cli status <run-id>
  bench-cli list [--mine] [--limit N]
  bench-cli cancel <run-id>
  bench-cli help
  bench-cli vocab

The grammar lives in the server: run `bench-cli help` for the /bench
reference. `vs=` names the compilers (first = baseline); versions and commit
shas resolve offline, refs like `trunk` need the GitHub resolver (not wired
up yet).

Options: --service-config (default service.json) --login (default $USER)
         --state-dir --base-url --base-config --vocab --running-ng-src
         --running-ng-dir --running-ng-ref --macro-benches-ref --helper
         --mine --limit
|};
  exit 0

let parse_args argv =
  let o = ref (default_opts ()) in
  let positional = ref [] in
  let rec go = function
    | [] -> ()
    | flag :: rest ->
      let need () =
        match rest with v :: tl -> (v, tl) | [] -> die "%s needs a value" flag
      in
      let set f = let v, tl = need () in o := f v; go tl in
      (match flag with
      | "--service-config" -> set (fun v -> { !o with service_config = v })
      | "--login" -> set (fun v -> { !o with login = v })
      | "--state-dir" -> set (fun v -> { !o with state_dir = v })
      | "--base-url" -> set (fun v -> { !o with base_url = v })
      | "--base-config" -> set (fun v -> { !o with base_config = v })
      | "--vocab" -> set (fun v -> { !o with vocab_file = v })
      | "--running-ng-src" -> set (fun v -> { !o with running_ng_src = v })
      | "--running-ng-dir" -> set (fun v -> { !o with running_ng_dir = v })
      | "--running-ng-ref" -> set (fun v -> { !o with running_ng_ref = v })
      | "--macro-benches-ref" -> set (fun v -> { !o with macro_benches_ref = v })
      | "--helper" -> set (fun v -> { !o with helper = v })
      | "--limit" -> set (fun v -> { !o with limit = int_of_string v })
      | "--mine" -> o := { !o with mine = true }; go rest
      | "-h" | "--help" -> usage ()
      | arg when String.length arg > 0 && arg.[0] = '-' ->
        die "unknown flag %s (try --help)" arg
      | arg -> positional := !positional @ [ arg ]; go rest)
  in
  go argv;
  (!o, !positional)

let deps o =
  let service =
    match Service_config.of_file o.service_config with
    | Ok c -> c
    | Error e -> die "bad service config %s: %s" o.service_config e
  in
  let bridge =
    Bridge.default_config ~helper:o.helper ~running_ng_src:o.running_ng_src ()
  in
  let facts =
    match Bridge.facts bridge ~config:o.base_config with
    | Ok f -> f
    | Error e -> die "could not read base config facts: %s" e
  in
  let sweepable =
    match Vocab.of_file o.vocab_file with
    | Ok d -> d
    | Error e -> die "could not read %s: %s" o.vocab_file e
  in
  let macro_bench_dir =
    match Service_config.default_machine service with
    | Some m -> m.Service_config.macro_bench_dir
    | None -> die "no machines registered"
  in
  {
    Server.service;
    facts;
    sweepable;
    base_include = o.base_config;
    program_count =
      (fun ~tags ->
        match Bridge.tagfilter bridge ~config:o.base_config ~tags with
        | Ok n -> Ok n
        | Error errs -> Error (String.concat "; " errs));
    resolver = Resolver.offline;
    sources =
      [
        Runspec.source ~name:"running-ng" ~dir:o.running_ng_dir
          ~git_ref:o.running_ng_ref ();
        Runspec.source ~name:"macro-benches" ~dir:macro_bench_dir
          ~git_ref:o.macro_benches_ref ();
      ];
    state_dir = o.state_dir;
    base_url = o.base_url;
    max_active_per_user = 2;
  }

(* The role is a claim the server re-derives from its config; User is the
   honest default claim. *)
let auth o = { Api.login = o.login; role = Api.User }

let fail_api (e : Api.error) =
  print_endline e.Api.error_markdown;
  exit 1

let cmd_submit o command =
  let d = deps o in
  let submit =
    {
      Api.command;
      origin = { Api.kind = Api.Cli; id = "cli:" ^ o.login };
    }
  in
  match Server.submit d (auth o) submit with
  | Error e -> fail_api e
  | Ok (Api.Accepted a) -> print_endline a.Api.ack_markdown
  | Ok (Api.Reused r) -> print_endline r.Api.ack_markdown
  | Ok (Api.Duplicate { run_id; _ }) ->
    Printf.printf "Already submitted: this command is `%s` (still active).\n"
      run_id

let cmd_status o run_id =
  match Server.status (deps o) (auth o) ~run_id with
  | Error e -> fail_api e
  | Ok st ->
    print_endline (Yojson.Safe.pretty_to_string (Api.json_of_run_status st))

let cmd_list o =
  let d = deps o in
  let filter =
    if o.mine then { Api.no_filter with Api.requester = Some (String.lowercase_ascii o.login) }
    else Api.no_filter
  in
  match Server.list d (auth o) filter { Api.limit = o.limit; after = None } with
  | Error e -> fail_api e
  | Ok metas ->
    if metas = [] then print_endline "no runs"
    else
      List.iter
        (fun (m : Api.meta) ->
          Printf.printf "%-20s %-10s %-12s %-10s %s\n" m.Api.run_id
            (Api.string_of_run_state m.Api.state)
            m.Api.requested_by m.Api.machine m.Api.command)
        metas

let cmd_cancel o run_id =
  match Server.cancel (deps o) (auth o) ~run_id with
  | Error e -> fail_api e
  | Ok () -> Printf.printf "cancelled %s\n" run_id

let () =
  match Array.to_list Sys.argv with
  | _ :: cmd :: rest -> (
    let o, positional = parse_args rest in
    match (cmd, positional) with
    | "submit", [ command ] -> cmd_submit o command
    | "submit", _ -> die "submit takes exactly one argument: the /bench command"
    | "status", [ id ] -> cmd_status o id
    | "status", _ -> die "status takes exactly one argument: the run id"
    | "list", [] -> cmd_list o
    | "cancel", [ id ] -> cmd_cancel o id
    | "cancel", _ -> die "cancel takes exactly one argument: the run id"
    | "help", [] -> print_string (Server.help (deps o) ())
    | "vocab", [] ->
      print_endline
        (Yojson.Safe.pretty_to_string
           (Api.json_of_vocab (Server.vocab (deps o) ())))
    | ("-h" | "--help"), _ -> usage ()
    | other, _ -> die "unknown command %s (try --help)" other)
  | _ -> usage ()
