(* Who may trigger a run, and as what role (§5.1, §5.4).

   The bench machine executes arbitrary compiler code from a PR, and a run costs
   an hour of exclusive machine time.  Both make triggering a privilege, so the
   gate is an explicit allowlist rather than a heuristic: `author_association`
   alone would let any first-time contributor to a repo the bot is installed on
   queue an hour of work.

   Two roles (the document's `auth.role`):

   * **users** submit, watch, and cancel their own runs;
   * **admins** additionally operate the service -- and only they may use the
     grammar keys that spend other people's time: `force=true` (run past the
     cost cap, Q4) and `priority=top` (jump the queue, Q10).

   Identity is a GitHub login everywhere; HOW it was proven (bot-asserted
   commenter, CLI bearer token) is the requester's concern and never reaches
   this module.

   `allow_associations` exists as an escape hatch (set it to ["OWNER"] and
   repository owners can trigger without being listed), but it is empty by
   default.  Explicit beats inferred here. *)

type decision =
  | Allowed of Api.auth * string (* why *)
  | Denied of string (* message, postable verbatim *)

let check (cfg : Service_config.t) ~login ~association =
  let login_lc = String.lowercase_ascii (String.trim login) in
  let auth role = { Api.login = login_lc; role } in
  if login_lc = "" then Denied "Could not determine who sent this command."
  else if List.mem login_lc cfg.admins then Allowed (auth Api.Admin, "admin")
  else if List.mem login_lc cfg.allowlist then
    Allowed (auth Api.User, "allowlisted login")
  else
    match association with
    | Some a when List.mem a cfg.allow_associations ->
      Allowed (auth Api.User, Printf.sprintf "author_association=%s" a)
    | _ ->
      Denied
        (Printf.sprintf
           "Sorry @%s -- benchmark runs take about an hour of exclusive machine \
            time, so only a few people can start one for now. Ask a maintainer \
            to add you to the allowlist."
           login)

let allowed = function Allowed _ -> true | Denied _ -> false

let message = function Allowed (_, why) -> why | Denied m -> m

let auth = function Allowed (a, _) -> Some a | Denied _ -> None

(* The admin-only grammar keys.  Parsed for everyone (the grammar stays pure and
   role-free) and refused here, where the role is known, BEFORE any generation
   work happens.  The refusal names the privilege, not just the failure. *)
let vet_request (auth : Api.auth) (r : Request.t) : (unit, Api.error) result =
  match auth.role with
  | Api.Admin -> Ok ()
  | Api.User ->
    if r.force then
      Api.error Api.Forbidden
        "`force=true` runs past the cost limit and is admin-only. Shrink the \
         request instead (lower `invocations=`, a smaller `tag=`, fewer sweep \
         values), or ask an admin to force it."
    else if r.priority <> None then
      Api.error Api.Forbidden
        "`priority=` is admin-only; requests are otherwise served in order. \
         Drop it and your run will be queued normally."
    else Ok ()
