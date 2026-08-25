(* Parsing a `/bench` comment into a request.

   Untrusted input from a PR comment, so every rejection produces a message good
   enough to post back verbatim.

   The grammar is deliberately small.  Tool selection (perf group, memtrace) and
   explicit benchmark lists were cut from the prototype: perf_grp1 is always
   attached, and the benchmark set is chosen with `tag=`.  Adding them back later
   is additive -- taking them away once people use them would not be.

   Vocabulary (Q17): the repetition key is `invocations=` -- how many times each
   (benchmark, config) cell is run, each in a fresh process, mapping 1:1 onto
   running-ng's `invocations:`.  "iterations" is not a word this service uses,
   and the old spelling gets a pointer, not a guess.

   This module resolves nothing: no refs to shas (no network), no idea which
   tags exist (that is Facts), no cost decision (that is Cost), no idea who is
   asking (roles are Authz's: `force=` and `priority=` parse here for everyone
   and are refused for non-admins there).  Keeping it pure is what makes it
   table-testable. *)

type action =
  | Run
  | Cancel of string  (* the run id to cancel, from the acknowledgement *)
  | Rerun
  | Help

type sweep = { dimension : string; values : string list }

type priority = Top

type t = {
  action : action;
  machine : string option;
  invocations : int option;
  tags : string list;  (* [] = the default set; several names are a UNION,
                          matching running-ng's apply_tag_filter *)
  vs : string list;
  sweeps : sweep list;
  family : Api.family;
  priority : priority option;  (* admin-only; enforced in Authz *)
  force : bool;  (* admin-only; enforced in Authz *)
  warnings : string list;
  raw : string;
}

let known_keys =
  [ "machine"; "invocations"; "tag"; "vs"; "sweep"; "force"; "family"; "priority" ]

let known_actions = [ "cancel"; "rerun"; "help" ]

(* Three invocations of the 20 `default_run` programs on two runtimes is ~1 h on
   the calibration machine -- enough repetition to see past noise, and inside
   the 2 h cost cap. *)
let default_invocations = 3

(* A guard well below the cost cap so an obvious fat-finger (invocations=300) is
   rejected as a typo rather than as an over-budget request. *)
let max_invocations = 10

(* The only measurement modifier in the prototype.  perf_grp* are
   PerfAndOllyAttach, so this is also what collects olly metrics. *)
let perf_modifier = "perf_grp1"

let empty raw =
  {
    action = Run;
    machine = None;
    invocations = None;
    tags = [];
    vs = [];
    sweeps = [];
    family = Api.Macro;
    priority = None;
    force = false;
    warnings = [];
    raw;
  }

let err fmt = Printf.ksprintf (fun s -> Error s) fmt

(* The command is the first line starting with the /bench token.  The word
   boundary means "/benchmarks are slow" stays prose. *)
let command_line comment =
  let is_command l =
    let l = Util.trim l in
    Util.starts_with ~prefix:"/bench" l
    && (String.length l = 6 || Util.is_space l.[6])
  in
  List.find_opt is_command (Util.split_on ~sep:'\n' comment)

(* sweep=s:1,2;o:80,120 -- semicolons separate dimensions, commas separate
   values.  Dimension keys may be the OCAMLRUNPARAM letter (`s`, `o`) or the
   contract's canonical name (`minor_heap`); resolution happens in Gen against
   vocab.json so the two stay in sync with the contract. *)
let parse_sweep value =
  let parts = Util.split_on ~sep:';' value |> List.map Util.trim in
  let parts = List.filter (fun p -> p <> "") parts in
  if parts = [] then err "`sweep=` was given no dimensions."
  else
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | part :: rest -> (
        match String.index_opt part ':' with
        | None ->
          err
            "`%s` is missing a value list. Use \
             `sweep=<param>:<v1>,<v2>[;<param>:<v1>,<v2>]` -- for example \
             `sweep=s:262144,524288;o:80,120`."
            part
        | Some i ->
          let dim = Util.trim (String.sub part 0 i) in
          let vals =
            Util.comma_list
              (String.sub part (i + 1) (String.length part - i - 1))
          in
          if dim = "" then err "`%s` has an empty parameter name." part
          else if vals = [] then err "`%s` lists no values." part
          else go ({ dimension = dim; values = vals } :: acc) rest)
    in
    go [] parts

let parse comment =
  match command_line comment with
  | None -> err "No `/bench` command found in this comment."
  | Some line -> (
    let toks = match Util.tokens line with [] -> [] | _ :: rest -> rest in
    let seen = Hashtbl.create 8 in
    let rec go req = function
      | [] -> Ok req
      | tok :: rest -> (
        match Util.split_kv tok with
        | None -> (
          match String.lowercase_ascii tok with
          (* Cancellation is by run id, which the acknowledgement comment
             hands out: "my latest run" is ambiguous the moment two requests
             share a PR, and a wrong guess cancels an hour of someone's work. *)
          | "cancel" -> (
            match rest with
            | id :: rest' when Util.split_kv id = None ->
              go { req with action = Cancel id } rest'
            | _ ->
              err
                "`cancel` needs the id of the run to cancel -- it is in the \
                 run's acknowledgement comment. For example `/bench cancel \
                 run-42`.")
          | "rerun" -> go { req with action = Rerun } rest
          | "help" -> go { req with action = Help } rest
          | other ->
            err
              "Unrecognised argument `%s`.%s Arguments look like `key=value`; \
               the bare words are `cancel`, `rerun` and `help`. Run `/bench \
               help` for the full list."
              other
              (Util.suggest ~candidates:(known_keys @ known_actions) other))
        | Some (key, value) ->
          let key = String.lowercase_ascii key in
          if key <> "sweep" && Hashtbl.mem seen key then
            err "`%s=` was given more than once." key
          else begin
            Hashtbl.replace seen key ();
            if value = "" then err "`%s=` was given an empty value." key
            else
              match key with
              | "machine" -> go { req with machine = Some (Util.trim value) } rest
              | "invocations" ->
                if not (Util.is_int value) then
                  err "`invocations=%s` is not a positive whole number." value
                else
                  let n = int_of_string value in
                  if n < 1 then err "`invocations=%d` must be at least 1." n
                  else if n > max_invocations then
                    err
                      "`invocations=%d` exceeds the limit of %d. If you really \
                       need more repetitions, say so on the PR and we will run \
                       it by hand."
                      n max_invocations
                  else go { req with invocations = Some n } rest
              (* The old spelling gets a pointer, not a "did you mean" guess:
                 it is three edits from the real key, and everyone coming from
                 the prototype will type it. *)
              | "iterations" ->
                err
                  "`iterations=` is not a `/bench` key; use `invocations=%s` \
                   -- how many times each benchmark is run, each in a fresh \
                   process."
                  value
              | "tag" -> (
                (* Several names are allowed and mean their UNION -- exactly
                   running-ng's comma-separated RUNNING_TAG semantics. *)
                let ts = Util.comma_list value in
                let dup =
                  List.filter
                    (fun t -> List.length (List.filter (( = ) t) ts) > 1)
                    ts
                in
                match dup with
                | d :: _ -> err "`tag=` names `%s` more than once." d
                | [] -> go { req with tags = ts } rest)
              | "vs" -> go { req with vs = Util.comma_list value } rest
              | "sweep" -> (
                match parse_sweep value with
                | Error e -> Error e
                | Ok ss -> go { req with sweeps = req.sweeps @ ss } rest)
              | "family" -> (
                match Api.family_of_string (String.lowercase_ascii value) with
                | Some Api.Macro -> go { req with family = Api.Macro } rest
                (* Reserved (§12): the field exists so micro can be added
                   without breaking any interface, but nothing serves it yet. *)
                | Some Api.Micro ->
                  err
                    "`family=micro` is reserved but not yet supported; the \
                     macro benchmarks are the only family that runs today."
                | None ->
                  err "`family=%s` is not a benchmark family.%s The families \
                       are `macro` (the default) and `micro` (reserved)."
                    value
                    (Util.suggest ~candidates:[ "macro"; "micro" ] value))
              | "priority" -> (
                match String.lowercase_ascii value with
                | "top" -> go { req with priority = Some Top } rest
                | v ->
                  err
                    "`priority=%s` is not recognised; the only priority is \
                     `top` (admin-only: enqueue at the front of the queue)."
                    v)
              | "force" -> (
                match String.lowercase_ascii value with
                | "true" | "yes" | "1" -> go { req with force = true } rest
                | "false" | "no" | "0" -> go { req with force = false } rest
                | v -> err "`force=%s` must be `true` or `false`." v)
              | other ->
                err "Unknown option `%s`.%s Run `/bench help` for the full list."
                  other
                  (Util.suggest ~candidates:known_keys other)
          end)
    in
    match go (empty line) toks with
    | Error e -> Error e
    | Ok req ->
      let dims = List.map (fun s -> s.dimension) req.sweeps in
      let dup = List.filter (fun d -> List.length (List.filter (( = ) d) dims) > 1) dims in
      if dup <> [] then
        err "`sweep=` names the parameter `%s` more than once." (List.hd dup)
      else Ok req)

(* --- accessors --- *)

let invocations_or_default t =
  match t.invocations with Some n -> n | None -> default_invocations

(* The names the user actually typed (or the default they got), for messages:
   echoing the resolved running-ng tags back at someone who typed an alias is
   confusing when the two differ. *)
let requested_tags t = match t.tags with [] -> [ "default" ] | ts -> ts

(* The running-ng tags, after alias resolution.  A bare /bench is default_run. *)
let resolved_tags t = List.map Tag_alias.resolve (requested_tags t)

(* (requested, resolved) pairs, for validation and for the run spec. *)
let tag_pairs t =
  List.map (fun name -> (name, Tag_alias.resolve name)) (requested_tags t)

let to_json t =
  let s x = `String x in
  let action =
    match t.action with
    | Run -> "run"
    | Cancel _ -> "cancel"
    | Rerun -> "rerun"
    | Help -> "help"
  in
  `Assoc
    [
      ("action", s action);
      ( "cancel_run_id",
        match t.action with Cancel id -> s id | _ -> `Null );
      ("machine", match t.machine with None -> `Null | Some m -> s m);
      ("invocations", `Int (invocations_or_default t));
      ("invocations_explicit", `Bool (t.invocations <> None));
      ("tags", `List (List.map s (resolved_tags t)));
      ( "tags_requested",
        match t.tags with [] -> `Null | ts -> `List (List.map s ts) );
      ("vs", `List (List.map s t.vs));
      ("family", s (Api.string_of_family t.family));
      ("priority", match t.priority with None -> `Null | Some Top -> s "top");
      ( "sweeps",
        `List
          (List.map
             (fun sw ->
               `Assoc
                 [
                   ("dimension", s sw.dimension);
                   ("values", `List (List.map s sw.values));
                 ])
             t.sweeps) );
      ("force", `Bool t.force);
      ("warnings", `List (List.map s t.warnings));
    ]
