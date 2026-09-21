(* Cost estimation and the budget guard: computed before acceptance, shown in
   the acknowledgement, enforced.  The unit is the cell, one (program, config)
   pair run `invocations` times.  `default_cell_seconds` is calibrated from one
   measurement (30 s per cell-invocation); per-program history should replace it. *)

type t = {
  programs : int;
  configs : int;
  invocations : int;
  cells : int;
  seconds : float;
}

let default_cell_seconds = 30.0

(* Compiler builds are excluded from the estimate: they are cached and highly
   variable, so they are reported separately rather than folded into a number the
   user is asked to reason about. *)
let default_cap_seconds = 2.0 *. 60.0 *. 60.0

let estimate ?(cell_seconds = default_cell_seconds) ~programs ~configs
    ~invocations () =
  let cells = programs * configs in
  {
    programs;
    configs;
    invocations;
    cells;
    seconds = float_of_int (cells * invocations) *. cell_seconds;
  }

let human seconds =
  let s = int_of_float (Float.round seconds) in
  let h = s / 3600 and m = s mod 3600 / 60 in
  if h > 0 then Printf.sprintf "%dh%02dm" h m
  else if m > 0 then Printf.sprintf "%dm" m
  else Printf.sprintf "%ds" s

let over_cap ?(cap_seconds = default_cap_seconds) t = t.seconds > cap_seconds

let explain t =
  Printf.sprintf "%s (%d programs x %d configs x %d invocations = %d measurements)"
    (human t.seconds) t.programs t.configs t.invocations
    (t.cells * t.invocations)

(* The refusal must say what to change.  `force=true` is admin-only and the
   text says so rather than dangling an option most readers cannot use. *)
let refusal ?(cap_seconds = default_cap_seconds) t =
  Printf.sprintf
    "This request is estimated at **%s**, over the %s limit.\n\n%s\n\nTo shrink \
     it: lower `invocations=`, pick a smaller `tag=` (`small` or `default`), or \
     drop sweep values. An admin can run it anyway with `force=true`."
    (human t.seconds) (human cap_seconds) (explain t)
