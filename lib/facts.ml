(* Facts about the base config, as reported by scripts/rng_helper.py.

   We never parse macro_base.yml ourselves.  running-ng owns includes/overrides
   merge semantics and the tag block; a second implementation of those rules is
   precisely the drift DATA_CONTRACT.md exists to prevent.  So the bridge dumps
   JSON and this module only reads it. *)

type tag = { name : string; programs : int; gap : bool }

type suite = {
  name : string;
  programs : string list;
  enabled : string list;
  ocamlrunparam : string option;
}

type t = {
  invocations : int;
  schema_version : string option;
  (* True once any suite or program declares `ocamlrunparam:` (running-ng #15).
     Then the runtime_events ring and domain cap live on the benchmarks, and a
     generated config must NOT carry re-N|md-M -- a config-string value is
     merged under the benchmark's, so a global one shadows nothing useful and
     silently reintroduces the setting we moved out. *)
  uses_ocamlrunparam : bool;
  tags : tag list;
  suites : suite list;
  modifiers : string list;
}

(* Hand-rolled accessors rather than Yojson.Safe.Util: fewer assumptions about
   the yojson major version installed in a switch we don't own. *)
let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let to_string_opt = function `String s -> Some s | _ -> None
let to_int_opt = function `Int i -> Some i | `Float f -> Some (int_of_float f) | _ -> None
let to_bool = function `Bool b -> b | _ -> false
let to_list = function `List l -> l | _ -> []

let strings j = List.filter_map to_string_opt (to_list j)

let of_json j =
  match member "ok" j with
  | `Bool false ->
    let msg =
      match to_string_opt (member "bridge_error" j) with
      | Some m -> m
      | None -> "rng_helper reported failure"
    in
    Error msg
  | _ ->
    let invocations =
      match to_int_opt (member "invocations" j) with Some n -> n | None -> 1
    in
    let tags =
      to_list (member "tags" j)
      |> List.filter_map (fun t ->
             match to_string_opt (member "name" t) with
             | None -> None
             | Some name ->
               Some
                 {
                   name;
                   programs =
                     (match to_int_opt (member "programs" t) with
                     | Some n -> n
                     | None -> 0);
                   gap = to_bool (member "gap" t);
                 })
    in
    let suites =
      to_list (member "suites" j)
      |> List.filter_map (fun s ->
             match to_string_opt (member "name" s) with
             | None -> None
             | Some name ->
               Some
                 {
                   name;
                   programs = strings (member "programs" s);
                   enabled = strings (member "enabled" s);
                   ocamlrunparam = to_string_opt (member "ocamlrunparam" s);
                 })
    in
    let modifiers =
      to_list (member "modifiers" j)
      |> List.filter_map (fun m -> to_string_opt (member "name" m))
    in
    if tags = [] && suites = [] then
      Error "rng_helper returned no tags and no suites -- wrong config file?"
    else
      Ok
        {
          invocations;
          schema_version = to_string_opt (member "schema_version" j);
          uses_ocamlrunparam = to_bool (member "uses_ocamlrunparam" j);
          tags;
          suites;
          modifiers;
        }

let of_json_string s =
  match Yojson.Safe.from_string s with
  | j -> of_json j
  | exception Yojson.Json_error m -> Error ("bad JSON from rng_helper: " ^ m)

let of_file path =
  match Util.read_file path with
  | s -> of_json_string s
  | exception Sys_error m -> Error m

let tag_names t = List.map (fun (tg : tag) -> tg.name) t.tags

let find_tag t name = List.find_opt (fun (tg : tag) -> tg.name = name) t.tags

(* Programs actually runnable: a program listed by a suite but absent from
   `benchmarks:` is disabled (merlin, lavyek), and no tag can revive it --
   apply_tag_filter is intersection-only. *)
let enabled_programs t =
  List.concat_map (fun (s : suite) -> s.enabled) t.suites

(* Suites with enabled programs that need the *parallel* runtime_events settings
   plus CPU pinning (`re_par-22|md_par-8|pin_lavyek`) in the config string.

   running-ng #15 moved the sequential `re`/`md` onto the benchmarks
   (`ocamlrunparam:`) but deliberately left the parallel path in the config
   string, and macro_base.yml still states that a config enabling a lavyek suite
   MUST add the triple.  Without it olly drops events and `wall_time` goes
   negative, so this cannot be left to chance.

   Detected by suite name: the `excludes:` maps on those modifiers are
   exclusion-only, so there is no positive declaration to read, and every suite
   that needs the triple is a lavyek one.  If a second parallel suite ever
   appears, this is the function to teach about it. *)
let par_chain_suites t =
  List.filter
    (fun (s : suite) ->
      s.enabled <> []
      && Util.contains ~needle:"lavyek" (String.lowercase_ascii s.name))
    t.suites

(* Which suite owns a program.  Searches the enabled set only, so asking for a
   disabled program gives "unknown" rather than a config that silently runs
   nothing. *)
let suite_of_program t program =
  List.find_opt
    (fun (s : suite) -> List.mem program s.enabled)
    t.suites
  |> Option.map (fun (s : suite) -> s.name)
