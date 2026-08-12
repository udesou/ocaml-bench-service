(* Sweep dimensions, read from the contract's generated vocab.json.

   The comment grammar speaks the contract's canonical dimension names
   (`space_overhead`), not running-ng's modifier tokens (`o`).  That mapping is
   `dimension_of_modifier` in registry.ml, generated into
   schema/json/vocab.json -- so the user-facing vocabulary stays in sync with
   the contract by construction.

   Policy (ours, not the contract's): not every mapped dimension is something a
   PR author should sweep.

   * runtime_events_ring_log2 / max_domains -- `re`/`md`/`re_par`/`md_par` are
     measurement infrastructure.  Changing them doesn't probe the compiler, it
     breaks the harness (a wrong ring size makes olly drop events).
   * gc_plan / gc_threads -- MMTk-only (`plan`/`threads` are EnvVar modifiers on
     OCamlMMTk runtimes); meaningless for a stock OCaml PR.

   What remains is the GC parameter set: s, o, M, m. *)

type dim = { dimension : string; modifier : string; unit_ : string }

let infrastructure_dimensions =
  [ "runtime_events_ring_log2"; "max_domains"; "gc_plan"; "gc_threads" ]

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let all_of_json j =
  match member "dimension_of_modifier" j with
  | `Assoc entries ->
    Ok
      (List.filter_map
         (fun (modifier, spec) ->
           match member "dimension" spec with
           | `String dimension ->
             let unit_ =
               match member "unit" spec with `String u -> u | _ -> ""
             in
             Some { dimension; modifier; unit_ }
           | _ -> None)
         entries)
  | _ -> Error "vocab.json has no `dimension_of_modifier` object"

let sweepable_of_json j =
  match all_of_json j with
  | Error e -> Error e
  | Ok dims ->
    Ok
      (List.filter
         (fun d -> not (List.mem d.dimension infrastructure_dimensions))
         dims)

let of_file ?(sweepable_only = true) path =
  match Util.read_file path with
  | exception Sys_error m -> Error m
  | s -> (
    match Yojson.Safe.from_string s with
    | exception Yojson.Json_error m -> Error ("bad JSON in vocab.json: " ^ m)
    | j -> if sweepable_only then sweepable_of_json j else all_of_json j)

let find dims dimension =
  List.find_opt (fun d -> d.dimension = dimension) dims

(* The comment grammar accepts either spelling: `sweep=o:80,120` (the
   OCAMLRUNPARAM letter people actually say) or `sweep=space_overhead:80,120`
   (the contract's canonical name).  Both resolve to the same modifier, so the
   generated config and the emitted dimension stay consistent either way. *)
let find_any dims key =
  match find dims key with
  | Some d -> Some d
  | None -> List.find_opt (fun d -> d.modifier = key) dims

let names dims = List.map (fun d -> d.dimension) dims |> List.sort_uniq compare

(* Every accepted spelling, for "did you mean" and for help. *)
let keys dims =
  List.concat_map (fun d -> [ d.modifier; d.dimension ]) dims
  |> List.sort_uniq compare
