(* Friendly tag names for the comment grammar (`tag=small` -> `small_run`).
   Unaliased names fall through unchanged so the feature tags stay reachable;
   validity is still checked against the base config. *)

let aliases =
  [
    ("default", "default_run");
    ("small", "small_run");
    ("large", "large_run");
    ("huge", "huge_run");
    ("legacy", "legacy");
    ("all", "all_benches");
  ]

(* The documented set, in the order help should list them. *)
let documented = List.map fst aliases

let resolve name =
  match List.assoc_opt name aliases with Some t -> t | None -> name

(* Reverse lookup, for reporting a running-ng tag back in the user's words. *)
let friendly tag =
  match List.find_opt (fun (_, t) -> t = tag) aliases with
  | Some (a, _) -> a
  | None -> tag

(* The tag vocabulary in user-facing order: documented aliases first, then the
   base config's remaining tags (the feature tags). *)
let vocabulary ~defined =
  let aliased = List.map resolve documented in
  documented @ List.filter (fun t -> not (List.mem t aliased)) defined
