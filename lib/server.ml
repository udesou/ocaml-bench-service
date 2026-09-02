(* The request server: the first real implementation of API A.

   This is the §5.2 signature over the existing pipeline (grammar -> authz ->
   validation -> config -> run spec), with a FILE-BACKED QUEUE: every accepted
   run becomes a directory under <state>/runs/<run_id>/ holding meta.json (the
   §8 index record), request.json (the audit record), runspec.json and the
   generated config.  The EXECUTION side (§6.2, the bottom of this file)
   drains it: the agent claims a run, heartbeats under a lease, streams
   events, uploads artifacts into the same directory (the v1 store bundle)
   and finishes it.

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
   * `evict` refuses honestly: caches are REPORTED (report_caches), but how
     an eviction order reaches a machine the server never connects to is a
     question raised on the document, not decided here.

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
  sources : Runspec.source list;
      (** per-run source snapshots, derived from the pins at startup *)
  pin_config : (Api.component * string * string) list;
      (** component -> (local checkout dir, tracked ref); what seed and
          bare-bump resolve against *)
  service_version : string;  (** the server's own build, for `versions` *)
  validate_pin : Api.component -> commit:string -> (unit, string) result;
      (** dry-run a candidate pin before adoption (e.g. running-ng: extract
          and load facts); injectable, noop in tests *)
  on_bump : unit -> unit;
      (** the daemon's adoption hook (re-exec); noop in tests *)
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

let iso_of_epoch epoch =
  let t = Unix.gmtime epoch in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.Unix.tm_year + 1900)
    (t.Unix.tm_mon + 1) t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min
    t.Unix.tm_sec

let iso_now () = iso_of_epoch (Unix.gettimeofday ())

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

(* The webview's data: one snapshot of every meta record, rewritten on every
   state change (the §10/Q6 model: a static page polls this file -- with a
   capnp-only wire, files over HTTP are the browser's read path, not API A). *)
let refresh_index deps =
  let dir = Filename.concat deps.state_dir "webview" in
  mkdir_p dir;
  write_json
    (Filename.concat dir "runs.json")
    (`Assoc
      [
        ("generated_at", `String (iso_now ()));
        ("runs", `List (List.map Api.json_of_meta (all_metas deps)));
      ])

let save_meta deps (m : Api.meta) =
  write_json (Filename.concat (run_dir deps m.run_id) "meta.json")
    (Api.json_of_meta m);
  refresh_index deps

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

(* --- version pins (§6.3): the server's control file ------------------------- *)

let pins_file ~state_dir = Filename.concat state_dir "pins.json"

let read_pins_at ~state_dir =
  match read_json (pins_file ~state_dir) with
  | Some j -> (
    match member "pins" j with
    | `List l ->
      List.filter_map (fun p -> Result.to_option (Api.pin_of_json p)) l
    | _ -> [])
  | None -> []

let write_pins_at ~state_dir pins =
  mkdir_p state_dir;
  write_json (pins_file ~state_dir)
    (`Assoc [ ("pins", `List (List.map Api.json_of_pin pins)) ])

let read_pins deps = read_pins_at ~state_dir:deps.state_dir
let write_pins deps pins = write_pins_at ~state_dir:deps.state_dir pins

let looks_like_version v =
  let v =
    if String.length v > 0 && (v.[0] = 'v' || v.[0] = 'V') then
      String.sub v 1 (String.length v - 1)
    else v
  in
  match Util.split_on ~sep:'.' v with
  | x :: y :: _ -> Util.is_int x && Util.is_int y
  | _ -> false

(* The declared X.Y.Z of a pinned commit: a VERSION file when the component
   ships one (the dashboard), else the target when it names a version tag. *)
let pin_version ~dir ~commit ~target =
  match
    Resolver.git_run ~git:"git" [ "-C"; dir; "show"; commit ^ ":VERSION" ]
  with
  | Ok v when String.trim v <> "" -> Some (String.trim v)
  | _ -> if looks_like_version target then Some target else None

(* Seed pins.json on first start from the configured checkouts; afterwards
   pins change only through `bump` -- a restart never silently re-pins. *)
let init_pins ~state_dir ~pin_config =
  match read_pins_at ~state_dir with
  | _ :: _ as pins -> pins
  | [] ->
    let now = iso_now () in
    let pins =
      List.filter_map
        (fun (component, dir, track) ->
          match
            Resolver.git_run ~git:"git" [ "-C"; dir; "rev-parse"; track ]
          with
          | Error out ->
            Printf.eprintf "pins: skipping %s (%s: %s)\n%!"
              (Api.string_of_component component)
              dir out;
            None
          | Ok commit ->
            Some
              {
                Api.pinned_component = component;
                track;
                commit;
                version = pin_version ~dir ~commit ~target:track;
                bumped_at = now;
                bumped_by = "seed";
              })
        pin_config
    in
    write_pins_at ~state_dir pins;
    pins

(* --- execution state (§6.2): the server's record of one attempt ------------- *)

(* execution.json in the run directory, server-owned like meta.json.  One
   record per run, overwritten when a requeue starts the next attempt. *)
type exec_state = {
  execution : int;
  exec_machine : string;
  claimed_at : string;
  claimed_at_epoch : float;  (* duration arithmetic without an ISO parser *)
  last_heartbeat_epoch : float;
  phase : Api.execution_phase;
  cancel_requested : bool;
}

let execution_file deps run_id =
  Filename.concat (run_dir deps run_id) "execution.json"

(* An agent that stops heartbeating for this long is presumed dead; its run
   becomes claimable again (the next claim increments `execution`).  Generous
   because a machine mid-compiler-build is busy, not dead. *)
let lease_seconds = 15. *. 60.

let read_exec deps run_id =
  match read_json (execution_file deps run_id) with
  | None -> None
  | Some j -> (
    match (member "execution" j, jstr (member "machine" j)) with
    | `Int execution, Some exec_machine ->
      let f k = match member k j with `Float x -> x | `Int i -> float_of_int i | _ -> 0. in
      Some
        {
          execution;
          exec_machine;
          claimed_at = Option.value (jstr (member "claimed_at" j)) ~default:"";
          claimed_at_epoch = f "claimed_at_epoch";
          last_heartbeat_epoch = f "last_heartbeat_epoch";
          phase =
            Option.value
              (Option.bind
                 (jstr (member "phase" j))
                 Api.execution_phase_of_string)
              ~default:Api.Preparing;
          cancel_requested =
            (match member "cancel_requested" j with `Bool b -> b | _ -> false);
        }
    | _ -> None)

let write_exec deps run_id (e : exec_state) =
  write_json (execution_file deps run_id)
    (`Assoc
      [
        ("execution", `Int e.execution);
        ("machine", `String e.exec_machine);
        ("claimed_at", `String e.claimed_at);
        ("claimed_at_epoch", `Float e.claimed_at_epoch);
        ("last_heartbeat_epoch", `Float e.last_heartbeat_epoch);
        ("phase", `String (Api.string_of_execution_phase e.phase));
        ("cancel_requested", `Bool e.cancel_requested);
      ])

let lease_expired (e : exec_state) =
  Unix.gettimeofday () -. e.last_heartbeat_epoch > lease_seconds

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
  (* both land on the per-run page (§10): live status while the run is
     active, results and the dashboard link once it is done *)
  let page = Printf.sprintf "%s/run.html#%s" deps.base_url run_id in
  { Api.status = page; webview = page }

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

let pin_of_variant ~default_repo (v : Variant.t) =
  {
    Api.name = Variant.runtime_name v;
    commit =
      (match v.Variant.spec with
      | Variant.Commit sha -> sha
      (* Offline placeholder: the GitHub resolver pins the release tag's sha
         here.  Until then the version string is the truthful pin value. *)
      | Variant.Version ver -> ver);
    repo = Option.value v.Variant.repo ~default:default_repo;
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
    ~flavors:deps.service.Service_config.flavors

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
  add "- selection: %s -- %d programs × %d configs × %d invocations\n"
    (String.concat ", " (List.map Tag_alias.friendly spec.Gen.tags))
    spec.Gen.cost.Cost.programs spec.Gen.cost.Cost.configs
    spec.Gen.cost.Cost.invocations;
  add "- machine: `%s` · estimate: %s\n" machine
    (Cost.human spec.Gen.cost.Cost.seconds);
  add "- [status](%s) · [results when done](%s)\n" l.Api.status l.Api.webview;
  List.iter (fun w -> add "\n> %s" w) spec.Gen.warnings;
  Buffer.contents b

(* The completion notice, rendered HERE (the server renders, requesters post
   verbatim -- the same rule as every other message) and parked in the bundle
   as completion.md.  The bot posts it once to the run's PR and leaves a
   completion.posted marker; CLI runs just keep the file as a record. *)
(* report.md: rendered from the bundle's contract at finish (policy and
   verdict gates in lib/report.ml).  Defensive at every step: a rendering
   problem must never lose a finish. *)
let render_report deps (m : Api.meta) =
  match m.Api.baseline with
  | None -> None
  | Some b -> (
    let file f =
      match Util.read_file (Filename.concat (run_dir deps m.Api.run_id) f) with
      | s -> Some s
      | exception _ -> None
    in
    match
      Option.bind (file "contract/manifest.json") (fun s ->
          match Yojson.Safe.from_string s with
          | j -> Some j
          | exception _ -> None)
    with
    | None -> None
    | Some manifest -> (
      try
        Report.render ~thresholds:deps.service.Service_config.report ~manifest
          ~olly:(file "contract/measurements/olly.ndjson")
          ~perf:(file "contract/measurements/perf.ndjson")
          ~baseline:b.Api.name
          ~candidates:
            (List.map (fun (c : Api.runtime_pin) -> c.Api.name) m.Api.candidates)
          ()
      with _ -> None))

let write_completion deps (m : Api.meta) ~detail ~report =
  let l = links deps m.Api.run_id in
  let b = Buffer.create 256 in
  let add fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  add "**Benchmark run `%s` %s**" m.Api.run_id
    (match m.Api.state with
    | Api.Done -> "finished"
    | Api.Failed -> "FAILED"
    | Api.Timed_out -> "timed out"
    | Api.Cancelled -> "was cancelled"
    | other -> Api.string_of_run_state other (* not terminal: never rendered *));
  (match m.Api.duration_seconds with
  | Some s -> add " after %s" (Cost.human (float_of_int s))
  | None -> ());
  add " on `%s`.\n\n" m.Api.machine;
  if m.Api.state = Api.Done then
    add "- cells: %d passed%s\n" m.Api.cells_passed
      (if m.Api.cells_failed > 0 then
         Printf.sprintf ", %d failed" m.Api.cells_failed
       else "");
  (match detail with
  | Some d when m.Api.state <> Api.Done -> add "\n> %s\n" (Util.trim d)
  | _ -> ());
  (* the report rides along VERBATIM (agreed 2026-08-31): no separate summary
     vocabulary, the tables are the summary *)
  (match report with
  | Some body when String.length body <= 6000 -> add "\n%s" body
  | Some _ ->
    add "\nThe result table is too large for a comment; it is in the report \
         behind the results link.\n"
  | None -> ());
  add "\n[Results](%s) -- measurements, dashboard, logs.\n" l.Api.webview;
  Util.write_file
    (Filename.concat (run_dir deps m.Api.run_id) "completion.md")
    (Buffer.contents b)

(* --- the API A functions ---------------------------------------------------- *)

(* Post-auth cancellation, shared by the cancel operation and `/bench cancel`
   arriving through submit (Q18).  A queued run dies here; a RUNNING run is
   only signalled -- the machine is unreachable from the server (Q1), so the
   cancel order travels as the reply to the agent's next heartbeat, and the
   state stays Running until the agent confirms via finish. *)
let cancel_run deps (auth : Api.auth) ~run_id =
  match meta_of deps run_id with
  | None -> err Api.Not_found "No run `%s` is known to this server." run_id
  | Some m ->
    if auth.Api.role <> Api.Admin && m.requested_by <> auth.Api.login then
      err Api.Forbidden
        "Run `%s` belongs to @%s; only its owner or an admin may cancel it."
        run_id m.requested_by
    else begin
      match m.state with
      | Api.Queued ->
        save_meta deps
          { m with state = Api.Cancelled; finished_at = Some (iso_now ()) };
        stamp deps run_id "cancelled";
        Ok `Cancelled
      | Api.Running -> (
        match read_exec deps run_id with
        | Some e ->
          if not e.cancel_requested then begin
            write_exec deps run_id { e with cancel_requested = true };
            stamp deps run_id "cancel_requested"
          end;
          Ok `Signalled
        | None ->
          (* Running without an execution record is a broken row; close it. *)
          save_meta deps
            { m with state = Api.Cancelled; finished_at = Some (iso_now ()) };
          stamp deps run_id "cancelled";
          Ok `Cancelled)
      | other ->
        err Api.Bad_command
          "Run `%s` is already %s; only queued or running runs can be \
           cancelled."
          run_id
          (Api.string_of_run_state other)
    end

let submit deps (auth0 : Api.auth) (s : Api.submit) =
  let* auth = effective_auth deps auth0 in
  let* request =
    match Request.parse s.Api.command with
    | Ok r -> Ok r
    | Error e -> Error { Api.code = Api.Bad_command; error_markdown = e }
  in
  match request.Request.action with
  (* Non-run commands are answers, not runs (Q18): the server acts and the
     requester posts the markdown verbatim -- it cannot pre-parse and route
     these itself, because the grammar lives here (Q13). *)
  | Request.Help -> Ok (Api.Answered { markdown = render_help deps })
  | Request.Cancel id ->
    let* how = cancel_run deps auth ~run_id:id in
    Ok
      (Api.Answered
         {
           markdown =
             (match how with
             | `Cancelled -> Printf.sprintf "Cancelled `%s`." id
             | `Signalled ->
               Printf.sprintf
                 "Cancellation signalled for `%s` (it is running); the agent \
                  aborts it at its next heartbeat."
                 id);
         })
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
    let default_repo = deps.service.Service_config.compiler_repo in
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
        (* The bridge failing is OUR fault (a running-ng drift, a broken
           helper), never the command's: the raw tool output goes to the
           server log, the user gets the incident id. *)
        | Error detail ->
          Api.internal
            ~detail:("tag filter failed for " ^ Util.trim request.Request.raw
                     ^ ": " ^ detail)
            "The service failed while resolving the benchmark selection."
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
          (* the SERVER validates against its real tree (deps.base_include),
             but the config it ships is machine-independent: the agent
             substitutes its own checkout for the placeholder (§6.1) *)
          base_include = Runspec.base_include_placeholder;
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
      (* persist the run: this directory IS the queue row.  The spec carries
         no machine-side detail (§6.1: paths, env and invocation are the
         agent's); which SLOT executes it is the claim's concern (§6.2). *)
      let dir = run_dir deps run_id in
      mkdir_p dir;
      Util.write_file
        (Filename.concat dir "runspec.json")
        (Runspec.to_string ~ctx ~request ~spec ~variants ~sources:deps.sources
           ~run_key:None);
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
            (* claim-time inputs (§6.2): rerun becomes the assignment's
               cache-bypass flag; the estimate feeds the timeout formula *)
            ( "action",
              `String
                (match request.Request.action with
                | Request.Rerun -> "rerun"
                | _ -> "run") );
            ("estimate_seconds", `Int (int_of_float spec.Gen.cost.Cost.seconds));
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
          baseline = Some (pin_of_variant ~default_repo baseline);
          candidates = List.map (pin_of_variant ~default_repo) candidates;
          queued_at = now;
          started_at = None;
          finished_at = None;
          duration_seconds = None;
          cells_passed = 0;
          cells_failed = 0;
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
          Api.baseline = pin_of_variant ~default_repo baseline;
          candidates = List.map (pin_of_variant ~default_repo) candidates;
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
    let progress =
      match (m.state, read_exec deps run_id) with
      | Api.Running, Some e ->
        Some
          {
            Api.phase = e.phase;
            execution = e.execution;
            (* benchmark-level counts arrive with the §7 progress plugin;
               until then the phase and attempt number are what is known *)
            benchmarks_done = 0;
            benchmarks_total = 0;
            current = None;
          }
      | _ -> None
    in
    Ok
      {
        Api.run_id = m.run_id;
        state = m.state;
        progress;
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
  let* (_ : [ `Cancelled | `Signalled ]) = cancel_run deps auth ~run_id in
  Ok ()

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
  let running = List.filter (fun (m : Api.meta) -> m.state = Api.Running) (all_metas deps) in
  Ok
    (List.map
       (fun name ->
         {
           Api.machine = name;
           drained = List.mem name drained;
           busy_with =
             Option.map
               (fun (m : Api.meta) -> m.run_id)
               (List.find_opt (fun (m : Api.meta) -> m.machine = name) running);
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

(* Put a terminal run back on the queue: the run keeps its identity and its
   spec (the pins it snapshotted), and the next claim starts execution N+1.
   An active run is not requeueable -- cancel it first. *)
let requeue deps (auth0 : Api.auth) ~run_id =
  let* auth = effective_auth deps auth0 in
  let* () = require_admin auth in
  match meta_of deps run_id with
  | None -> err Api.Not_found "No run `%s` is known to this server." run_id
  | Some m -> (
    match m.state with
    | Api.Queued | Api.Running | Api.Publishing ->
      err Api.Bad_command
        "Run `%s` is %s -- only finished runs can be requeued (cancel it \
         first if it is stuck)."
        run_id
        (Api.string_of_run_state m.state)
    | Api.Done | Api.Failed | Api.Timed_out | Api.Cancelled ->
      save_meta deps
        {
          m with
          state = Api.Queued;
          finished_at = None;
          duration_seconds = None;
          cells_passed = 0;
          cells_failed = 0;
          summary = None;
        };
      (* a fresh cycle gets a fresh completion notice (and post) *)
      List.iter
        (fun f ->
          try Sys.remove (Filename.concat (run_dir deps run_id) f)
          with Sys_error _ -> ())
        [ "completion.md"; "completion.posted" ];
      stamp deps run_id "requeued";
      Ok ())

let machines_dir deps = Filename.concat deps.state_dir "machines"

let machine_caches_file deps machine =
  Filename.concat (machines_dir deps) (machine ^ "-caches.json")

let reported_caches deps machine =
  match read_json (machine_caches_file deps machine) with
  | None -> None
  | Some j -> (
    match member "caches" j with
    | `List l ->
      Some
        ( Option.value (jstr (member "reported_at" j)) ~default:"never",
          List.filter_map
            (fun c -> Result.to_option (Api.cache_entry_of_json c))
            l )
    | _ -> None)

let evict deps (auth0 : Api.auth) ~machine (_ : Api.cache_selector) =
  let* auth = effective_auth deps auth0 in
  let* () = require_admin auth in
  match reported_caches deps machine with
  | None ->
    err Api.Bad_command
      "No agent has reported caches for `%s` yet; there is nothing to evict."
      machine
  | Some (reported_at, entries) ->
    (* Visibility exists (report_caches); the DELIVERY of an eviction order to
       a machine the server cannot connect to is not designed yet -- raised on
       the document rather than invented here. *)
    err Api.Bad_command
      "Eviction is not wired to the agent yet. `%s` last reported %d cache \
       entr%s at %s."
      machine (List.length entries)
      (if List.length entries = 1 then "y" else "ies")
      reported_at

let versions deps (auth0 : Api.auth) =
  let* auth = effective_auth deps auth0 in
  let* () = require_admin auth in
  Ok
    {
      Api.service = deps.service_version;
      pins = read_pins deps;
      machines = [] (* agent-reported, once agents exist *);
    }

(* Adopt a new version of a component (§6.3): validate before adopting, write
   pins.json, fire the daemon's adoption hook.  Queued specs are untouched by
   construction -- they snapshotted the pins at submission. *)
let bump deps (auth0 : Api.auth) ~component ?to_ () =
  let* auth = effective_auth deps auth0 in
  let* () = require_admin auth in
  match
    List.find_opt (fun (c, _, _) -> c = component) deps.pin_config
  with
  | None ->
    err Api.Bad_command
      "This server has no checkout configured for `%s`, so it cannot be        bumped here."
      (Api.string_of_component component)
  | Some (_, dir, track) -> (
    let target = Option.value to_ ~default:track in
    (* fetch first so adopting upstream movement is one command; best effort
       (a purely local target still resolves) *)
    ignore
      (Resolver.git_run ~git:"git" [ "-C"; dir; "fetch"; "--quiet"; "origin" ]);
    match
      Resolver.git_run ~git:"git"
        [ "-C"; dir; "rev-parse"; target ^ "^{commit}" ]
    with
    | Error out ->
      err Api.Bad_command
        "`%s` does not resolve in the server's `%s` checkout: %s" target
        (Api.string_of_component component)
        out
    | Ok commit -> (
      match deps.validate_pin component ~commit with
      | Error why ->
        err Api.Bad_command
          "Refusing to bump `%s` to `%s`: %s. Nothing was changed."
          (Api.string_of_component component)
          target why
      | Ok () ->
        let pin =
          {
            Api.pinned_component = component;
            track;
            commit;
            version = pin_version ~dir ~commit ~target;
            bumped_at = iso_now ();
            bumped_by = auth.Api.login;
          }
        in
        let others =
          List.filter
            (fun (p : Api.pin) -> p.Api.pinned_component <> component)
            (read_pins deps)
        in
        write_pins deps (others @ [ pin ]);
        deps.on_bump ();
        Ok pin))

(* --- API B: the execution side (§6.2) --------------------------------------- *)
(* Called BY the agent (§6.4: the agent dials out; the server never connects
   to a machine).  ~machine is the transport-proven identity -- the agent
   capability is bound to one machine exactly as a user capability is bound
   to one login.  No roles here: an agent capability can only do agent
   things, and only for its own machine's runs. *)

(* The guard on every per-execution call: the run exists, the execution
   record matches the caller's id, and the caller is the machine it was
   assigned to.  A mismatch means the lease moved on (the server presumed the
   agent dead and reassigned) -- the stale agent must stop, not write. *)
let own_execution deps ~machine (id : Api.execution_id) =
  match meta_of deps id.Api.run_id with
  | None ->
    err Api.Not_found "No run `%s` is known to this server." id.Api.run_id
  | Some m -> (
    match read_exec deps id.Api.run_id with
    | None ->
      err Api.Not_found "Run `%s` has no execution on record." id.Api.run_id
    | Some e ->
      if e.exec_machine <> machine || e.execution <> id.Api.execution then
        err Api.Forbidden
          "Execution %d of `%s` is not this agent's (the lease moved on)."
          id.Api.execution id.Api.run_id
      else Ok (m, e))

(* Hand out one assignment: everything the agent needs travels now, because
   the server cannot be asked follow-ups by a machine it never connects to. *)
let assign deps ~machine (m : Api.meta) =
  let run_id = m.Api.run_id in
  match read_json (Filename.concat (run_dir deps run_id) "runspec.json") with
  | None ->
    Api.internal
      ~detail:("claim: missing runspec.json for " ^ run_id)
      "The service lost the run spec for `%s`." run_id
  | Some spec ->
    let req = request_json_of deps run_id in
    let field k = Option.bind req (fun j -> jstr (member k j)) in
    let caches = if field "action" = Some "rerun" then `Bypass else `Reuse in
    let estimate =
      match Option.map (member "estimate_seconds") req with
      | Some (`Int s) -> s
      | _ -> 0 (* pre-agent rows: the timeout floor covers them *)
    in
    let execution =
      match read_exec deps run_id with Some e -> e.execution + 1 | None -> 1
    in
    let now_epoch = Unix.gettimeofday () in
    let now = iso_of_epoch now_epoch in
    write_exec deps run_id
      {
        execution;
        exec_machine = machine;
        claimed_at = now;
        claimed_at_epoch = now_epoch;
        last_heartbeat_epoch = now_epoch;
        phase = Api.Preparing;
        cancel_requested = false;
      };
    save_meta deps
      {
        m with
        state = Api.Running;
        started_at =
          (match m.Api.started_at with Some _ as s -> s | None -> Some now);
      };
    stamp deps run_id
      (if execution = 1 then "started"
       else Printf.sprintf "started_execution_%d" execution);
    Ok
      (Some
         {
           Api.id = { Api.run_id; execution };
           spec;
           caches;
           timeout_seconds = Runspec.timeout_of_estimate ~seconds:estimate;
         })

let claim deps ~machine =
  if not (List.mem machine (Service_config.machine_names deps.service)) then
    err Api.Unknown_machine
      "This server has no machine `%s` registered." machine
  else if List.mem machine (drained_machines deps) then
    Ok None (* drained = no NEW work; a run already claimed finishes *)
  else begin
    let metas = List.rev (all_metas deps) (* oldest first *) in
    let mine (m : Api.meta) = m.Api.machine = machine in
    let running =
      List.filter (fun m -> mine m && m.Api.state = Api.Running) metas
    in
    let live_lease =
      List.exists
        (fun (m : Api.meta) ->
          match read_exec deps m.Api.run_id with
          | Some e -> not (lease_expired e)
          | None -> false)
        running
    in
    if live_lease then Ok None (* one slot per machine: it is taken *)
    else begin
      (* dead leases: a cancel-requested run closes (the agent died before it
         could abort); anything else becomes claimable as the next attempt *)
      let reclaimable =
        List.filter
          (fun (m : Api.meta) ->
            match read_exec deps m.Api.run_id with
            | Some e when e.cancel_requested ->
              let m =
                {
                  m with
                  Api.state = Api.Cancelled;
                  finished_at = Some (iso_now ());
                }
              in
              save_meta deps m;
              stamp deps m.Api.run_id "cancelled";
              write_completion deps m ~report:None
                ~detail:
                  (Some
                     "the agent stopped responding while the cancellation \
                      was pending");
              false
            | _ -> true)
          running
      in
      let queued =
        List.filter (fun m -> mine m && m.Api.state = Api.Queued) metas
      in
      let priority (m : Api.meta) =
        match request_json_of deps m.Api.run_id with
        | Some j -> jstr (member "priority" j) = Some "top"
        | None -> false
      in
      let queued =
        List.filter priority queued
        @ List.filter (fun m -> not (priority m)) queued
      in
      match reclaimable @ queued with
      | [] -> Ok None
      | m :: _ -> assign deps ~machine m
    end
  end

let heartbeat deps ~machine (id : Api.execution_id) phase =
  match meta_of deps id.Api.run_id with
  | None ->
    err Api.Not_found "No run `%s` is known to this server." id.Api.run_id
  | Some m -> (
    match read_exec deps id.Api.run_id with
    | None -> Ok `Cancel
    | Some e ->
      (* a superseded or finalized execution is told to stop, not errored:
         `Cancel` is the one reply a stale agent always knows how to obey *)
      if
        e.exec_machine <> machine
        || e.execution <> id.Api.execution
        || m.Api.state <> Api.Running
      then Ok `Cancel
      else begin
        write_exec deps id.Api.run_id
          { e with last_heartbeat_epoch = Unix.gettimeofday (); phase };
        Ok (if e.cancel_requested then `Cancel else `Continue)
      end)

let post_events deps ~machine (id : Api.execution_id) events =
  let* _m, e = own_execution deps ~machine id in
  let path = Filename.concat (run_dir deps id.Api.run_id) "events.ndjson" in
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  List.iter
    (fun (ev : Api.event) ->
      (* run_id and execution are the AUTHENTICATED ones, never the payload's:
         a compromised bench machine must not write into another run's stream *)
      let ev =
        { ev with Api.run_id = id.Api.run_id; execution = id.Api.execution }
      in
      output_string oc (Yojson.Safe.to_string (Api.json_of_event ev) ^ "\n"))
    events;
  close_out oc;
  (* events are signs of life; count them toward the lease *)
  write_exec deps id.Api.run_id
    { e with last_heartbeat_epoch = Unix.gettimeofday () };
  Ok ()

(* Files the SERVER writes in a run directory; an upload may never name one. *)
let server_owned =
  [
    "meta.json"; "request.json"; "runspec.json"; "config.yml";
    "execution.json"; "events.ndjson"; "completion.md"; "completion.posted";
    "report.md" (* rendered by the server at finish, not uploaded *);
  ]

let safe_rel_path p =
  p <> ""
  && Filename.is_relative p
  && List.for_all
       (fun seg -> seg <> "" && seg <> "." && seg <> "..")
       (String.split_on_char '/' p)

let upload deps ~machine (id : Api.execution_id) (a : Api.artifact) =
  let* _ = own_execution deps ~machine id in
  if not (safe_rel_path a.Api.path) then
    err Api.Bad_command "Artifact path `%s` is not a clean relative path."
      a.Api.path
  else if List.mem a.Api.path server_owned then
    err Api.Forbidden "`%s` is server-owned; an agent cannot write it."
      a.Api.path
  else begin
    (* v1 store: the run directory IS the bundle (§8's layout), so landing
       artifacts beside meta.json is the store write, and finish's Ok is the
       confirmation after which the agent may delete its local run dir *)
    let dst = Filename.concat (run_dir deps id.Api.run_id) a.Api.path in
    mkdir_p (Filename.dirname dst);
    Util.write_file dst a.Api.content;
    Ok ()
  end

let finish deps ~machine (id : Api.execution_id) (r : Api.execution_result) =
  let* m, e = own_execution deps ~machine id in
  if m.Api.state <> Api.Running then
    err Api.Bad_command "Run `%s` is %s, not running." id.Api.run_id
      (Api.string_of_run_state m.Api.state)
  else begin
    let state =
      match r.Api.outcome with
      | `Done -> Api.Done
      | `Failed -> Api.Failed
      | `Timed_out -> Api.Timed_out
      | `Aborted -> Api.Cancelled
    in
    let now_epoch = Unix.gettimeofday () in
    let m =
      {
        m with
        Api.state;
        finished_at = Some (iso_of_epoch now_epoch);
        duration_seconds = Some (int_of_float (now_epoch -. e.claimed_at_epoch));
        cells_passed = r.Api.cells_passed;
        cells_failed = r.Api.cells_failed;
      }
    in
    save_meta deps m;
    stamp deps id.Api.run_id (Api.string_of_run_state state);
    (* the report: from whatever contract exists -- failed and timed-out runs
       included, the contract degrades gracefully (§4) *)
    let report = render_report deps m in
    (match report with
    | Some body ->
      Util.write_file
        (Filename.concat (run_dir deps id.Api.run_id) "report.md")
        (Printf.sprintf "# %s\n\n%s" id.Api.run_id body)
    | None -> ());
    write_completion deps m ~detail:r.Api.detail ~report;
    Ok ()
  end

let report_caches deps ~machine entries =
  if not (List.mem machine (Service_config.machine_names deps.service)) then
    err Api.Unknown_machine
      "This server has no machine `%s` registered." machine
  else begin
    mkdir_p (machines_dir deps);
    write_json
      (machine_caches_file deps machine)
      (`Assoc
        [
          ("reported_at", `String (iso_now ()));
          ("caches", `List (List.map Api.json_of_cache_entry entries));
        ]);
    Ok ()
  end

(* One machine's view of the service, the §6.2 module. *)
let execution_api deps ~machine : (module Api.EXECUTION_API) =
  (module struct
    let claim () = claim deps ~machine
    let heartbeat id phase = heartbeat deps ~machine id phase
    let post_events id events = post_events deps ~machine id events
    let upload id a = upload deps ~machine id a
    let finish id r = finish deps ~machine id r
    let report_caches entries = report_caches deps ~machine entries
  end)

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
    let versions a = versions deps a
    let machines a = machines deps a
    let drain a ~machine = drain deps a ~machine
    let undrain a ~machine = undrain deps a ~machine
    let requeue a ~run_id = requeue deps a ~run_id
    let evict a ~machine sel = evict deps a ~machine sel
    let bump a ~component ?to_ () = bump deps a ~component ?to_ ()
  end)
