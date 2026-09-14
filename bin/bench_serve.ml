(* bench-serve -- the request server daemon.

   Hosts the API A implementation (lib/server.ml) behind Cap'n Proto (Q15).
   Identity is a capability file, ocluster's model: at startup the daemon
   (re)writes <caps-dir>/<login>.cap for every login in the allowlist and
   admins list, plus bot.cap for the PR bot.  Handing someone their file is
   how access is granted; deleting a login from service.json and restarting
   revokes it (the sturdy ids derive from the login and the vat's secret key,
   so a removed login's old file no longer restores to anything).

   The default listen address is a unix-domain socket under the state dir;
   pass --listen tcp:HOST:PORT (and usually --public-address) to serve over
   the network. *)

open Bench_service
open Bench_rpc

let home = try Sys.getenv "HOME" with Not_found -> "."
let default_state = Filename.concat home ".ocaml-bench-service"

type opts = {
  service_config : string;
  state_dir : string;
  listen : string option;
  public_address : string option;
  caps_dir : string option;
  secret_key : string option;
  resolver : string;
  base_url : string;
  (* Every path the server reads code or metadata from is an OPTION whose
     default hangs off --state-dir (below).  The server owns its clones: a
     host that also carries a developer checkout, or a bench agent, must not
     share git objects, refs or build products with the service. *)
  base_config : string option;
      (* given: use flag paths verbatim instead of extracting from the
         running-ng pin (hermetic runs, the live check) *)
  vocab_file : string option;
  running_ng_src : string option;
  running_ng_dir : string option;
  running_ng_ref : string;
  macro_benches_dir : string option;
  macro_benches_ref : string;
  olly_dir : string option;
  olly_ref : string;
  dashboard_dir : string option;
  dashboard_ref : string;
  helper : string;
  max_active_per_user : int;
}

let default_opts () =
  {
    service_config = "service.json";
    state_dir = default_state;
    listen = None;
    public_address = None;
    caps_dir = None;
    secret_key = None;
    resolver = "github";
    base_url = "http://localhost";
    base_config = None;
    vocab_file = None;
    running_ng_src = None;
    running_ng_dir = None;
    running_ng_ref = "origin/adding-ocaml-support";
    macro_benches_dir = None;
    macro_benches_ref = "origin/master";
    olly_dir = None;
    olly_ref = "origin/main";
    dashboard_dir = None;
    dashboard_ref = "origin/main";
    helper = Filename.concat (Sys.getcwd ()) "scripts/rng_helper.py";
    max_active_per_user = 2;
  }

(* The server's own clones live under <state>/git/<name>.  Filename.concat
   rather than "/" so this stays right wherever the service is built. *)
let repo_dir o name = Filename.concat (Filename.concat o.state_dir "git") name

let running_ng_dir o =
  Option.value o.running_ng_dir ~default:(repo_dir o "running-ng")

let macro_benches_dir o =
  Option.value o.macro_benches_dir ~default:(repo_dir o "macro-benches")

let olly_dir o = Option.value o.olly_dir ~default:(repo_dir o "runtime_events_tools")

let dashboard_dir o =
  Option.value o.dashboard_dir ~default:(repo_dir o "ocaml-bench-dashboard")

let vocab_file o =
  Option.value o.vocab_file
    ~default:(Filename.concat (dashboard_dir o) "schema/json/vocab.json")

let die fmt = Printf.ksprintf (fun s -> prerr_endline s; exit 2) fmt

let usage () =
  print_string
    {|bench-serve -- the benchmarking request server (Cap'n Proto)

  bench-serve --service-config service.json [--listen tcp:0.0.0.0:7000]

On startup, writes one capability file per configured login into --caps-dir
(default <state-dir>/caps): <login>.cap for each allowlist/admins entry and
bot.cap for the PR bot. Hand people their file; that file IS their access.

Options:
  --service-config FILE   (default service.json)
  --state-dir DIR         queue + keys + caps (default ~/.ocaml-bench-service)
  --listen ADDR           unix:PATH or tcp:HOST:PORT
                          (default unix:<state-dir>/server.sock)
  --public-address ADDR   the address written into capability files
  --caps-dir DIR          where to write *.cap (default <state-dir>/caps)
  --secret-key FILE       vat key (default <state-dir>/secret-key.pem)
  --resolver github|offline
                          how vs=/PR refs become shas (default github;
                          offline accepts only versions and commit shas)
  --base-url URL          links in acknowledgements
  --running-ng-dir DIR    the server's own clone of running-ng, whose pin the
                          base config and python are extracted from
                          (default <state-dir>/git/running-ng); likewise
  --macro-benches-dir --olly-dir --dashboard-dir, each defaulting to
                          <state-dir>/git/<repo>.  These are the SERVER's
                          clones: point them at a developer checkout only
                          deliberately, and never on a host that also runs a
                          bench agent.  scripts/server-setup.sh creates them.
  --vocab FILE            (default <dashboard-dir>/schema/json/vocab.json)
  --base-config FILE      skip the pin extraction and read this config
                          verbatim (hermetic runs, the live check)
  --running-ng-src DIR    python for --base-config (default <running-ng-dir>/src)
  --running-ng-ref --macro-benches-ref --olly-ref --dashboard-ref
                          the tracked refs pins are SEEDED from on first start
  --helper --max-active-per-user
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
      | "--service-config" -> set (fun v -> { !o with service_config = v })
      | "--state-dir" -> set (fun v -> { !o with state_dir = v })
      | "--listen" -> set (fun v -> { !o with listen = Some v })
      | "--public-address" -> set (fun v -> { !o with public_address = Some v })
      | "--caps-dir" -> set (fun v -> { !o with caps_dir = Some v })
      | "--secret-key" -> set (fun v -> { !o with secret_key = Some v })
      | "--resolver" -> set (fun v -> { !o with resolver = v })
      | "--base-url" -> set (fun v -> { !o with base_url = v })
      | "--base-config" -> set (fun v -> { !o with base_config = Some v })
      | "--vocab" -> set (fun v -> { !o with vocab_file = Some v })
      | "--running-ng-src" -> set (fun v -> { !o with running_ng_src = Some v })
      | "--running-ng-dir" -> set (fun v -> { !o with running_ng_dir = Some v })
      | "--running-ng-ref" -> set (fun v -> { !o with running_ng_ref = v })
      | "--macro-benches-dir" -> set (fun v -> { !o with macro_benches_dir = Some v })
      | "--macro-benches-ref" -> set (fun v -> { !o with macro_benches_ref = v })
      | "--olly-dir" -> set (fun v -> { !o with olly_dir = Some v })
      | "--olly-ref" -> set (fun v -> { !o with olly_ref = v })
      | "--dashboard-dir" -> set (fun v -> { !o with dashboard_dir = Some v })
      | "--dashboard-ref" -> set (fun v -> { !o with dashboard_ref = v })
      | "--helper" -> set (fun v -> { !o with helper = v })
      | "--max-active-per-user" ->
        set (fun v -> { !o with max_active_per_user = int_of_string v })
      | "-h" | "--help" -> usage ()
      | other -> die "unknown flag %s (try --help)" other)
  in
  go argv;
  !o

(* extract a running-ng tree at a pinned commit (the config AND the python
   must come from the same sha the specs pin) *)
let extract_tree ~dir ~commit ~dst =
  let q = Filename.quote in
  if Sys.command (Printf.sprintf "rm -rf %s && mkdir -p %s" (q dst) (q dst)) <> 0
  then Error ("could not prepare " ^ dst)
  else if
    Sys.command
      (Printf.sprintf "git -C %s archive %s | tar -x -C %s" (q dir) (q commit)
         (q dst))
    <> 0
  then Error (Printf.sprintf "could not extract %s at %s" dir commit)
  else Ok ()

let base_in_tree dst =
  Filename.concat dst "src/running/config/base/ocaml/macro_base.yml"

let deps o ~on_bump =
  let service =
    match Service_config.of_file o.service_config with
    | Ok c -> c
    | Error e -> die "bad service config %s: %s" o.service_config e
  in
  (* The pins: seeded from these SERVER-SIDE checkouts on first start, then
     changed only by `bump` (+ restart).  Missing checkouts are skipped with
     a warning.  These are the server's metadata clones, nothing to do with
     where the agent checks sources out (§6.1: the agent owns its paths). *)
  let pin_config =
    [
      (Api.Running_ng, running_ng_dir o, o.running_ng_ref);
      (Api.Macro_benches, macro_benches_dir o, o.macro_benches_ref);
      (Api.Olly, olly_dir o, o.olly_ref);
      (Api.Dashboard, dashboard_dir o, o.dashboard_ref);
    ]
  in
  let pins = Server.init_pins ~state_dir:o.state_dir ~pin_config in
  let find_pin c =
    List.find_opt (fun (p : Api.pin) -> p.Api.pinned_component = c) pins
  in
  (* base config + running-ng python follow the PIN, not the working copy;
     --base-config overrides for hermetic runs (the live check). *)
  let base_config, running_ng_src =
    match o.base_config with
    | Some bc ->
      ( bc,
        Option.value o.running_ng_src
          ~default:(Filename.concat (running_ng_dir o) "src") )
    | None -> (
      match find_pin Api.Running_ng with
      | None ->
        die
          "no running-ng pin (is %s a checkout?  scripts/server-setup.sh \
           creates the server's own clones) and no --base-config override"
          (running_ng_dir o)
      | Some p -> (
        let dst = Filename.concat o.state_dir "running-ng-src" in
        match extract_tree ~dir:(running_ng_dir o) ~commit:p.Api.commit ~dst with
        | Error m -> die "%s" m
        | Ok () -> (base_in_tree dst, Filename.concat dst "src")))
  in
  let bridge =
    Bridge.default_config ~helper:o.helper ~running_ng_src ()
  in
  let facts =
    match Bridge.facts bridge ~config:base_config with
    | Ok f -> f
    | Error e -> die "could not read base config facts: %s" e
  in
  let sweepable =
    match Vocab.of_file (vocab_file o) with
    | Ok d -> d
    | Error e -> die "could not read %s: %s" (vocab_file o) e
  in
  let resolver =
    match o.resolver with
    | "offline" ->
      Resolver.offline_with ~flavors:service.Service_config.flavors
    | "github" ->
      Resolver.github
        {
          (Resolver.github_defaults
             ~cache_dir:(Filename.concat o.state_dir "git-cache"))
          with
          compiler_repo = service.Service_config.compiler_repo;
          flavors = service.Service_config.flavors;
        }
    | other -> die "unknown resolver %s (github|offline)" other
  in
  {
    Server.service;
    facts;
    sweepable;
    base_include = base_config;
    program_count =
      (fun ~tags ->
        match Bridge.tagfilter bridge ~config:base_config ~tags with
        | Ok n -> Ok n
        | Error errs -> Error (String.concat "; " errs));
    resolver;
    (* per-run source snapshots come straight from the pins *)
    sources =
      List.filter_map
        (fun (p : Api.pin) ->
          match p.Api.pinned_component with
          | Api.Dashboard -> None (* presentation, not a run input *)
          | (Api.Running_ng | Api.Macro_benches | Api.Benches | Api.Olly) as c
            ->
            let dir =
              match List.find_opt (fun (c', _, _) -> c' = c) pin_config with
              | Some (_, d, _) -> d
              | None -> "."
            in
            let repo =
              match
                Resolver.git_run ~git:"git"
                  [ "-C"; dir; "remote"; "get-url"; "origin" ]
              with
              | Ok url when url <> "" -> url
              | _ -> dir
            in
            Some
              (Runspec.source ~name:(Api.string_of_component c) ~repo
                 ~commit:p.Api.commit ()))
        pins;
    pin_config;
    service_version =
      (match
         Resolver.git_run ~git:"git"
           [ "-C"; Sys.getcwd (); "describe"; "--always"; "--dirty" ]
       with
      | Ok v -> v
      | Error _ -> "unknown");
    validate_pin =
      (fun component ~commit ->
        match component with
        | Api.Running_ng -> (
          (* dry-run the candidate: extract it and load facts through its own
             python -- the drift class of failure surfaces HERE, not later *)
          let dst = Filename.concat o.state_dir "pin-check" in
          match extract_tree ~dir:(running_ng_dir o) ~commit ~dst with
          | Error m -> Error m
          | Ok () -> (
            let b =
              Bridge.default_config ~helper:o.helper
                ~running_ng_src:(Filename.concat dst "src") ()
            in
            match Bridge.facts b ~config:(base_in_tree dst) with
            | Ok _ -> Ok ()
            | Error m -> Error m))
        | _ -> Ok ());
    on_bump;
    state_dir = o.state_dir;
    base_url = o.base_url;
    max_active_per_user = o.max_active_per_user;
  }

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let () =
  Logs.set_level (Some Logs.Warning);
  Logs.set_reporter (Logs_fmt.reporter ());
  let o = parse_args (List.tl (Array.to_list Sys.argv)) in
  let bump_requested = ref false in
  let d = deps o ~on_bump:(fun () -> bump_requested := true) in
  mkdir_p o.state_dir;
  (* the webview snapshot survives restarts and backfills pre-webview runs *)
  Server.refresh_index d;
  let caps_dir =
    Option.value o.caps_dir ~default:(Filename.concat o.state_dir "caps")
  in
  mkdir_p caps_dir;
  let secret_key =
    Option.value o.secret_key
      ~default:(Filename.concat o.state_dir "secret-key.pem")
  in
  let listen =
    Option.value o.listen
      ~default:("unix:" ^ Filename.concat o.state_dir "server.sock")
  in
  let location s =
    match Capnp_rpc_unix.Network.Location.of_string s with
    | Ok l -> l
    | Error (`Msg m) -> die "bad address %s: %s" s m
  in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Eio.Switch.run @@ fun sw ->
  let config =
    Capnp_rpc_unix.Vat_config.create
      ?public_address:(Option.map location o.public_address)
      ~secret_key:(`File Eio.Path.(Eio.Stdenv.fs env / secret_key))
      ~net:(Eio.Stdenv.net env) (location listen)
  in
  let services =
    Capnp_rpc_net.Restorer.Table.create ~sw
      (Capnp_rpc_unix.Vat_config.sturdy_uri config)
  in
  (* One capability per configured login; the bot gets the asserting one. *)
  let logins =
    List.sort_uniq compare
      (d.Server.service.Service_config.allowlist
      @ d.Server.service.Service_config.admins)
  in
  let ids =
    List.map
      (fun login ->
        let id =
          Capnp_rpc_unix.Vat_config.derived_id config ("user:" ^ login)
        in
        Capnp_rpc_net.Restorer.Table.add services id
          (Rpc.bench_api d ~login);
        (login, id))
      logins
  in
  let bot_id = Capnp_rpc_unix.Vat_config.derived_id config "bot" in
  Capnp_rpc_net.Restorer.Table.add services bot_id (Rpc.bench_bot d);
  (* One agent capability per registered machine (§6.2): the file IS the
     machine's identity, exactly as <login>.cap is a user's.  It lives on the
     bench machine, which is treated as compromisable -- an agent capability
     can only claim/report its own machine's work, never submit or admin. *)
  let agent_ids =
    List.map
      (fun name ->
        let id =
          Capnp_rpc_unix.Vat_config.derived_id config ("agent:" ^ name)
        in
        Capnp_rpc_net.Restorer.Table.add services id
          (Rpc.agent_api d ~machine:name);
        (name, id))
      (Service_config.machine_names d.Server.service)
  in
  let restore = Capnp_rpc_net.Restorer.of_table services in
  let vat = Capnp_rpc_unix.serve ~sw ~restore config in
  let save id path =
    match Capnp_rpc_unix.Cap_file.save_service vat id path with
    | Ok () -> Printf.printf "  %s\n" path
    | Error (`Msg m) -> die "could not write %s: %s" path m
  in
  Printf.printf "capability files (hand these out; they ARE the access):\n";
  List.iter
    (fun (login, id) -> save id (Filename.concat caps_dir (login ^ ".cap")))
    ids;
  save bot_id (Filename.concat caps_dir "bot.cap");
  List.iter
    (fun (name, id) ->
      save id (Filename.concat caps_dir ("agent-" ^ name ^ ".cap")))
    agent_ids;
  Printf.printf "bench-serve: listening on %s (resolver: %s, queue: %s)\n%!"
    listen o.resolver
    (Filename.concat o.state_dir "runs");
  (* Adoption is a restart: after a bump, re-exec with the same argv (same
     pid, tmux session survives, pins.json is re-read).  The delay lets the
     bump reply flush to the client first. *)
  let clock = Eio.Stdenv.clock env in
  let rec watch () =
    Eio.Time.sleep clock 0.5;
    if !bump_requested then begin
      Eio.Time.sleep clock 1.5;
      Printf.printf "bench-serve: pins changed; restarting to adopt\n%!";
      Unix.execv Sys.executable_name Sys.argv
    end
    else watch ()
  in
  watch ()
