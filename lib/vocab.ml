(* Sweep dimensions, read from the contract's generated vocab.json so the
   grammar's canonical names (`space_overhead`) stay in sync with the contract.
   Policy: runtime_events_ring_log2/max_domains are measurement infrastructure
   and gc_plan/gc_threads are MMTk-only, so only s, o, M, m are sweepable. *)

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

(* Either spelling is accepted, `sweep=o:80,120` or `sweep=space_overhead:80,120`;
   both resolve to the same modifier. *)
let find_any dims key =
  match find dims key with
  | Some d -> Some d
  | None -> List.find_opt (fun d -> d.modifier = key) dims

let names dims = List.map (fun d -> d.dimension) dims |> List.sort_uniq compare

(* Every accepted spelling, for "did you mean" and for help. *)
let keys dims =
  List.concat_map (fun d -> [ d.modifier; d.dimension ]) dims
  |> List.sort_uniq compare
