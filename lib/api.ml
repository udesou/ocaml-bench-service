(* API A: the Request API (architecture document, §5).

   The one public surface of the service: the PR bot and the CLI are thin
   clients of it, and any future requester (web form, scheduler) implements
   nothing else.  This module is the OCaml module signature the document
   specifies, plus the payload types and their JSON encodings; the wire
   protocol (HTTP+JSON now, capnp later, §5.6) is an adapter over it.

   Two kinds of definition live here, and the distinction matters:

   * Types the document defines in §5.2/§5.3 (including its "Referenced
     types" block) are transcribed verbatim.  Do not "improve" them here --
     a change starts in the document.
   * `meta` and `event` are owned by the document's store (§8) and progress
     (§7) sections, which are not agreed yet: PROVISIONAL, marked below. *)

(* --- identity and roles (§5.1, §5.4) ------------------------------------- *)

type role = User | Admin

(* Everything a requester proves about itself; HOW it proves it differs per
   requester kind (the bot asserts a verified commenter login, the CLI maps a
   bearer token to a login) and never reaches this layer. *)
type auth = { login : string; role : role }

(* What the requester already knows about where the command came from.  The
   bot forwards what the webhook payload carries -- the server still resolves
   the PR head and merge base itself (an issue_comment payload does not
   include the head sha, and the merge base needs a GitHub call regardless);
   anything the bot does know is passed along, both to save lookups and to
   land verbatim in the audit record (request.json). *)
type pr_context = {
  repo : string;  (** "owner/name" *)
  number : int;
  url : string;
  comment_id : string;
  comment_url : string;
  head_sha : string option;
      (** if the requester saw it; else the server resolves *)
  base_ref : string option;
      (** the PR's target branch, if the requester knows it; the merge-base
          baseline is computed against it (default: trunk) *)
}

type origin_kind = Pr_comment of pr_context | Cli (* later: Web, Schedule *)

type origin = {
  kind : origin_kind;
  id : string;  (** idempotency key component, e.g. the comment id *)
}

type submit = { command : string; origin : origin }
(* [command] is the raw string, e.g. "/bench tag=small invocations=1 vs=trunk".
   The server owns the grammar; requesters never parse. *)

(* --- the error envelope --------------------------------------------------- *)

type error_code =
  | Bad_command
  | Unauthorized
  | Forbidden
  | Over_budget
  | User_queue_full
  | Unknown_machine
  | Machine_drained
  | Not_found
  | Internal
      (** the SERVICE failed, not the request: the markdown stays generic
          and carries a short id that indexes the detail in the server log *)

type error = { code : error_code; error_markdown : string }
(* [error_markdown] is ALWAYS safe to post to a PR verbatim. *)

let error code fmt =
  Printf.ksprintf (fun error_markdown -> Error { code; error_markdown }) fmt

(* An internal failure: the DETAIL (tool output, tracebacks) goes to stderr --
   the daemon's log -- under a short id; the postable message carries only the
   id, so an operator can grep the log for exactly this incident. *)
let internal ~detail fmt =
  let id =
    "i-"
    ^ String.sub
        (Digest.to_hex
           (Digest.string (detail ^ string_of_float (Unix.gettimeofday ()))))
        0 6
  in
  Printf.eprintf "[internal %s] %s\n%!" id detail;
  Printf.ksprintf
    (fun msg ->
      Error
        {
          code = Internal;
          error_markdown =
            Printf.sprintf
              "%s This is a service fault, not a problem with your request; \
               an admin can find the details in the server log under `%s`."
              msg id;
        })
    fmt

(* --- payload types (§5.3) ------------------------------------------------- *)

type family = Macro | Micro (* Micro is reserved: refused until §12 lands *)

type runtime_pin = {
  name : string;
      (** running-ng runtime name = the compiler cache key.
          Server-constructed, injective in (sha, configure_args). *)
  commit : string;  (** resolved sha; never a ref *)
  repo : string;
      (** clone URL the sha is fetched from: a fork PR's head exists only on
          the fork.  Not part of identity -- a sha is globally unique. *)
  configure_args : string;  (** e.g. "--enable-flambda" *)
}
(* Commit-only, decided: a released baseline (vs=5.4.1) is resolved by the
   SERVER to its release-tag sha, which running-ng builds identically to
   `version:`.  lib/variant.ml keeps the `version` spelling only as an offline
   convenience for bench-gen, which cannot resolve; server-produced pins
   always carry the sha. *)

(* What the command actually meant, echoed back so the user can catch a wrong
   resolution early. *)
type resolved = {
  baseline : runtime_pin;  (** the PR's merge base by default *)
  candidates : runtime_pin list;
  family : family;
  tags : string list;  (** running-ng tags, union; e.g. ["small_run"] *)
  invocations : int;
  machine : string;
}

type links = { status : string; webview : string }

type accepted = {
  run_id : string;
  queue_position : int;
  estimate_seconds : int;
  resolved : resolved;
  links : links;
  ack_markdown : string;  (** post this verbatim *)
}

type reused = {
  run_id : string;  (** the completed run that already answers this *)
  run_key : string;  (** why it matched (§8.1) *)
  links : links;
  ack_markdown : string;
}

type submit_outcome =
  | Accepted of accepted  (** a new run was queued *)
  | Reused of reused  (** run key matched a completed run (§8.1) *)
  | Duplicate of { run_id : string; links : links }  (** idempotency key hit *)
  | Answered of { markdown : string }
      (** commands that are answers, not runs (/bench help, /bench cancel):
          the server acts and replies; requesters post the markdown verbatim.
          Exists because the grammar lives in the server (Q13): a requester
          cannot pre-parse these and route them itself (Q18) *)

type run_state =
  | Queued
  | Running
  | Publishing
  | Done
  | Failed
  | Timed_out
  | Cancelled

type execution_phase =
  | Preparing
  | Provisioning
  | Building
  | Measuring
  | Collecting
  | Aborted

type progress = {
  phase : execution_phase;
  execution : int;  (** which attempt; a requeue increments this *)
  benchmarks_done : int;
  benchmarks_total : int;
  current : (string * string * int) option;  (** suite, benchmark, invocation *)
}

type summary = { improved : int; regressed : int; unchanged : int; noisy : int }

type completion = {
  report_url : string;
  dashboard_url : string;
  summary : summary;
}

type run_status = {
  run_id : string;
  state : run_state;
  progress : progress option;  (** while Running *)
  machine : string;
  timestamps : (string * string) list;  (** state -> ISO-8601 *)
  completion : completion option;  (** once terminal *)
}

(* --- the vocabulary (§5.2) ------------------------------------------------ *)

type sweepable = {
  param : string;  (** what sweep= accepts: the OCAMLRUNPARAM letter, "o" *)
  dimension : string;  (** the contract's canonical name, "space_overhead" *)
  unit_ : string;  (** "pct", "words", ... *)
}

type machine_type = string
(* a bare name for now, deliberately: what a machine should expose to
   requesters (architecture? governor? dedicated or not?) is undecided *)

(* --- version pins (§6.3) ---------------------------------------------------- *)

(* The bumpable components: everything the server pins into specs and builds.
   The service and the agent themselves are absent on purpose -- they change
   by DEPLOYING, not bumping, and the variant makes that unrepresentable. *)
type component = Running_ng | Macro_benches | Benches | Olly | Dashboard

type pin = {
  pinned_component : component;
  track : string;  (** what a bare bump re-resolves: a ref or tag *)
  commit : string;  (** the adopted sha *)
  version : string option;  (** X.Y.Z where the component declares one *)
  bumped_at : string;
  bumped_by : string;
}

type versions = {
  service : string;  (** the server's own build; changes by deploying *)
  pins : pin list;
  machines : (string * (string * string) list) list;
      (** machine -> agent-REPORTED versions (agent build, olly checkout,
          kernel ...); empty until agents exist *)
}

let string_of_component = function
  | Running_ng -> "running-ng"
  | Macro_benches -> "macro-benches"
  | Benches -> "benches"
  | Olly -> "olly"
  | Dashboard -> "dashboard"

let component_of_string = function
  | "running-ng" -> Some Running_ng
  | "macro-benches" -> Some Macro_benches
  | "benches" -> Some Benches
  | "olly" -> Some Olly
  | "dashboard" -> Some Dashboard
  | _ -> None

type vocab = {
  machines : machine_type list;
  families : family list;  (** [Macro] today; Micro reserved *)
  tags : string list;  (** small, default, plus the feature tags *)
  sweepable : sweepable list;
  max_invocations : int;
}

(* --- referenced types (§5.3 "Referenced types") ---------------------------- *)

(* Cursor pagination, newest first. *)
type page = { limit : int; after : string option }

(* What `list` filters on; every field optional, conjunction. *)
type filter = {
  pr : string option;
  requester : string option;
  state : run_state option;
  machine : string option;
  family : family option;
}

let no_filter =
  { pr = None; requester = None; state = None; machine = None; family = None }

(* PROVISIONAL below this line: `meta` and `event` are owned by the store (§8)
   and progress (§7) sections, which are not agreed yet; API A returns them
   as-is. *)

(* The compact per-run record the webview index lists (§8 draft). *)
type meta = {
  run_id : string;
  state : run_state;
  run_key : string;
  pr_url : string option;
  requested_by : string;
  command : string;
  machine : string;
  family : family;
  baseline : runtime_pin option;
      (* §8 makes this required; option here because pre-webview rows
         lack it and the index must keep rendering them *)
  candidates : runtime_pin list;
  queued_at : string;
  started_at : string option;  (* first claim; §8 *)
  finished_at : string option;
  duration_seconds : int option;
  cells_passed : int;
  cells_failed : int;
  summary : summary option;
  links : links;
}

(* One progress record (§7 draft).  Events belong to an execution. *)
type event = {
  seq : int;  (** monotone per run *)
  ts : string;  (** ISO-8601 *)
  run_id : string;
  execution : int;
  body : Yojson.Safe.t;
      (** the §7 body variants, kept opaque until API E is agreed *)
}

type machine_status = {
  machine : string;
  drained : bool;
  busy_with : string option;  (** run_id, when a run is executing *)
}

type cache_selector = All_caches | Runtime_cache of string (* runtime name *)

(* --- API B: the run execution API (§6.2) ----------------------------------- *)
(* The §6.2 types.  Deviations from the document's spelling, both raised:
   `agent_auth` does not exist here (the capability IS the machine, the same
   collapse that removed --login from API A), and claim's `slot` argument is
   gone for the same reason -- the capability names the machine, and a machine
   is one slot (Service_config: one concurrent run because running-ng locks
   the opam root).  `artifact` and `execution_result` are referenced by the
   document without a definition: PROVISIONAL spellings below. *)

type execution_id = { run_id : string; execution : int }

(* §6.3: switch-provenance.json, the recorded build inputs of one switch.
   The runtime name cannot see the environmental inputs (dune, opam repo
   state), so reuse compares this record, never the name alone. *)
type provenance = {
  compiler_sha : string;
  configure_args : string;
  dune_version : string;
  opam_repo_commit : string;
  built_at : string;
  build_id : string;  (** fresh nonce per (re)build; binaries key on it *)
}

type cache_entry =
  (* agent-side caches only (§6.3): each class has its own key shape, hence a
     constructor each.  Checkouts are not reported: re-pinned per run, they
     cannot be stale. *)
  | Switch of {
      runtime_name : string;
      provenance : provenance;
      size_bytes : int64;
      last_used : string;
    }
  | Binaries of {
      runtime_name : string;
      benches_commit : string;
      switch_build_id : string;
      size_bytes : int64;
      last_used : string;
    }

type assignment = {
  (* an execution: the spec plus execution-scoped directives, which never
     live in the spec *)
  id : execution_id;
  spec : Yojson.Safe.t;  (** the run spec (docs/RUNSPEC.md), verbatim *)
  caches : [ `Reuse | `Bypass ];  (** Bypass when the run came from `rerun` *)
  resume : bool;
      (** `/bench continue`: re-enter the previous execution's run directory
          (running-ng --resume) so completed cells are kept and failed
          builds retried; false = a fresh run directory *)
  timeout_seconds : int;
}

type execution_outcome = [ `Done | `Failed | `Timed_out | `Aborted ]
(* Timed_out split from Failed: only the agent can tell them apart.
   `Aborted is the reply to a cancel order arriving via heartbeat. *)

type execution_result = {
  outcome : execution_outcome;
  cells_passed : int;
  cells_failed : int;
  detail : string option;  (** human-readable failure reason, for the meta *)
}

(* PROVISIONAL: one artifact = one bundle-relative file, whole.  Chunked
   upload is an additive change when a file outgrows a message. *)
type artifact = { path : string; content : string }

(* Every function is called BY the agent ON the server (§6.4: the agent dials
   out).  No auth argument: the transport binds the capability to a machine,
   exactly as API A binds one to a login. *)
module type EXECUTION_API = sig
  val claim : unit -> (assignment option, error) result
  (** "give me work for this machine"; None = nothing queued.  Claiming
      creates an execution and starts its lease. *)

  val heartbeat :
    execution_id -> execution_phase -> ([ `Continue | `Cancel ], error) result
  (** doubles as the control channel: the reply tells the agent to keep going
      or to abort -- how cancellation reaches a machine the server cannot
      connect to *)

  val post_events : execution_id -> event list -> (unit, error) result
  val upload : execution_id -> artifact -> (unit, error) result
  val finish : execution_id -> execution_result -> (unit, error) result
  val report_caches : cache_entry list -> (unit, error) result
end

(* --- the signature (§5.2) ------------------------------------------------- *)

module type REQUEST_API = sig
  val submit : auth -> submit -> (submit_outcome, error) result
  val status : auth -> run_id:string -> (run_status, error) result
  val events : auth -> run_id:string -> since:int -> (event list, error) result
  val cancel : auth -> run_id:string -> (unit, error) result (* owner or admin *)
  val list : auth -> filter -> page -> (meta list, error) result
  val help : unit -> string (* the generated /bench reference, markdown *)
  val vocab : unit -> vocab (* machines, tags, sweepable params *)

  (* admin only *)
  val versions : auth -> (versions, error) result (* what the service pins *)
  val machines : auth -> (machine_status list, error) result
  val drain : auth -> machine:string -> (unit, error) result
  val undrain : auth -> machine:string -> (unit, error) result
  val requeue : auth -> run_id:string -> (unit, error) result
  val evict : auth -> machine:string -> cache_selector -> (int64, error) result

  val bump :
    auth -> component:component -> ?to_:string -> unit -> (pin, error) result
  (* adopt a new version: bare bump re-resolves [track]; [to_] pins a
     ref/tag/sha.  Validated before adoption; queued specs are untouched
     (they snapshot pins at submission). *)
end

(* --- string forms ---------------------------------------------------------- *)

let string_of_role = function User -> "user" | Admin -> "admin"

let string_of_family = function Macro -> "macro" | Micro -> "micro"

let family_of_string = function
  | "macro" -> Some Macro
  | "micro" -> Some Micro
  | _ -> None

let string_of_error_code = function
  | Bad_command -> "bad_command"
  | Unauthorized -> "unauthorized"
  | Forbidden -> "forbidden"
  | Over_budget -> "over_budget"
  | User_queue_full -> "user_queue_full"
  | Unknown_machine -> "unknown_machine"
  | Machine_drained -> "machine_drained"
  | Not_found -> "not_found"
  | Internal -> "internal"

let string_of_run_state = function
  | Queued -> "queued"
  | Running -> "running"
  | Publishing -> "publishing"
  | Done -> "done"
  | Failed -> "failed"
  | Timed_out -> "timed_out"
  | Cancelled -> "cancelled"

let run_state_of_string = function
  | "queued" -> Some Queued
  | "running" -> Some Running
  | "publishing" -> Some Publishing
  | "done" -> Some Done
  | "failed" -> Some Failed
  | "timed_out" -> Some Timed_out
  | "cancelled" -> Some Cancelled
  | _ -> None

let string_of_execution_phase = function
  | Preparing -> "preparing"
  | Provisioning -> "provisioning"
  | Building -> "building"
  | Measuring -> "measuring"
  | Collecting -> "collecting"
  | Aborted -> "aborted"

let execution_phase_of_string = function
  | "preparing" -> Some Preparing
  | "provisioning" -> Some Provisioning
  | "building" -> Some Building
  | "measuring" -> Some Measuring
  | "collecting" -> Some Collecting
  | "aborted" -> Some Aborted
  | _ -> None

let string_of_execution_outcome = function
  | `Done -> "done"
  | `Failed -> "failed"
  | `Timed_out -> "timed_out"
  | `Aborted -> "aborted"

let execution_outcome_of_string = function
  | "done" -> Some `Done
  | "failed" -> Some `Failed
  | "timed_out" -> Some `Timed_out
  | "aborted" -> Some `Aborted
  | _ -> None

(* --- JSON encodings -------------------------------------------------------- *)

(* Hand-rolled, like the rest of the repo: the only dependency is yojson.
   Clients must ignore unknown fields (additive versioning, §5.3.1), so
   encoders may gain fields without notice; the shapes here are v1. *)

let str s = `String s
let opt_str = function None -> `Null | Some s -> `String s

let json_of_error (e : error) =
  `Assoc
    [
      ("code", str (string_of_error_code e.code));
      ("error_markdown", str e.error_markdown);
    ]

let error_code_of_string = function
  | "bad_command" -> Some Bad_command
  | "unauthorized" -> Some Unauthorized
  | "forbidden" -> Some Forbidden
  | "over_budget" -> Some Over_budget
  | "user_queue_full" -> Some User_queue_full
  | "unknown_machine" -> Some Unknown_machine
  | "machine_drained" -> Some Machine_drained
  | "not_found" -> Some Not_found
  | "internal" -> Some Internal
  | _ -> None

(* origin round-trips: it is built by a requester and decoded by the transport
   adapter on the server side. *)
let json_of_origin (o : origin) =
  let kind, pr =
    match o.kind with
    | Cli -> ("cli", `Null)
    | Pr_comment c ->
      ( "pr_comment",
        `Assoc
          [
            ("repo", str c.repo);
            ("number", `Int c.number);
            ("url", str c.url);
            ("comment_id", str c.comment_id);
            ("comment_url", str c.comment_url);
            ("head_sha", opt_str c.head_sha);
            ("base_ref", opt_str c.base_ref);
          ] )
  in
  `Assoc [ ("kind", str kind); ("id", str o.id); ("pr", pr) ]

let origin_of_json j =
  let mem k = function
    | `Assoc kvs -> (
      match List.assoc_opt k kvs with Some v -> v | None -> `Null)
    | _ -> `Null
  in
  let s j = match j with `String s -> Some s | _ -> None in
  match (s (mem "kind" j), s (mem "id" j)) with
  | Some "cli", Some id -> Ok { kind = Cli; id }
  | Some "pr_comment", Some id -> (
    let pr = mem "pr" j in
    match
      ( s (mem "repo" pr),
        mem "number" pr,
        s (mem "url" pr),
        s (mem "comment_id" pr),
        s (mem "comment_url" pr) )
    with
    | Some repo, `Int number, Some url, Some comment_id, Some comment_url ->
      Ok
        {
          kind =
            Pr_comment
              {
                repo;
                number;
                url;
                comment_id;
                comment_url;
                head_sha = s (mem "head_sha" pr);
                base_ref = s (mem "base_ref" pr);
              };
          id;
        }
    | _ -> Error "pr_comment origin is missing a required field"
  )
  | _ -> Error "origin needs a kind (cli | pr_comment) and an id"

let json_of_runtime_pin (p : runtime_pin) =
  `Assoc
    [
      ("name", str p.name);
      ("commit", str p.commit);
      ("repo", str p.repo);
      ("configure_args", str p.configure_args);
    ]

let json_of_resolved (r : resolved) =
  `Assoc
    [
      ("baseline", json_of_runtime_pin r.baseline);
      ("candidates", `List (List.map json_of_runtime_pin r.candidates));
      ("family", str (string_of_family r.family));
      ("tags", `List (List.map str r.tags));
      ("invocations", `Int r.invocations);
      ("machine", str r.machine);
    ]

let json_of_links (l : links) =
  `Assoc [ ("status", str l.status); ("webview", str l.webview) ]

let json_of_summary (s : summary) =
  `Assoc
    [
      ("improved", `Int s.improved);
      ("regressed", `Int s.regressed);
      ("unchanged", `Int s.unchanged);
      ("noisy", `Int s.noisy);
    ]

let json_of_progress (p : progress) =
  `Assoc
    [
      ("phase", str (string_of_execution_phase p.phase));
      ("execution", `Int p.execution);
      ("benchmarks_done", `Int p.benchmarks_done);
      ("benchmarks_total", `Int p.benchmarks_total);
      ( "current",
        match p.current with
        | None -> `Null
        | Some (suite, benchmark, invocation) ->
          `Assoc
            [
              ("suite", str suite);
              ("benchmark", str benchmark);
              ("invocation", `Int invocation);
            ] );
    ]

let json_of_run_status (s : run_status) =
  `Assoc
    [
      ("run_id", str s.run_id);
      ("state", str (string_of_run_state s.state));
      ( "progress",
        match s.progress with None -> `Null | Some p -> json_of_progress p );
      ("machine", str s.machine);
      ( "timestamps",
        `Assoc (List.map (fun (state, ts) -> (state, str ts)) s.timestamps) );
      ( "completion",
        match s.completion with
        | None -> `Null
        | Some c ->
          `Assoc
            [
              ("report_url", str c.report_url);
              ("dashboard_url", str c.dashboard_url);
              ("summary", json_of_summary c.summary);
            ] );
    ]

let json_of_submit_outcome = function
  | Accepted a ->
    `Assoc
      [
        ("outcome", str "accepted");
        ("run_id", str a.run_id);
        ("queue_position", `Int a.queue_position);
        ("estimate_seconds", `Int a.estimate_seconds);
        ("resolved", json_of_resolved a.resolved);
        ("links", json_of_links a.links);
        ("ack_markdown", str a.ack_markdown);
      ]
  | Reused r ->
    `Assoc
      [
        ("outcome", str "reused");
        ("run_id", str r.run_id);
        ("run_key", str r.run_key);
        ("links", json_of_links r.links);
        ("ack_markdown", str r.ack_markdown);
      ]
  | Duplicate { run_id; links } ->
    `Assoc
      [
        ("outcome", str "duplicate");
        ("run_id", str run_id);
        ("links", json_of_links links);
      ]
  | Answered { markdown } ->
    `Assoc [ ("outcome", str "answered"); ("markdown", str markdown) ]

let json_of_vocab (v : vocab) =
  `Assoc
    [
      ("machines", `List (List.map str v.machines));
      ( "families",
        `List (List.map (fun f -> str (string_of_family f)) v.families) );
      ("tags", `List (List.map str v.tags));
      ( "sweepable",
        `List
          (List.map
             (fun s ->
               `Assoc
                 [
                   ("param", str s.param);
                   ("dimension", str s.dimension);
                   ("unit", str s.unit_);
                 ])
             v.sweepable) );
      ("max_invocations", `Int v.max_invocations);
    ]

(* meta round-trips: the server's queue is meta.json files (§8's index record),
   so it must read back what it wrote.  Reading is lenient about unknown
   fields, per the additive-versioning rule. *)
let json_member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let json_str = function `String s -> Some s | _ -> None

let meta_of_json j =
  let mem k = json_member k j in
  match
    ( json_str (mem "run_id"),
      Option.bind (json_str (mem "state")) run_state_of_string,
      json_str (mem "requested_by"),
      json_str (mem "command"),
      json_str (mem "machine"),
      Option.bind (json_str (mem "family")) family_of_string,
      json_str (mem "queued_at") )
  with
  | ( Some run_id,
      Some state,
      Some requested_by,
      Some command,
      Some machine,
      Some family,
      Some queued_at ) ->
    let links_j = mem "links" in
    let pin_of j =
      match json_str (json_member "name" j) with
      | None -> None
      | Some name ->
        Some
          {
            name;
            commit =
              Option.value
                (json_str (json_member "commit" j))
                ~default:
                  (Option.value
                     (json_str (json_member "version" j))
                     ~default:"");
            repo =
              Option.value
                (json_str (json_member "repo" j))
                ~default:"https://github.com/ocaml/ocaml";
            configure_args =
              Option.value
                (json_str (json_member "configure_args" j))
                ~default:"";
          }
    in
    Ok
      {
        run_id;
        state;
        run_key = Option.value (json_str (mem "run_key")) ~default:"";
        pr_url = json_str (mem "pr_url");
        requested_by;
        command;
        machine;
        family;
        baseline = pin_of (mem "baseline");
        candidates =
          (match mem "candidates" with
          | `List l -> List.filter_map pin_of l
          | _ -> []);
        queued_at;
        started_at = json_str (mem "started_at");
        finished_at = json_str (mem "finished_at");
        duration_seconds =
          (match mem "duration_seconds" with `Int s -> Some s | _ -> None);
        cells_passed =
          (match mem "cells_passed" with `Int i -> i | _ -> 0);
        cells_failed =
          (match mem "cells_failed" with `Int i -> i | _ -> 0);
        summary =
          (match json_member "improved" (mem "summary") with
          | `Int improved ->
            let int k =
              match json_member k (mem "summary") with `Int i -> i | _ -> 0
            in
            Some
              {
                improved;
                regressed = int "regressed";
                unchanged = int "unchanged";
                noisy = int "noisy";
              }
          | _ -> None);
        links =
          {
            status = Option.value (json_str (json_member "status" links_j)) ~default:"";
            webview =
              Option.value (json_str (json_member "webview" links_j)) ~default:"";
          };
      }
  | _ -> Error "meta.json is missing a required field"

(* pin round-trips: pins.json is the server's control file. *)
let json_of_pin (p : pin) =
  `Assoc
    [
      ("component", str (string_of_component p.pinned_component));
      ("track", str p.track);
      ("commit", str p.commit);
      ("version", opt_str p.version);
      ("bumped_at", str p.bumped_at);
      ("bumped_by", str p.bumped_by);
    ]

let pin_of_json j =
  let mem k = json_member k j in
  match
    ( Option.bind (json_str (mem "component")) component_of_string,
      json_str (mem "track"),
      json_str (mem "commit") )
  with
  | Some pinned_component, Some track, Some commit ->
    Ok
      {
        pinned_component;
        track;
        commit;
        version = json_str (mem "version");
        bumped_at = Option.value (json_str (mem "bumped_at")) ~default:"";
        bumped_by = Option.value (json_str (mem "bumped_by")) ~default:"";
      }
  | _ -> Error "pin is missing component/track/commit"

let json_of_versions (v : versions) =
  `Assoc
    [
      ("service", str v.service);
      ("pins", `List (List.map json_of_pin v.pins));
      ( "machines",
        `Assoc
          (List.map
             (fun (m, kvs) ->
               (m, `Assoc (List.map (fun (k, value) -> (k, str value)) kvs)))
             v.machines) );
    ]

let json_of_meta (m : meta) =
  `Assoc
    [
      ("run_id", str m.run_id);
      ("state", str (string_of_run_state m.state));
      ("run_key", str m.run_key);
      ("pr_url", opt_str m.pr_url);
      ("requested_by", str m.requested_by);
      ("command", str m.command);
      ("machine", str m.machine);
      ("family", str (string_of_family m.family));
      ( "baseline",
        match m.baseline with None -> `Null | Some p -> json_of_runtime_pin p );
      ("candidates", `List (List.map json_of_runtime_pin m.candidates));
      ("queued_at", str m.queued_at);
      ("started_at", opt_str m.started_at);
      ("finished_at", opt_str m.finished_at);
      ( "duration_seconds",
        match m.duration_seconds with None -> `Null | Some s -> `Int s );
      ("cells_passed", `Int m.cells_passed);
      ("cells_failed", `Int m.cells_failed);
      ( "summary",
        match m.summary with None -> `Null | Some s -> json_of_summary s );
      ("links", json_of_links m.links);
    ]

(* --- API B encodings (§6.2) ------------------------------------------------ *)

let json_of_provenance (p : provenance) =
  `Assoc
    [
      ("compiler_sha", str p.compiler_sha);
      ("configure_args", str p.configure_args);
      ("dune_version", str p.dune_version);
      ("opam_repo_commit", str p.opam_repo_commit);
      ("built_at", str p.built_at);
      ("build_id", str p.build_id);
    ]

let provenance_of_json j =
  let field k = Option.value (json_str (json_member k j)) ~default:"" in
  {
    compiler_sha = field "compiler_sha";
    configure_args = field "configure_args";
    dune_version = field "dune_version";
    opam_repo_commit = field "opam_repo_commit";
    built_at = field "built_at";
    build_id = field "build_id";
  }

let json_of_cache_entry = function
  | Switch { runtime_name; provenance; size_bytes; last_used } ->
    `Assoc
      [
        ("cache", str "switch");
        ("runtime_name", str runtime_name);
        ("provenance", json_of_provenance provenance);
        ("size_bytes", str (Int64.to_string size_bytes));
        ("last_used", str last_used);
      ]
  | Binaries { runtime_name; benches_commit; switch_build_id; size_bytes; last_used }
    ->
    `Assoc
      [
        ("cache", str "binaries");
        ("runtime_name", str runtime_name);
        ("benches_commit", str benches_commit);
        ("switch_build_id", str switch_build_id);
        ("size_bytes", str (Int64.to_string size_bytes));
        ("last_used", str last_used);
      ]

let cache_entry_of_json j =
  let field k = Option.value (json_str (json_member k j)) ~default:"" in
  let size =
    match Int64.of_string_opt (field "size_bytes") with
    | Some s -> s
    | None -> 0L
  in
  match json_str (json_member "cache" j) with
  | Some "switch" ->
    Ok
      (Switch
         {
           runtime_name = field "runtime_name";
           provenance = provenance_of_json (json_member "provenance" j);
           size_bytes = size;
           last_used = field "last_used";
         })
  | Some "binaries" ->
    Ok
      (Binaries
         {
           runtime_name = field "runtime_name";
           benches_commit = field "benches_commit";
           switch_build_id = field "switch_build_id";
           size_bytes = size;
           last_used = field "last_used";
         })
  | _ -> Error "cache entry: unknown `cache` kind"

let json_of_execution_id (id : execution_id) =
  `Assoc [ ("run_id", str id.run_id); ("execution", `Int id.execution) ]

let json_of_assignment (a : assignment) =
  `Assoc
    [
      ("id", json_of_execution_id a.id);
      ("spec", a.spec);
      ("caches", str (match a.caches with `Reuse -> "reuse" | `Bypass -> "bypass"));
      ("resume", `Bool a.resume);
      ("timeout_seconds", `Int a.timeout_seconds);
    ]

let assignment_of_json j =
  let idj = json_member "id" j in
  match
    (json_str (json_member "run_id" idj), json_member "execution" idj)
  with
  | Some run_id, `Int execution ->
    Ok
      {
        id = { run_id; execution };
        spec = json_member "spec" j;
        caches =
          (match json_str (json_member "caches" j) with
          | Some "bypass" -> `Bypass
          | _ -> `Reuse);
        resume =
          (match json_member "resume" j with `Bool b -> b | _ -> false);
        timeout_seconds =
          (match json_member "timeout_seconds" j with
          | `Int t -> t
          | _ -> 90 * 60);
      }
  | _ -> Error "assignment: missing execution id"

let json_of_execution_result (r : execution_result) =
  `Assoc
    [
      ("outcome", str (string_of_execution_outcome r.outcome));
      ("cells_passed", `Int r.cells_passed);
      ("cells_failed", `Int r.cells_failed);
      ("detail", opt_str r.detail);
    ]

let execution_result_of_json j =
  match
    Option.bind (json_str (json_member "outcome" j)) execution_outcome_of_string
  with
  | None -> Error "execution result: bad `outcome`"
  | Some outcome ->
    let int k = match json_member k j with `Int i -> i | _ -> 0 in
    Ok
      {
        outcome;
        cells_passed = int "cells_passed";
        cells_failed = int "cells_failed";
        detail = json_str (json_member "detail" j);
      }

(* Wire shape for post_events: the agent sends [{seq, ts, body}]; run_id and
   execution come from the AUTHENTICATED execution id, never from the payload
   (the bench machine is treated as compromisable -- it must not be able to
   write into another run's stream). *)
let event_of_wire ~(id : execution_id) j =
  match (json_member "seq" j, json_str (json_member "ts" j)) with
  | `Int seq, Some ts ->
    Ok
      {
        seq;
        ts;
        run_id = id.run_id;
        execution = id.execution;
        body = json_member "body" j;
      }
  | _ -> Error "event: missing seq/ts"

let json_of_event (e : event) =
  `Assoc
    [
      ("seq", `Int e.seq);
      ("ts", str e.ts);
      ("run_id", str e.run_id);
      ("execution", `Int e.execution);
      ("body", e.body);
    ]
