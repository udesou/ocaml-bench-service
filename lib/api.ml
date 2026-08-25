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

type error = { code : error_code; error_markdown : string }
(* [error_markdown] is ALWAYS safe to post to a PR verbatim. *)

let error code fmt =
  Printf.ksprintf (fun error_markdown -> Error { code; error_markdown }) fmt

(* --- payload types (§5.3) ------------------------------------------------- *)

type family = Macro | Micro (* Micro is reserved: refused until §12 lands *)

type runtime_pin = {
  name : string;
      (** running-ng runtime name; doubles as the compiler cache key,
          e.g. "ocaml-pr-14796-e5f6a7b" *)
  commit : string;  (** resolved sha; never a ref *)
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
  queued_at : string;
  finished_at : string option;
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
  val machines : auth -> (machine_status list, error) result
  val drain : auth -> machine:string -> (unit, error) result
  val undrain : auth -> machine:string -> (unit, error) result
  val requeue : auth -> run_id:string -> (unit, error) result
  val evict : auth -> machine:string -> cache_selector -> (int64, error) result
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

let string_of_run_state = function
  | Queued -> "queued"
  | Running -> "running"
  | Publishing -> "publishing"
  | Done -> "done"
  | Failed -> "failed"
  | Timed_out -> "timed_out"
  | Cancelled -> "cancelled"

let string_of_execution_phase = function
  | Preparing -> "preparing"
  | Provisioning -> "provisioning"
  | Building -> "building"
  | Measuring -> "measuring"
  | Collecting -> "collecting"
  | Aborted -> "aborted"

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

let json_of_runtime_pin (p : runtime_pin) =
  `Assoc
    [
      ("name", str p.name);
      ("commit", str p.commit);
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
      ("queued_at", str m.queued_at);
      ("finished_at", opt_str m.finished_at);
      ( "summary",
        match m.summary with None -> `Null | Some s -> json_of_summary s );
      ("links", json_of_links m.links);
    ]
