(* Who may trigger a run.

   The bench machine executes arbitrary compiler code from a PR, and a run costs
   an hour of exclusive machine time.  Both make triggering a privilege, so the
   gate is an explicit allowlist rather than a heuristic: `author_association`
   alone would let any first-time contributor to a repo the bot is installed on
   queue an hour of work.

   `allow_associations` exists as an escape hatch (set it to ["OWNER"] and
   repository owners can trigger without being listed), but it is empty by
   default.  Explicit beats inferred here. *)

type decision = Allowed of string (* why *) | Denied of string (* message *)

let check (cfg : Service_config.t) ~login ~association =
  let login_lc = String.lowercase_ascii (String.trim login) in
  if login_lc = "" then Denied "Could not determine who sent this command."
  else if List.mem login_lc cfg.allowlist then Allowed "allowlisted login"
  else
    match association with
    | Some a when List.mem a cfg.allow_associations ->
      Allowed (Printf.sprintf "author_association=%s" a)
    | _ ->
      Denied
        (Printf.sprintf
           "Sorry @%s -- benchmark runs take about an hour of exclusive machine \
            time, so only a few people can start one for now. Ask a maintainer \
            to add you to the allowlist."
           login)

let allowed = function Allowed _ -> true | Denied _ -> false

let message = function Allowed why -> why | Denied m -> m
