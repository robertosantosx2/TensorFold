# NEPENTHES host trace connector — implementation notes

This branch tracks the host-only request trace slice for issue #3. The accepted LEONES envelope and source profile are the contract; this document is subordinate to the LEONES INDEX.

## Proposed instrumentation boundary

- Request admission/dispatch in `zig/src/server/server.zig` is the per-request identity boundary. Assign a trace request ID per accepted HTTP request, not per connection or generated response.
- Keep-alive resets request-local state on `Conn.readRequest`; IDs must be renewed for each request.
- A dispatch-boundary event is the only lifecycle event justified at the current boundary. It must not be labelled request completion: routes may stream or continue background work after dispatch.
- The disabled feature gate should be checked before timestamp reads, field construction or queue interaction.
- Producers should submit fixed-size, privacy-safe records. Any contention/full condition should drop immediately and increment an accounting counter.
- Writer/lifecycle ownership must emit one terminal sink summary after draining; failures should be explicit, not silently repaired.

## Source findings (reviewed on `main`)

- `Conn.readRequest` is the keep-alive request reset point, but trace ID assignment must be tied to the logical request, not the persistent connection object.
- `Server.next_id` already serves response-ID generation. It is not yet proven to be a stable, independent trace identity namespace; avoid consuming/reusing it without a dedicated contract.
- `Server.dispatch` calls `routes.dispatch` and then closes unfinished response connections. This is a dispatch boundary only.
- `responses_background.Manager.start` spawns `Job.run` on a detached thread; `Manager.end` owns the job's end/storage/removal. Any background trace lifecycle must propagate a trace ID into the `Job` explicitly, or remain dispatch-only.
- The request journal is unsuitable as a trace sink because it may contain request bodies and is designed for a different privacy/retention contract.

## Privacy

Do not capture request paths, bodies, prompts, completions, model/user input, API keys, key labels, authorization headers, peer addresses, environment values, or private error text. Static event labels and observed numeric status/error codes only.

## Evidence status

This note is design/audit work, not runtime acceptance. No build, tests, importer run, overhead measurement or hardware validation is claimed here. The implementation remains blocked on establishing a host-tested bounded sink and trace-ID propagation that does not misrepresent response completion.
