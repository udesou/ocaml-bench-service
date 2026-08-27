@0xc266ded9330dea06;

# API A over Cap'n Proto (Q15): one method per REQUEST_API function.
#
# Identity is the capability: a BenchApi reference is bound server-side to one
# GitHub login, so no method carries auth.  The role (user/admin) is derived
# from the server's config per call, never asserted by the client.
#
# v1 wire encoding: record payloads travel as the API A JSON encodings
# (lib/api.ml), one JSON document per Text field.  The capability model is
# capnp's; promoting payloads to capnp structs is an additive change later.
# Errors are the API A error envelope, JSON-encoded in the exception reason.

interface BenchApi {
  submit   @0 (command :Text, originJson :Text) -> (outcomeJson :Text);
  status   @1 (runId :Text) -> (statusJson :Text);
  events   @2 (runId :Text, since :Int32) -> (eventsJson :Text);
  cancel   @3 (runId :Text);
  # filter fields; "" means unset
  list     @4 (pr :Text, requester :Text, state :Text, machine :Text,
               family :Text, limit :Int32, after :Text) -> (metasJson :Text);
  help     @5 () -> (markdown :Text);
  vocab    @6 () -> (vocabJson :Text);

  # admin only (the server refuses by role)
  machines @7 () -> (machinesJson :Text);
  drain    @8 (machine :Text);
  undrain  @9 (machine :Text);
  requeue  @10 (runId :Text);
  # runtimeName "" evicts every cache on the machine
  evict    @11 (machine :Text, runtimeName :Text) -> (bytes :Int64);
  versions @12 () -> (versionsJson :Text);
  # target "" = bare bump: re-resolve the pin's tracked ref
  bump     @13 (component :Text, target :Text) -> (pinJson :Text);
}

# Held only by the PR bot (trusted infrastructure): the same submit, asserting
# the commenter's login, which the bot verified via GitHub.
interface BenchBot {
  submitAs @0 (login :Text, command :Text, originJson :Text) -> (outcomeJson :Text);
}

# API B (§6.2), held by one bench machine's agent: the capability IS the
# machine, so no method carries an identity.  The agent dials out (§6.4);
# every method here is called by the agent on the server.
interface AgentApi {
  # assignmentJson "" = nothing queued; poll again later
  claim        @0 () -> (assignmentJson :Text);
  # order: "continue" | "cancel" -- the control channel for a machine the
  # server cannot connect to
  heartbeat    @1 (runId :Text, execution :Int32, phase :Text) -> (order :Text);
  # eventsJson: JSON list of {seq, ts, body}; runId/execution are taken from
  # the authenticated arguments, never from the payload
  postEvents   @2 (runId :Text, execution :Int32, eventsJson :Text);
  upload       @3 (runId :Text, execution :Int32, path :Text, content :Data);
  finish       @4 (runId :Text, execution :Int32, resultJson :Text);
  reportCaches @5 (cachesJson :Text);
}
