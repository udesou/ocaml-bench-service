(* Request + base-config facts -> a running-ng run spec.  Pure: resolving refs,
   counting programs and writing files are the caller's job.  The benchmark set
   is selected by the RUNNING_TAG environment variable, not by a config field,
   so the config alone does not describe the run.

   Shape rules that fail silently when got wrong: the config `includes:`
   macro_base.yml and declares only runtimes, configs, modifiers, config_sweep,
   comparisons, overrides; `invocations` must go through `overrides:` (a
   top-level redefinition is a combine() TypeError); `comparisons:` uses
   running-ng's label/a/b shape, translated by contract/native.py; a sweep must
   define its modifier (s/o/M/m are not in macro_base.yml). *)

type context = {
  request_id : string;
      (* Ours, not the contract's run_id (running-ng names the run directory itself);
         ties the config back to the queue row and request.json. *)
  base_include : string;
  machine : string;
  requested_by : string option;
  pr_url : string option;
  program_count : int;
  cell_seconds : float;
  cap_seconds : float;
}

type t = {
  config_yaml : string;
  env : (string * string) list;
  runtime_names : string list;
  configs : string list;
  tags : string list;  (* resolved; several tags select their union *)
  cost : Cost.t;
  warnings : string list;
}

(* Fixed on purpose: these size the runtime_events ring and olly's domain cap.
   A wrong ring size silently drops events, and `re`/`re_par` without a matching
   domain cap makes OCaml demand ~4 GB for the ring and abort.  Whether they
   belong in the config string is derived from the base config (modifier_chain). *)
let ring_log2 = 25
let max_domains = 2
let ring_log2_par = 22
let max_domains_par = 8

(* The modifier chain after the runtime, derived from the base config.
   Sequential `re`/`md` are emitted only when the base config does not declare
   `ocamlrunparam:` on its suites (since running-ng #15 the benchmarks that
   need them declare it, and emitting them would reinstate a global setting).
   Parallel `re_par`/`md_par`/`pin_lavyek` are emitted only when a suite that
   needs them has enabled programs: omitting them for an enabled lavyek suite
   makes wall_time go negative. *)
(* A token is a bare modifier name or name-value (`re-25`); the base config
   declares the name.  Names use underscores, never dashes, so a trailing
   `-<digits>` is always a value. *)
let modifier_name token =
  match String.rindex_opt token '-' with
  | Some i ->
    let suffix = String.sub token (i + 1) (String.length token - i - 1) in
    if Util.is_int suffix then String.sub token 0 i else token
  | None -> token

let modifier_chain (facts : Facts.t) =
  let sequential =
    if facts.uses_ocamlrunparam then []
    else
      [ Printf.sprintf "re-%d" ring_log2; Printf.sprintf "md-%d" max_domains ]
  in
  let parallel =
    if Facts.par_chain_suites facts <> [] then
      [
        Printf.sprintf "re_par-%d" ring_log2_par;
        Printf.sprintf "md_par-%d" max_domains_par;
        "pin_lavyek";
      ]
    else []
  in
  sequential @ parallel

(* Every refusal is an API A error envelope.  Everything is a bad command except
   the cost cap, which gets its own code so a client can tell "fix the
   spelling" from "shrink the request". *)
let err fmt = Api.error Api.Bad_command fmt
let ( let* ) = Result.bind

(* --- YAML emission ------------------------------------------------------- *)

let rule =
  "# =============================================================================\n"

let banner b title =
  Buffer.add_string b rule;
  Buffer.add_string b (Printf.sprintf "# %s\n" title);
  Buffer.add_string b rule

let quote s = "\"" ^ s ^ "\""
let flow_list items = "[" ^ String.concat ", " items ^ "]"

(* --- validation ---------------------------------------------------------- *)

let check_variants variants =
  let* () = if variants = [] then err "no runtimes to measure" else Ok () in
  let* () =
    List.fold_left
      (fun acc v ->
        match acc with
        | Error _ -> acc
        | Ok () -> (
          match Variant.validate v with
          | Ok () -> Ok ()
          | Error e -> err "%s" e))
      (Ok ()) variants
  in
  let names = List.map Variant.runtime_name variants in
  let uniq = List.sort_uniq compare names in
  if List.length uniq <> List.length names then
    err
      "Two runtimes resolve to the same name (%s). Give them distinct labels, or \
       drop the duplicate from `vs=`."
      (String.concat ", " names)
  else Ok names

let check_tag (facts : Facts.t) ~requested tag =
  let known = Facts.tag_names facts in
  match Facts.find_tag facts tag with
  (* A name we do know how to spell, for a tag the base config does not define,
     is almost always a branch mismatch rather than a typo -- so say that,
     instead of listing the alias the user just typed back at them. *)
  | None when List.mem requested Tag_alias.documented ->
    err
      "The base config does not define `%s` (from `tag=%s`). The service may be \
       reading a different branch of running-ng than you expect. Tags it does \
       define: %s."
      tag requested
      (String.concat ", " known)
  | None ->
    (* Suggest over both spellings: the friendly aliases the user was told
       about, and the raw tag names they may have copied from a config. *)
    let candidates = Tag_alias.documented @ known in
    err "Unknown benchmark set `%s`.%s Available: %s." requested
      (Util.suggest ~candidates requested)
      (String.concat ", " Tag_alias.documented)
  | Some t when t.gap ->
    err
      "`%s` is a coverage gap: no benchmark exercises it yet. See the `gap:` \
       notes in macro_base.yml."
      requested
  | Some _ -> Ok ()

let check_sweeps sweepable (sweeps : Request.sweep list) =
  let candidates = Vocab.keys sweepable in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | (s : Request.sweep) :: rest -> (
      match Vocab.find_any sweepable s.dimension with
      | None ->
        err "Cannot sweep `%s`.%s Sweepable parameters: %s." s.dimension
          (Util.suggest ~candidates s.dimension)
          (String.concat ", "
             (List.map
                (fun (d : Vocab.dim) ->
                  Printf.sprintf "`%s` (%s)" d.modifier d.dimension)
                sweepable))
      | Some d ->
        let bad = List.filter (fun v -> not (Util.is_int v)) s.values in
        if bad <> [] then
          err "`sweep=%s:` expects whole numbers; got %s." s.dimension
            (String.concat ", " (List.map (fun v -> "`" ^ v ^ "`") bad))
        else go ((d, s.values) :: acc) rest)
  in
  (* Two spellings of the same parameter (`o` and `space_overhead`) would emit a
     duplicate modifier definition, so collapse after resolution. *)
  let* resolved = go [] sweeps in
  let mods = List.map (fun ((d : Vocab.dim), _) -> d.modifier) resolved in
  let dup =
    List.filter (fun m -> List.length (List.filter (( = ) m) mods) > 1) mods
  in
  if dup <> [] then
    err "`sweep=` names the same parameter twice (`%s`)." (List.hd dup)
  else Ok resolved

let check_perf_modifier (facts : Facts.t) =
  if List.mem Request.perf_modifier facts.modifiers then Ok ()
  else
    err
      "The base config does not define `%s`, so no perf or olly metrics could be \
       collected. Available modifiers: %s."
      Request.perf_modifier
      (String.concat ", " facts.modifiers)

(* --- generation ---------------------------------------------------------- *)

let generate ~ctx ~(request : Request.t) ~(facts : Facts.t) ~sweepable ~variants =
  let* runtime_names = check_variants variants in
  let tags = Request.resolved_tags request in
  let* () =
    List.fold_left
      (fun acc (requested, tag) ->
        match acc with
        | Error _ -> acc
        | Ok () -> check_tag facts ~requested tag)
      (Ok ()) (Request.tag_pairs request)
  in
  let* sweeps = check_sweeps sweepable request.sweeps in
  let* () = check_perf_modifier facts in

  let invocations = Request.invocations_or_default request in
  let sweep_points =
    List.fold_left (fun acc (_, vs) -> acc * List.length vs) 1 sweeps
  in
  let configs_count = List.length variants * sweep_points in
  let cost =
    Cost.estimate ~cell_seconds:ctx.cell_seconds ~programs:ctx.program_count
      ~configs:configs_count ~invocations ()
  in
  let* () =
    if Cost.over_cap ~cap_seconds:ctx.cap_seconds cost && not request.force then
      Error
        {
          Api.code = Api.Over_budget;
          error_markdown = Cost.refusal ~cap_seconds:ctx.cap_seconds cost;
        }
    else Ok ()
  in

  (* Warnings are advisory and surface in the acknowledgement; none blocks. *)
  let warnings = ref request.warnings in
  let warn m = warnings := !warnings @ [ m ] in
  if List.length variants < 2 then
    warn
      "Only one runtime: no comparison will be declared, so the dashboard will \
       show absolute numbers rather than a base-vs-head delta.";
  List.iter
    (fun ((d : Vocab.dim), _) ->
      if List.mem d.modifier facts.modifiers then
        warn
          (Printf.sprintf
             "Sweeping `%s` redefines the base config's `%s` modifier; the \
              generated definition wins."
             d.dimension d.modifier))
    sweeps;
  if ctx.program_count = 0 then
    warn "The selection resolved to zero programs -- the run would do nothing.";
  if Cost.over_cap ~cap_seconds:ctx.cap_seconds cost then
    warn
      (Printf.sprintf "Over the %s limit, accepted because `force=true` was set."
         (Cost.human ctx.cap_seconds));

  let infra = modifier_chain facts in
  (* Every modifier we emit must exist in the base config, or the run dies at
     resolve time with an undefined-modifier error long after the request was
     accepted. *)
  let* () =
    match
      List.filter
        (fun m -> not (List.mem (modifier_name m) facts.modifiers))
        infra
    with
    | [] -> Ok ()
    | missing ->
      err
        "The base config does not define the measurement modifier(s) %s that \
         this benchmark selection requires. Available: %s."
        (String.concat ", " (List.map (fun m -> "`" ^ m ^ "`") missing))
        (String.concat ", " facts.modifiers)
  in
  if infra <> [] && not facts.uses_ocamlrunparam then
    warn
      "The base config does not declare per-benchmark `ocamlrunparam:`, so the \
       runtime_events settings are being passed in the config string \
       (pre-#15 behaviour).";
  List.iter
    (fun (s : Facts.suite) ->
      warn
        (Printf.sprintf
           "Suite `%s` is enabled and needs the parallel runtime_events \
            modifiers, so `re_par`/`md_par`/`pin_lavyek` were added to every \
            config."
           s.name))
    (Facts.par_chain_suites facts);
  let configs =
    List.map
      (fun v ->
        String.concat "|"
          ((Variant.runtime_name v :: [ Request.perf_modifier ]) @ infra))
      variants
  in

  let baseline =
    match
      List.find_opt (fun v -> v.Variant.role = Variant.Baseline) variants
    with
    | Some v -> v
    | None -> List.hd variants
  in
  let candidates =
    List.filter
      (fun v -> Variant.runtime_name v <> Variant.runtime_name baseline)
      variants
  in

  let b = Buffer.create 4096 in
  banner b "Generated by ocaml-bench-service -- do not edit by hand";
  let line fmt =
    Printf.ksprintf
      (fun s ->
        Buffer.add_string b (if s = "" then "#\n" else "# " ^ s ^ "\n"))
      fmt
  in
  line "request_id:   %s" ctx.request_id;
  line "command:      %s" (Util.trim request.raw);
  (match ctx.pr_url with Some u -> line "pull request: %s" u | None -> ());
  (match ctx.requested_by with Some u -> line "requested by: %s" u | None -> ());
  line "machine:      %s" ctx.machine;
  line "benchmarks:   %s (%d programs)"
    (String.concat ", " (List.map Tag_alias.friendly tags))
    ctx.program_count;
  line "estimate:     %s" (Cost.explain cost);
  line "";
  line "Runtimes:";
  List.iter
    (fun v ->
      line "  %-24s %-14s %s" (Variant.runtime_name v)
        (Variant.role_string v.Variant.role)
        (Variant.describe v))
    variants;
  Buffer.add_string b rule;
  Buffer.add_char b '\n';

  Buffer.add_string b "includes:\n";
  Buffer.add_string b (Printf.sprintf "  - %s\n\n" (quote ctx.base_include));

  Buffer.add_string b "overrides:\n";
  Buffer.add_string b (Printf.sprintf "  invocations: %d\n\n" invocations);

  banner b "Runtimes";
  Buffer.add_string b "runtimes:\n";
  List.iter
    (fun v ->
      Buffer.add_string b
        (Printf.sprintf "  %s:\n    type: OCaml\n" (Variant.runtime_name v));
      List.iter
        (fun (k, value) ->
          Buffer.add_string b (Printf.sprintf "    %s: %s\n" k (quote value)))
        (Variant.yaml_fields v);
      (* the sha's home when it is not the default compiler repo: a fork
         PR's head exists only on the fork *)
      (match v.Variant.repo with
      | Some url ->
        Buffer.add_string b (Printf.sprintf "    repo: %s\n" (quote url))
      | None -> ());
      (* running-ng passes this list to `opam compiler create
         --configure-command "./configure <args>"`. *)
      if v.Variant.configure_args <> "" then
        Buffer.add_string b
          (Printf.sprintf "    configure_args: %s\n"
             (flow_list
                (List.map quote (Util.tokens v.Variant.configure_args)))))
    variants;
  Buffer.add_char b '\n';

  if sweeps <> [] then begin
    banner b "Modifiers -- swept GC parameters (not defined in the base config)";
    Buffer.add_string b "modifiers:\n";
    List.iter
      (fun ((d : Vocab.dim), _) ->
        Buffer.add_string b
          (Printf.sprintf "  %s:\n    type: OCamlRunParam\n    val: %s   # %s\n"
             d.modifier
             (quote (d.modifier ^ "={0}"))
             d.dimension))
      sweeps;
    Buffer.add_char b '\n'
  end;

  banner b "Configs";
  Buffer.add_string b "configs:\n";
  List.iter
    (fun c -> Buffer.add_string b (Printf.sprintf "  - %s\n" (quote c)))
    configs;
  Buffer.add_char b '\n';

  if sweeps <> [] then begin
    Buffer.add_string b "config_sweep:\n";
    List.iter
      (fun ((d : Vocab.dim), values) ->
        Buffer.add_string b
          (Printf.sprintf "  %s: %s\n" d.modifier (flow_list values)))
      sweeps;
    Buffer.add_char b '\n'
  end;

  (* validate() requires every runtime in `configs:` to appear in some
     comparison and vice versa, so the block is emitted only when there is a
     real pair to compare. *)
  if candidates <> [] then begin
    banner b "Comparisons";
    Buffer.add_string b "comparisons:\n";
    Buffer.add_string b
      (Printf.sprintf "  - label: %s\n"
         (quote
            (Printf.sprintf "%s -> %s" (Variant.runtime_name baseline)
               (String.concat ", " (List.map Variant.runtime_name candidates)))));
    Buffer.add_string b
      (Printf.sprintf "    a: %s\n" (Variant.runtime_name baseline));
    Buffer.add_string b
      (Printf.sprintf "    b: %s\n"
         (flow_list (List.map Variant.runtime_name candidates)))
  end;

  (* Machine-independent env only: paths are the agent's; bench-gen appends its
     own dev-local ones when printing a by-hand recipe. *)
  let env =
    [
      (* Reuse is the service's policy: the switch is the compiler cache and a
         rebuild costs 10-20 min per runtime.  Correctness comes from the
         runner's switch-provenance check, not from rebuilding blindly. *)
      ("RUNNING_REUSE_SWITCHES", "1");
      (* Comma-separated: apply_tag_filter unions the named tags. *)
      ("RUNNING_TAG", String.concat "," tags);
    ]
  in
  Ok
    {
      config_yaml = Buffer.contents b;
      env;
      runtime_names;
      configs;
      tags;
      cost;
      warnings = !warnings;
    }
