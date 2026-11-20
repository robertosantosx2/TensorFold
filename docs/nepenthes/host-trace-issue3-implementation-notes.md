# NEPENTHES host trace connector — implementation notes

This branch tracks the host-only request trace slice for issue #3. The accepted LEONES envelope and source profile are the contract; this document is subordinate to the LEONES INDEX.

## Proposed instrumentation boundary

- Request admission/dispatch in `zig/src/server/server.zig` is the per-request identity boundary. Assign a trace request ID per accepted HTTP request, not per connection or generated response.
- Keep-alive resets request-local state on `Conn.readRequest`; IDs must be renewed for each request.
- A dispatch-boundary event is the only lifecycle event justified at the current boundary. It must not be labelled request completion: routes may stream or continue background work after dispatch.
- The disabled feature gate should be checked before timestamp reads, field construction or queue interaction.
- Producers should submit fixed-size, privacy-safe records. Any contention/full condition should drop immediately and increment an accounting counter.
- Writer/lifecycle ownership must emit one terminal sink summary after draining; failures should be explicit, not silently repaired.

## Privacy

Do not capture request paths, bodies, prompts, completions, model/user input, API keys, key labels, authorization headers, peer addresses, environment values, or private error text. Static event labels and observed numeric status/error codes only.

## Evidence status

This note is design/audit work, not runtime acceptance. No build, tests, importer run, overhead measurement or hardware validation is claimed here.
