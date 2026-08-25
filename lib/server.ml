(* The request server: the first real implementation of API A.

   This is the §5.2 signature over the existing pipeline (grammar -> authz ->
   validation -> config -> run spec), with a FILE-BACKED QUEUE: every accepted
   run becomes a directory under <state>/runs/<run_id>/ holding meta.json (the
   §8 index record), request.json (the audit record), runspec.json and the
   generated config.  Nothing executes yet -- the queue is the edge where API B
   starts: a future agent's `claim` drains these directories.

   Scope of this build, stated rather than implied:

   * **In-process.**  The server is a library; bench-cli instantiates it
     directly.  A transport (capnp per Q15) wraps this module without changing
     it -- that is the point of the signature-first rule.
   * **Offline resolution** (Resolver.offline): versions and shas pass
     through, refs and PR-comment submissions are refused with instructions.
     The GitHub-backed resolver drops into `deps.resolver`.
   * **No result reuse yet**: run keys need resolved shas and agent-reported
     machine facts (tool versions, env fingerprint), so nothing computes them
     and `find_by_run_key` would never hit; submits therefore never answer
     `Reused`.  Idempotency (`Duplicate`) IS implemented, checked against
     ACTIVE runs only -- completed runs are run-key territory (§8.1).
   * `requeue`/`evict` refuse honestly: there are no executions or agents.

   Roles: the caller's `auth.role` is NOT trusted.  Identity (the login) is the
   transport's to prove; the ROLE is this server's to decide, from the admins
   list in service.json.  A client that self-declares Admin gets whatever the
   config says it gets. *)

type deps = {
  service : Service_config.t;
  facts : Facts.t;
  sweepable : Vocab.dim list;
  base_include : string;  (** the base config path used in generated configs *)
  program_count : tags:string list -> (int, string) result;
      (** running-ng's own tag filter, via the bridge; injectable for tests *)
  resolver : Resolver.t;
  sources : Runspec.source list;  (** pinned repos for the run spec *)
  state_dir : string;
  base_url : string;  (** links in acknowledgements point under here *)
  max_active_per_user : int;  (** queued+running cap per user (Q10) *)
}

let ( let* ) = Result.bind
let err code fmt = Api.error code fmt

(* --- state on disk --------------------------------------------------------- *)

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let runs_dir deps = Filename.concat deps.state_dir "runs"
let run_dir deps run_id = Filename.concat (runs_dir deps) run_id
let machines_file deps = Filename.concat deps.state_dir "machines.json"

let read_json path =
  match Yojson.Safe.from_string (Util.read_file path) with
  | j -> Some j
  | exception _ -> None

let write_json path j = Util.write_file path (Yojson.Safe.pretty_to_string j ^ "\n")

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let jstr = function `String s -> Some s | _ -> None

let iso_now () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.Unix.tm_year + 1900)
    (t.Unix.tm_mon + 1) t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min
    t.Unix.tm_sec

let meta_of deps run_id =
  match read_json (Filename.concat (run_dir deps run_id) "meta.json") with
  | None -> None
  | Some j -> ( match Api.meta_of_json j with Ok m -> Some m | Error _ -> None)

let request_json_of deps run_id =
  read_json (Filename.concat (run_dir deps run_id) "request.json")

let all_metas deps =
  let dir = runs_dir deps in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list
    |> List.filter_map (fun name -> meta_of deps name)
    (* newest first; ISO-8601 sorts lexicographically *)
    |> List.sort (fun (a : Api.meta) b -> compare b.queued_at a.queued_at)

let is_active (m : Api.meta) =
  match m.state with Api.Queued | Api.Running -> true | _ -> false

let save_meta deps (m : Api.meta) =
  write_json (Filename.concat (run_dir deps m.run_id) "meta.json")
    (Api.json_of_meta m)

let stamp deps run_id state_name =
  (* append state -> timestamp to request.json's audit trail *)
  match request_json_of deps run_id with
  | None -> ()
  | Some j ->
    let ts =
      match member "timestamps" j with `Assoc kvs -> kvs | _ -> []
    in
    let j' =
      match j with
      | `Assoc kvs ->
        `Assoc
          (List.remove_assoc "timestamps" kvs
          @ [ ("timestamps", `Assoc (ts @ [ (state_name, `String (iso_now ())) ])) ])
      | other -> other
    in
    write_json (Filename.concat (run_dir deps run_id) "request.json") j'

(* run-YYYYMMDD-NNN, dense per day, collision-checked against the directory *)
let fresh_run_id deps =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  let date =
    Printf.sprintf "%04d%02d%02d" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1)
      t.Unix.tm_mday
  in
  let rec go n =
    let id = Printf.sprintf "run-%s-%03d" date n in
    if Sys.file_exists (run_dir deps id) then go (n + 1) else id
  in
  go 1

let drained_machines deps =
  match read_json (machines_file deps) with
  | Some j -> (
    match member "drained" j with
    | `List l -> List.filter_map jstr l
    | _ -> [])
  | None -> []

let set_drained deps names =
  mkdir_p deps.state_dir;
  write_json (machines_file deps)
    (`Assoc [ ("drained", `List (List.map (fun n -> `String n) names)) ])

(* --- shared pieces --------------------------------------------------------- *)

let links deps run_id =
  {
    Api.status = Printf.sprintf "%s/runs/%s/status" deps.base_url run_id;
    webview = Printf.sprintf "%s/runs/%s/" deps.base_url run_id;
  }

(* The caller proves the login; the CONFIG decides the role and whether the
   login may trigger at all. *)
let effective_auth deps (a : Api.auth) =
  match Authz.check deps.service ~login:a.Api.login ~association:None with
  | Authz.Allowed (auth, _) -> Ok auth
  | Authz.Denied msg ->
    if String.trim a.Api.login = "" then Error { Api.code = Api.Unauthorized; error_markdown = msg }
    else Error { Api.code = Api.Forbidden; error_markdown = msg }

let require_admin (auth : Api.auth) =
  if auth.role = Api.Admin then Ok ()
  else
    err Api.Forbidden
      "Only admins may do that. Ask a maintainer listed in `admins`."

let pin_of_variant (v : Variant.t) =
  {
    Api.name = Variant.runtime_name v;
    commit =
      (match v.Variant.spec with
      | Variant.Commit sha -> sha
      (* Offline placeholder: the GitHub resolver pins the release tag's sha
         here.  Until then the version string is the truthful pin value. *)
      | Variant.Version ver -> ver);
    configure_args = v.Variant.configure_args;
  }

let build_vocab deps =
  {
    Api.machines = Service_config.machine_names deps.service;
    families = [ Api.Macro ];
    tags = Tag_alias.vocabulary ~defined:(Facts.tag_names deps.facts);
    sweepable =
      List.map
        (fun (d : Vocab.dim) ->
          { Api.param = d.modifier; dimension = d.dimension; unit_ = d.unit_ })
        deps.sweepable;
    max_invocations = Request.max_invocations;
  }

let render_help deps =
  let machines = Service_config.machine_names deps.service in
  let default_machine =
    match Service_config.default_machine deps.service with
    | Some m -> m.Service_config.name
    | None -> "none"
  in
  Help.render ~facts:deps.facts ~sweepable:deps.sweepable ~machines
    ~cap_seconds:deps.service.Service_config.cap_seconds ~default_machine

let render_ack deps ~run_id ~(request : Request.t) ~(spec : Gen.t) ~machine
    ~queue_position ~variants =
  let b = Buffer.create 1024 in
  let add fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  let l = links deps run_id in
  add "**Benchmark run `%s` queued** (position %d).\n\n" run_id queue_position;
  add "- command: `%s`\n" (Util.trim request.Request.raw);
  (match variants with
  | baseline :: candidates ->
    add "- baseline: `%s`" (Variant.runtime_name baseline);
    if candidates <> [] then
      add " · candidates: %s"
        (String.concat ", "
           (List.map (fun v -> "`" ^ Variant.runtime_name v ^ "`") candidates));
    add "\n"
  | [] -> ());
  add "- selection: %s — %d programs × %d configs × %d invocations\n"
    (String.concat ", " (List.map Tag_alias.friendly spec.Gen.tags))
    spec.Gen.cost.Cost.programs spec.Gen.cost.Cost.configs
    spec.Gen.cost.Cost.invocations;
  add "- machine: `%s` · estimate: %s\n" machine
    (Cost.human spec.Gen.cost.Cost.seconds);
  add "- [status](%s) · [results when done](%s)\n" l.Api.status l.Api.webview;
  List.iter (fun w -> add "\n> %s" w) spec.Gen.warnings;
  Buffer.contents b

(* --- the API A functions ---------------------------------------------------- *)

let submit deps (auth0 : Api.auth) (s : Api.submit) =
  let* auth = effective_auth deps auth0 in
  let* request =
    match Request.parse s.Api.command with
    | Ok r -> Ok r
    | Error e -> Error { Api.code = Api.Bad_command; error_markdown = e }
  in
  match request.Request.action with
  (* GAP raised on the document: submit_outcome has no arm for help/cancel
     commands, yet the grammar lives in the server (Q13), so a bot cannot
     pre-parse them.  Until that is decided: help answers through the error
     envelope (whose text is postable verbatim, which is exactly what a bot
     does with it), cancel points at the cancel operation. *)
  | Request.Help ->
    Error { Api.code = Api.Bad_command; error_markdown = render_help deps }
  | Request.Cancel id ->
    err Api.Bad_command
      "Cancellation is its own operation: run `bench-cli cancel %s`." id
  | Request.Run | Request.Rerun ->
    let* () = Authz.vet_request auth request in
    let* machine =
      match
        Service_config.resolve_machine deps.service request.Request.machine
      with
      | Ok m -> Ok m
      | Error msg -> Error { Api.code = Api.Unknown_machine; error_markdown = msg }
    in
    let* () =
      if List.mem machine.Service_config.name (drained_machines deps) then
        err Api.Machine_drained
          "Machine `%s` is drained for maintenance; try again later or pick \
           another machine."
          machine.Service_config.name
      else Ok ()
    in
    let* variants =
      deps.resolver.Resolver.variants ~origin:s.Api.origin ~vs:request.Request.vs
    in
    let normalized =
      String.concat " " (Util.tokens (Util.trim request.Request.raw))
    in
    let active = List.filter is_active (all_metas deps) in
    let duplicate =
      List.find_opt
        (fun (m : Api.meta) ->
          match request_json_of deps m.run_id with
          | None -> false
          | Some j ->
            jstr (member "origin_id" j) = Some s.Api.origin.Api.id
            && jstr (member "normalized" j) = Some normalized)
        active
    in
    (match duplicate with
    | Some m ->
      Ok (Api.Duplicate { run_id = m.run_id; links = links deps m.run_id })
    | None ->
      let* () =
        let mine =
          List.filter
            (fun (m : Api.meta) -> m.requested_by = auth.Api.login)
            active
        in
        if auth.Api.role = Api.User && List.length mine >= deps.max_active_per_user
        then
          err Api.User_queue_full
            "You already have %d active run(s) (%s) -- the limit per user. \
             Wait for one to finish or cancel it."
            (List.length mine)
            (String.concat ", "
               (List.map (fun (m : Api.meta) -> "`" ^ m.run_id ^ "`") mine))
        else Ok ()
      in
      let* () =
        List.fold_left
          (fun acc (requested, tag) ->
            match acc with
            | Error _ -> acc
            | Ok () -> Gen.check_tag deps.facts ~requested tag)
          (Ok ()) (Request.tag_pairs request)
      in
      let* program_count =
        match deps.program_count ~tags:(Request.resolved_tags request) with
        | Ok n -> Ok n
        | Error msg ->
          err Api.Bad_command "The benchmark selection failed to resolve: %s"
            msg
      in
      let run_id = fresh_run_id deps in
      let pr_url =
        match s.Api.origin.Api.kind with
        | Api.Pr_comment ctx -> Some ctx.Api.url
        | Api.Cli -> None
      in
      let ctx =
        {
          Gen.request_id = run_id;
          base_include = deps.base_include;
          (* machine-side path: the agent writes the config next to the logs *)
          config_path =
            Filename.concat machine.Service_config.log_dir (run_id ^ ".yml");
          macro_bench_dir = machine.Service_config.macro_bench_dir;
          log_dir = machine.Service_config.log_dir;
          opamroot = machine.Service_config.opamroot;
          machine = machine.Service_config.name;
          requested_by = Some auth.Api.login;
          pr_url;
          program_count;
          cell_seconds = deps.service.Service_config.cell_seconds;
          cap_seconds = deps.service.Service_config.cap_seconds;
        }
      in
      let* spec = Gen.generate ~ctx ~request ~facts:deps.facts
          ~sweepable:deps.sweepable ~variants
      in
      (* persist the run: this directory IS the queue row *)
      let dir = run_dir deps run_id in
      mkdir_p dir;
      let slot =
        Printf.sprintf "%s:%s" machine.Service_config.name
          (Option.value machine.Service_config.opamroot
             ~default:"default-opamroot")
      in
      Util.write_file
        (Filename.concat dir "runspec.json")
        (Runspec.to_string ~ctx ~request ~spec ~variants ~sources:deps.sources
           ~run_key:None ~slot);
      Util.write_file (Filename.concat dir "config.yml") spec.Gen.config_yaml;
      let now = iso_now () in
      write_json
        (Filename.concat dir "request.json")
        (`Assoc
          [
            ( "origin_kind",
              `String
                (match s.Api.origin.Api.kind with
                | Api.Pr_comment _ -> "pr_comment"
                | Api.Cli -> "cli") );
            ("origin_id", `String s.Api.origin.Api.id);
            ("pr_url", match pr_url with Some u -> `String u | None -> `Null);
            ("login", `String auth.Api.login);
            ("command", `String (Util.trim request.Request.raw));
            ("normalized", `String normalized);
            ( "priority",
              match request.Request.priority with
              | Some Request.Top -> `String "top"
              | None -> `Null );
            ("timestamps", `Assoc [ ("queued", `String now) ]);
          ]);
      let baseline = List.hd variants in
      let candidates = List.tl variants in
      let meta =
        {
          Api.run_id;
          state = Api.Queued;
          run_key = "";
          pr_url;
          requested_by = auth.Api.login;
          command = Util.trim request.Request.raw;
          machine = machine.Service_config.name;
          family = request.Request.family;
          queued_at = now;
          finished_at = None;
          summary = None;
          links = links deps run_id;
        }
      in
      save_meta deps meta;
      let priority_of (m : Api.meta) =
        match request_json_of deps m.run_id with
        | Some j -> jstr (member "priority" j) = Some "top"
        | None -> false
      in
      let queued =
        List.filter (fun (m : Api.meta) -> m.state = Api.Queued) active
      in
      let queue_position =
        match request.Request.priority with
        | Some Request.Top -> 1 + List.length (List.filter priority_of queued)
        | None -> 1 + List.length queued
      in
      let resolved =
        {
          Api.baseline = pin_of_variant baseline;
          candidates = List.map pin_of_variant candidates;
          family = request.Request.family;
          tags = spec.Gen.tags;
          invocations = spec.Gen.cost.Cost.invocations;
          machine = machine.Service_config.name;
        }
      in
      Ok
        (Api.Accepted
           {
             run_id;
             queue_position;
             estimate_seconds = int_of_float spec.Gen.cost.Cost.seconds;
             resolved;
             links = links deps run_id;
             ack_markdown =
               render_ack deps ~run_id ~request ~spec
                 ~machine:machine.Service_config.name ~queue_position ~variants;
           }))

let status deps (auth0 : Api.auth) ~run_id =
  let* _auth = effective_auth deps auth0 in
  match meta_of deps run_id with
  | None -> err Api.Not_found "No run `%s` is known to this server." run_id
  | Some m ->
    let timestamps =
      match request_json_of deps run_id with
      | Some j -> (
        match member "timestamps" j with
        | `Assoc kvs ->
          List.filter_map
            (fun (k, v) -> Option.map (fun ts -> (k, ts)) (jstr v))
            kvs
        | _ -> [])
      | None -> []
    in
    Ok
      {
        Api.run_id = m.run_id;
        state = m.state;
        progress = None;  (* nothing executes yet: API B territory *)
        machine = m.machine;
        timestamps;
        completion = None;
      }

let events deps (auth0 : Api.auth) ~run_id ~since =
  let* _auth = effective_auth deps auth0 in
  match meta_of deps run_id with
  | None -> err Api.Not_found "No run `%s` is known to this server." run_id
  | Some _ -> (
    let path = Filename.concat (run_dir deps run_id) "events.ndjson" in
    if not (Sys.file_exists path) then Ok []
    else
      let parse line =
        match Yojson.Safe.from_string line with
        | exception _ -> None
        | j -> (
          match (member "seq" j, jstr (member "ts" j)) with
          | `Int seq, Some ts when seq > since ->
            Some
              {
                Api.seq;
                ts;
                run_id;
                execution =
                  (match member "execution" j with `Int e -> e | _ -> 1);
                body = member "body" j;
              }
          | _ -> None)
      in
      Util.read_file path |> Util.split_on ~sep:'\n'
      |> List.filter_map (fun l -> if Util.trim l = "" then None else parse l)
      |> Result.ok)

let cancel deps (auth0 : Api.auth) ~run_id =
  let* auth = effective_auth deps auth0 in
  match meta_of deps run_id with
  | None -> err Api.Not_found "No run `%s` is known to this server." run_id
  | Some m ->
    if auth.Api.role <> Api.Admin && m.requested_by <> auth.Api.login then
      err Api.Forbidden
        "Run `%s` belongs to @%s; only its owner or an admin may cancel it."
        run_id m.requested_by
    else if m.state <> Api.Queued then
      err Api.Bad_command
        "Run `%s` is %s; only queued runs can be cancelled in this build \
         (nothing executes yet)."
        run_id
        (Api.string_of_run_state m.state)
    else begin
      save_meta deps
        { m with state = Api.Cancelled; finished_at = Some (iso_now ()) };
      stamp deps run_id "cancelled";
      Ok ()
    end

let list deps (auth0 : Api.auth) (filter : Api.filter) (page : Api.page) =
  let* _auth = effective_auth deps auth0 in
  let keep (m : Api.meta) =
    let opt f = function None -> true | Some v -> f v in
    opt (fun p -> m.pr_url = Some p) filter.Api.pr
    && opt (fun r -> m.requested_by = r) filter.Api.requester
    && opt (fun s -> m.state = s) filter.Api.state
    && opt (fun mach -> m.machine = mach) filter.Api.machine
    && opt (fun f -> m.family = f) filter.Api.family
  in
  let metas = List.filter keep (all_metas deps) in
  let rec drop_until_after = function
    | [] -> []
    | (m : Api.meta) :: rest ->
      if Some m.run_id = page.Api.after then rest else drop_until_after rest
  in
  let metas =
    match page.Api.after with None -> metas | Some _ -> drop_until_after metas
  in
  let rec take n = function
    | [] -> []
    | x :: rest -> if n <= 0 then [] else x :: take (n - 1) rest
  in
  Ok (take page.Api.limit metas)

let help deps () = render_help deps
let vocab deps () = build_vocab deps

let machines deps (auth0 : Api.auth) =
  let* auth = effective_auth deps auth0 in
  let* () = require_admin auth in
  let drained = drained_machines deps in
  Ok
    (List.map
       (fun name ->
         {
           Api.machine = name;
           drained = List.mem name drained;
           busy_with = None (* no executions yet *);
         })
       (Service_config.machine_names deps.service))

let set_drain deps (auth0 : Api.auth) ~machine ~drained:want =
  let* auth = effective_auth deps auth0 in
  let* () = require_admin auth in
  if not (List.mem machine (Service_config.machine_names deps.service)) then
    err Api.Unknown_machine "Unknown machine `%s`." machine
  else begin
    let now = drained_machines deps in
    let next =
      if want then if List.mem machine now then now else machine :: now
      else List.filter (( <> ) machine) now
    in
    set_drained deps next;
    Ok ()
  end

let drain deps auth ~machine = set_drain deps auth ~machine ~drained:true
let undrain deps auth ~machine = set_drain deps auth ~machine ~drained:false

let requeue deps (auth0 : Api.auth) ~run_id =
  let* auth = effective_auth deps auth0 in
  let* () = require_admin auth in
  match meta_of deps run_id with
  | None -> err Api.Not_found "No run `%s` is known to this server." run_id
  | Some _ ->
    err Api.Bad_command
      "Nothing to requeue: no execution has ever run `%s` (no agent is \
       connected in this build)."
      run_id

let evict deps (auth0 : Api.auth) ~machine (_ : Api.cache_selector) =
  let* auth = effective_auth deps auth0 in
  let* () = require_admin auth in
  err Api.Bad_command
    "No agent is connected to `%s` yet; there are no caches to evict." machine

(* The whole thing as the document's module, proving the signature is
   implementable as specified. *)
let request_api deps : (module Api.REQUEST_API) =
  (module struct
    let submit a s = submit deps a s
    let status a ~run_id = status deps a ~run_id
    let events a ~run_id ~since = events deps a ~run_id ~since
    let cancel a ~run_id = cancel deps a ~run_id
    let list a f p = list deps a f p
    let help () = help deps ()
    let vocab () = vocab deps ()
    let machines a = machines deps a
    let drain a ~machine = drain deps a ~machine
    let undrain a ~machine = undrain deps a ~machine
    let requeue a ~run_id = requeue deps a ~run_id
    let evict a ~machine sel = evict deps a ~machine sel
  end)
