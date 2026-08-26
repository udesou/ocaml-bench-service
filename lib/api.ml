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
        finished_at = json_str (mem "finished_at");
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
      ("finished_at", opt_str m.finished_at);
      ( "summary",
        match m.summary with None -> `Null | Some s -> json_of_summary s );
      ("links", json_of_links m.links);
    ]
