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
  base_config : string;
  vocab_file : string;
  running_ng_src : string;
  running_ng_dir : string;
  running_ng_ref : string;
  macro_benches_ref : string;
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
    base_config =
      Filename.concat home "running-ng/src/running/config/base/ocaml/macro_base.yml";
    vocab_file = Filename.concat home "ocaml-bench-dashboard/schema/json/vocab.json";
    running_ng_src = Filename.concat home "running-ng/src";
    running_ng_dir = Filename.concat home "running-ng";
    running_ng_ref = "origin/adding-ocaml-support";
    macro_benches_ref = "origin/master";
    helper = Filename.concat (Sys.getcwd ()) "scripts/rng_helper.py";
    max_active_per_user = 2;
  }

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
  --base-config --vocab --running-ng-src --running-ng-dir --running-ng-ref
  --macro-benches-ref --helper --max-active-per-user
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
      | "--base-config" -> set (fun v -> { !o with base_config = v })
      | "--vocab" -> set (fun v -> { !o with vocab_file = v })
      | "--running-ng-src" -> set (fun v -> { !o with running_ng_src = v })
      | "--running-ng-dir" -> set (fun v -> { !o with running_ng_dir = v })
      | "--running-ng-ref" -> set (fun v -> { !o with running_ng_ref = v })
      | "--macro-benches-ref" -> set (fun v -> { !o with macro_benches_ref = v })
      | "--helper" -> set (fun v -> { !o with helper = v })
      | "--max-active-per-user" ->
        set (fun v -> { !o with max_active_per_user = int_of_string v })
      | "-h" | "--help" -> usage ()
      | other -> die "unknown flag %s (try --help)" other)
  in
  go argv;
  !o

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
  let resolver =
    match o.resolver with
    | "offline" -> Resolver.offline
    | "github" ->
      Resolver.github
        {
          (Resolver.github_defaults
             ~cache_dir:(Filename.concat o.state_dir "git-cache"))
          with
          compiler_repo = service.Service_config.compiler_repo;
        }
    | other -> die "unknown resolver %s (github|offline)" other
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
    resolver;
    sources =
      [
        Runspec.source ~name:"running-ng" ~dir:o.running_ng_dir
          ~git_ref:o.running_ng_ref ();
        Runspec.source ~name:"macro-benches" ~dir:macro_bench_dir
          ~git_ref:o.macro_benches_ref ();
      ];
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
  let d = deps o in
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
  Printf.printf "bench-serve: listening on %s (resolver: %s, queue: %s)\n%!"
    listen o.resolver
    (Filename.concat o.state_dir "runs");
  Eio.Fiber.await_cancel ()
