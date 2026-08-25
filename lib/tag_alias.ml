(* Friendly tag names for the comment grammar.

   running-ng's tags are `default_run`, `small_run`, `large_run`, `huge_run`,
   `legacy`, `all_benches` plus ~16 runtime-feature tags.  A PR author should
   type `tag=small`, so the grammar exposes short aliases and maps them here.

   Unaliased names fall through unchanged, which keeps the feature tags
   (`bigarrays`, `effects`, `io_uring`, ...) reachable for anyone who knows
   they exist without putting them in the documented surface.  Validity is
   still checked against the base config, so a fall-through typo is caught. *)

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

(* The tag vocabulary in user-facing order: the documented aliases first, then
   whatever tags the base config defines that they do not cover (the feature
   tags: bigarrays, effects, ...).  Both spellings the grammar accepts. *)
let vocabulary ~defined =
  let aliased = List.map resolve documented in
  documented @ List.filter (fun t -> not (List.mem t aliased)) defined
