(* Parsing a `/bench` comment into a request.

   Untrusted input from a PR comment, so every rejection produces a message good
   enough to post back verbatim.

   The grammar is deliberately small.  Tool selection (perf group, memtrace) and
   explicit benchmark lists were cut from the prototype: perf_grp1 is always
   attached, and the benchmark set is chosen with `tag=`.  Adding them back later
   is additive -- taking them away once people use them would not be.

   This module resolves nothing: no refs to shas (no network), no idea which
   tags exist (that is Facts), no cost decision (that is Cost).  Keeping it pure
   is what makes it table-testable. *)

type action = Run | Cancel | Rerun | Help

type sweep = { dimension : string; values : string list }

type t = {
  action : action;
  machine : string option;
  iterations : int option;
  tag : string option;
  vs : string list;
  sweeps : sweep list;
  force : bool;
  warnings : string list;
  raw : string;
}

let known_keys = [ "machine"; "iterations"; "tag"; "vs"; "sweep"; "force" ]
let known_actions = [ "cancel"; "rerun"; "help" ]

(* Three iterations of the 20 `default_run` programs on two runtimes is ~1 h on
   the calibration machine -- enough repetition to see past noise, and inside
   the 2 h cost cap. *)
let default_iterations = 3

(* A guard well below the cost cap so an obvious fat-finger (iterations=300) is
   rejected as a typo rather than as an over-budget request. *)
let max_iterations = 10

(* The only measurement modifier in the prototype.  perf_grp* are
   PerfAndOllyAttach, so this is also what collects olly metrics. *)
let perf_modifier = "perf_grp1"

let empty raw =
  {
    action = Run;
    machine = None;
    iterations = None;
    tag = None;
    vs = [];
    sweeps = [];
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
          | "cancel" -> go { req with action = Cancel } rest
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
              | "iterations" ->
                if not (Util.is_int value) then
                  err "`iterations=%s` is not a positive whole number." value
                else
                  let n = int_of_string value in
                  if n < 1 then err "`iterations=%d` must be at least 1." n
                  else if n > max_iterations then
                    err
                      "`iterations=%d` exceeds the limit of %d. If you really \
                       need more repetitions, say so on the PR and we will run \
                       it by hand."
                      n max_iterations
                  else go { req with iterations = Some n } rest
              | "tag" ->
                let ts = Util.comma_list value in
                if List.length ts > 1 then
                  err
                    "`tag=` takes a single name (got %d). One benchmark set per \
                     request keeps the queue predictable."
                    (List.length ts)
                else go { req with tag = Some (List.hd ts) } rest
              | "vs" -> go { req with vs = Util.comma_list value } rest
              | "sweep" -> (
                match parse_sweep value with
                | Error e -> Error e
                | Ok ss -> go { req with sweeps = req.sweeps @ ss } rest)
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

let iterations_or_default t =
  match t.iterations with Some n -> n | None -> default_iterations

(* The name the user actually typed (or the default they got), for messages:
   echoing the resolved running-ng tag back at someone who typed an alias is
   confusing when the two differ. *)
let requested_tag t = match t.tag with None -> "default" | Some n -> n

(* The running-ng tag, after alias resolution.  A bare /bench is default_run. *)
let resolved_tag t =
  match t.tag with
  | None -> Tag_alias.resolve "default"
  | Some name -> Tag_alias.resolve name

let to_json t =
  let s x = `String x in
  let action =
    match t.action with
    | Run -> "run"
    | Cancel -> "cancel"
    | Rerun -> "rerun"
    | Help -> "help"
  in
  `Assoc
    [
      ("action", s action);
      ("machine", match t.machine with None -> `Null | Some m -> s m);
      ("iterations", `Int (iterations_or_default t));
      ("iterations_explicit", `Bool (t.iterations <> None));
      ("tag", s (resolved_tag t));
      ("tag_requested", match t.tag with None -> `Null | Some x -> s x);
      ("vs", `List (List.map s t.vs));
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
