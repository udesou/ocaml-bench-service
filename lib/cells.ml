(* What became of each cell of a run: one (benchmark, runtime) pair, from the
   files running-ng leaves in its run directory. *)

type cell = string * string (* benchmark, runtime *)

type failure = { cell : cell; reason : string }

let entries ~key s =
  let open Yojson.Safe.Util in
  try Yojson.Safe.from_string s |> member key |> to_list with _ -> []

let failures ~key s =
  let open Yojson.Safe.Util in
  List.filter_map
    (fun j ->
      match
        (member "benchmark" j |> to_string, member "runtime" j |> to_string)
      with
      | cell ->
        let reason =
          match member "reason" j with `String r -> r | _ -> ""
        in
        Some { cell; reason }
      | exception _ -> None)
    (entries ~key s)

(* build-failures.json *)
let build_failures s = failures ~key:"build_failures" s

(* run-failures.json: one entry per failed invocation *)
let run_failures s = failures ~key:"run_failures" s

(* Cells the contract holds at least one measurement of.  Rows name a
   config_id; the manifest maps it to the runtime that produced it. *)
let measured ~manifest ~measurements =
  let open Yojson.Safe.Util in
  let runtime_of =
    List.filter_map
      (fun c ->
        try
          let rt =
            match member "_runtime_name" c with
            | `String n -> n
            | _ -> member "runtime" c |> member "version" |> to_string
          in
          Some (member "config_id" c |> to_string, rt)
        with _ -> None)
      (try Yojson.Safe.from_string manifest |> member "configs" |> to_list
       with _ -> [])
  in
  List.concat_map
    (fun ndjson ->
      List.filter_map
        (fun line ->
          try
            let j = Yojson.Safe.from_string line in
            let bench = member "benchmark" j |> member "name" |> to_string in
            let cid = member "config" j |> member "config_id" |> to_string in
            Option.map (fun rt -> (bench, rt)) (List.assoc_opt cid runtime_of)
          with _ -> None)
        (String.split_on_char '\n' ndjson))
    measurements
  |> List.sort_uniq compare

(* A cell passed when it was measured and nothing about it failed: any failed
   invocation fails the cell.  Every other planned cell failed, so one that
   left no trace (no row, no failure entry) still counts against the run. *)
let count ~planned ~measured ~failed =
  let passed =
    List.filter (fun c -> not (List.mem c failed)) measured |> List.length
  in
  let passed = min planned passed in
  (passed, planned - passed)

(* One line per failed cell, its first reason, and how many invocations. *)
let summarise (fs : failure list) =
  let cells = List.sort_uniq compare (List.map (fun f -> f.cell) fs) in
  List.map
    (fun cell ->
      let mine = List.filter (fun f -> f.cell = cell) fs in
      (cell, (List.hd mine).reason, List.length mine))
    cells
