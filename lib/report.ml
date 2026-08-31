(* The report renderer: contract artifacts -> report.md.

   Pure: manifest + measurement lines in, markdown out.  Rendered by the
   SERVER at finish (the agent uploads the contract, the server owns the
   prose), written into the bundle as report.md and embedded verbatim in the
   completion comment.

   The verdict policy, agreed 2026-08-31: the three headline metrics are
   reported INDIVIDUALLY, never composed into one verdict -- no metric is
   authoritative (fp changes can regress instructions while wall barely
   moves; RSS can step for allocator reasons).  Each column uses the
   dashboard's shared vocabulary (delta of per-benchmark MEDIANS across
   invocations; warn at +-warn_pct, significant at +-significant_pct), plus
   two honesty gates:

   * wall_time: below wall_min_invocations, deltas are shown but never
     receive a verdict mark -- one invocation of a noisy metric is weather,
     not climate;
   * max_rss: a verdict needs the percentage band AND an absolute move of at
     least rss_floor_kib -- percent of a small heap shouts too easily.

   Thresholds live in service.json ("report": {...}) and are PROVISIONAL
   until Q12's repeat-run noise data. *)

type thresholds = {
  warn_pct : float;
  significant_pct : float;
  wall_min_invocations : int;
  rss_floor_kib : float;
}

let default_thresholds =
  {
    warn_pct = 1.0;
    significant_pct = 3.0;
    wall_min_invocations = 3;
    rss_floor_kib = 1024.0;
  }

(* --- contract parsing -------------------------------------------------------- *)

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let jstr = function `String s -> Some s | _ -> None

let jnum = function
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

(* config_id -> runtime name, from the manifest *)
let runtimes_of_manifest manifest =
  List.filter_map
    (fun c ->
      match (jstr (member "config_id" c), jstr (member "_runtime_name" c)) with
      | Some id, Some name -> Some (id, name)
      | Some id, None ->
        Option.map (fun v -> (id, v)) (jstr (member "version" (member "runtime" c)))
      | _ -> None)
    (match member "configs" manifest with `List l -> l | _ -> [])

(* one measurement line -> (benchmark, runtime, [(metric, value)]) *)
let parse_line ~runtime_of line =
  match Yojson.Safe.from_string line with
  | exception _ -> None
  | j -> (
    match
      ( jstr (member "name" (member "benchmark" j)),
        Option.bind
          (jstr (member "config_id" (member "config" j)))
          (fun id -> List.assoc_opt id runtime_of) )
    with
    | Some bench, Some runtime ->
      Some
        ( bench,
          runtime,
          List.filter_map
            (fun m ->
              match (jstr (member "name" m), jnum (member "value" m)) with
              | Some n, Some v -> Some (n, v)
              | _ -> None)
            (match member "metrics" j with `List l -> l | _ -> []) )
    | _ -> None)

(* (bench, runtime, metric) -> values across invocations *)
let index ~runtime_of lines =
  let tbl = Hashtbl.create 64 in
  List.iter
    (fun line ->
      match parse_line ~runtime_of line with
      | None -> ()
      | Some (bench, runtime, metrics) ->
        List.iter
          (fun (metric, v) ->
            let key = (bench, runtime, metric) in
            Hashtbl.replace tbl key
              (v :: (try Hashtbl.find tbl key with Not_found -> [])))
          metrics)
    lines;
  tbl

let median = function
  | [] -> None
  | xs ->
    let a = List.sort compare xs in
    let n = List.length a in
    let nth i = List.nth a i in
    Some
      (if n mod 2 = 1 then nth (n / 2)
       else (nth ((n / 2) - 1) +. nth (n / 2)) /. 2.0)

(* --- verdicts ---------------------------------------------------------------- *)

type mark = Regression | Improvement | Warn | Neutral | Ungated

let mark_of ~(t : thresholds) delta_pct =
  if delta_pct >= t.significant_pct then Regression
  else if delta_pct <= -.t.significant_pct then Improvement
  else if Float.abs delta_pct >= t.warn_pct then Warn
  else Neutral

let icon = function
  | Regression -> " \xe2\xac\x86" (* up arrow *)
  | Improvement -> " \xe2\xac\x87" (* down arrow *)
  | Warn -> " \xe2\x9a\xa0" (* warning sign *)
  | Neutral | Ungated -> ""

(* --- rendering --------------------------------------------------------------- *)

let headline_metrics = [ ("wall_time", "wall"); ("instructions", "instructions"); ("max_rss", "max RSS") ]

let pct = Printf.sprintf "%+.1f%%"

let humane v =
  (* absolute values for the single-runtime table *)
  if Float.abs v >= 1e9 then Printf.sprintf "%.2fG" (v /. 1e9)
  else if Float.abs v >= 1e6 then Printf.sprintf "%.2fM" (v /. 1e6)
  else if Float.abs v >= 1e4 then Printf.sprintf "%.0f" v
  else Printf.sprintf "%.2f" v

(* Render the report BODY (no title: report.md gets one, the completion
   comment supplies its own header).  [olly] and [perf] are the raw ndjson
   file contents; either may be missing. *)
let render ?(thresholds = default_thresholds) ~manifest ~olly ~perf ~baseline
    ~candidates () =
  let t = thresholds in
  let runtime_of = runtimes_of_manifest manifest in
  let lines s = List.filter (fun l -> String.trim l <> "") (String.split_on_char '\n' s) in
  let tbl =
    index ~runtime_of
      (lines (Option.value olly ~default:"")
      @ lines (Option.value perf ~default:""))
  in
  let benches =
    List.sort_uniq compare
      (Hashtbl.fold (fun (b, _, _) _ acc -> b :: acc) tbl [])
  in
  if benches = [] then None
  else begin
    let buf = Buffer.create 1024 in
    let add fmt = Printf.ksprintf (Buffer.add_string buf) fmt in
    let values bench runtime metric =
      try Hashtbl.find tbl (bench, runtime, metric) with Not_found -> []
    in
    let med bench runtime metric = median (values bench runtime metric) in
    let wall_gated = ref false in
    (* one delta cell: median-vs-median, with the per-metric gates *)
    let cell bench cand metric =
      match (med bench baseline metric, med bench cand metric) with
      | Some b, Some c when b <> 0.0 ->
        let d = (c -. b) /. b *. 100.0 in
        let n = List.length (values bench cand metric) in
        let m =
          match metric with
          | "wall_time" when n < t.wall_min_invocations ->
            wall_gated := true;
            Ungated
          | "max_rss" when Float.abs (c -. b) < t.rss_floor_kib -> Ungated
          | _ -> mark_of ~t d
        in
        let note =
          if metric = "wall_time" && n < t.wall_min_invocations then
            Printf.sprintf " (n=%d)*" n
          else ""
        in
        (pct d ^ icon m ^ note, Some m)
      | _ -> ("--", None)
    in
    let marks = Hashtbl.create 8 in
    let count metric m =
      let k = (metric, m) in
      Hashtbl.replace marks k (1 + (try Hashtbl.find marks k with Not_found -> 0))
    in
    List.iter
      (fun cand ->
        add "**`%s` vs `%s`** (negative = candidate is better)\n\n" cand
          baseline;
        add "| benchmark |%s\n"
          (String.concat ""
             (List.map (fun (_, l) -> " " ^ l ^ " |") headline_metrics));
        add "|---|%s\n"
          (String.concat "" (List.map (fun _ -> "---|") headline_metrics));
        List.iter
          (fun bench ->
            add "| `%s` |" bench;
            List.iter
              (fun (metric, _) ->
                let text, m = cell bench cand metric in
                (match m with Some m -> count metric m | None -> ());
                add " %s |" text)
              headline_metrics;
            add "\n")
          benches;
        add "\n")
      candidates;
    (* per-metric counts: information, not a verdict *)
    if candidates <> [] then begin
      let line (metric, label) =
        let n m = try Hashtbl.find marks (metric, m) with Not_found -> 0 in
        Printf.sprintf "%s: %d regressed, %d improved, %d warn, %d unchanged%s"
          label (n Regression) (n Improvement) (n Warn) (n Neutral)
          (if n Ungated > 0 then Printf.sprintf ", %d gated" (n Ungated) else "")
      in
      add "%s\n\n" (String.concat " \xc2\xb7 " (List.map line headline_metrics))
    end;
    if candidates = [] then begin
      (* single runtime: absolute medians, no verdicts *)
      add "**`%s`** (absolute medians; single runtime, nothing to compare)\n\n"
        baseline;
      add "| benchmark | wall (s) | instructions | max RSS (MiB) |\n|---|---|---|---|\n";
      List.iter
        (fun bench ->
          let v metric f =
            match med bench baseline metric with
            | Some x -> f x
            | None -> "--"
          in
          add "| `%s` | %s | %s | %s |\n" bench
            (v "wall_time" (Printf.sprintf "%.2f"))
            (v "instructions" humane)
            (v "max_rss" (fun x -> Printf.sprintf "%.1f" (x /. 1024.0))))
        benches;
      add "\n"
    end;
    if !wall_gated then
      add "\\* wall time below %d invocations: indicative only, never a verdict.\n"
        t.wall_min_invocations;
    add
      "<sub>medians across invocations; bands \xc2\xb1%.0f%% warn, \xc2\xb1%.0f%% \
       significant; RSS verdicts need \xe2\x89\xa5 %.0f MiB moved. Thresholds \
       are provisional (service.json `report`).</sub>\n"
      t.warn_pct t.significant_pct
      (t.rss_floor_kib /. 1024.0);
    Some (Buffer.contents buf)
  end
