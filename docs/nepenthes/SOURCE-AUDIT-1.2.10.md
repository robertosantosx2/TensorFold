# NEPENTHES — TensorFold 1.2.10 source audit

**Audit date:** 2026-11-19  
**Repository:** [robertosantosx2/TensorFold](https://github.com/robertosantosx2/TensorFold)  
**Branch:** [nepenthes/tensorfold](https://github.com/robertosantosx2/TensorFold/tree/nepenthes/tensorfold)  
**Baseline:** TensorFold 1.2.10; `build.zig.zon` declares Zig minimum 0.17.0.  
**Audit type:** remote source inspection only. No build, tests, runtime trace, GPU capture, or overhead measurement was executed.

This document records concrete source boundaries for the NEPENTHES connector. It does not claim that any instrumentation has been implemented.

## 1. Request lifecycle: correct instrumentation boundary

### Verified source

- `zig/src/server/http_conn.zig` — blob `3a02d3dc6f794ad1691489ba828df3d570a4c031`
  - `Conn.readRequest` resets request-scoped connection state for every parsed HTTP request, including `id`, `counted`, response completion and auth/key metadata.
  - The connection object persists across HTTP keep-alive requests. A connection identifier is therefore not a request identifier.
  - `StatusHook` is documented as firing once per request at its first final status (HTTP status >= 200); this is an existing observation point, not a full request lifecycle.
- `zig/src/server/routes.zig` — blob `820072b4a306ffda058e78c65974f8207e612c57`
  - `dispatch(srv, conn, allocator)` dispatches the current request by method and route.
  - `post` classifies the request route and sends it to the appropriate handler; streaming/background response paths may outlive the initial dispatch.
- `zig/src/server/server.zig` — blob `2a3009396f0b556ade74dc274a850eaa11d66579`
  - The server uses one thread per connection; `Server.next_id` and `Conn.id` are associated with response IDs (for example `chatcmpl-`, `cmpl-`, `speech-`, `images-`), not a proven stable NEPENTHES request identity.
- `zig/src/server/request_journal.zig` — blob `2a249f883834349e9e4ea5a587b8a5a13de638ca`
  - The optional request journal records request route/body-related recovery data and can serialize request content. It is not a telemetry sink and must not be reused for NEPENTHES.

### Design consequence

The connector must assign a distinct request ID at the per-request dispatch/admission boundary, not at connection accept and not by reusing response IDs without a separately proven one-to-one lifecycle. That identity must be carried explicitly through synchronous, streaming and background completion paths. Keep-alive must produce multiple request IDs on one connection. Request start/end/error/cancel semantics must be attached to the logical request, not to the lifetime of the HTTP socket.

Do not instrument raw request bodies, prompts, completions, authorization/key labels, client addresses or journal content.

## 2. CUDA launch and graph boundaries

### Kernel launch

- `zig/src/cuda/launch.zig` — blob `f280a0de070a4972a2b6727837b6dd4aa9552a2c`
  - `launch` validates launch geometry and calls `cuLaunchKernel` or `cuLaunchKernelEx`.
  - Successful return means submission was accepted; it does not mean the kernel completed.
  - The error path can identify the function/configuration, but adding a synchronization to time execution is prohibited.
- `zig/src/cuda/abi.zig` — blob `7c7d98a38e8b458f788768b989eb6eae81ed6283`
  - The loaded driver API surface includes kernel launch, memory allocation/free, H2D/D2H/D2D copies (sync and async), 2D async copies, stream/event operations and graph APIs.

### CUDA graphs

- `zig/src/cuda/graph.zig` — blob `e8881f3d2a30d93573786128f4f399fb36544224`
  - Existing explicit boundaries include `beginCapture`, `endCapture`, graph creation, kernel-node addition/update, `instantiate`, `upload` and `Exec.launchOn`.
  - A graph launch is a submission boundary, not per-node completion evidence.
  - Capture coordination already interacts with `copy_source.zig`; probes must preserve its guards and failure behavior.

### Streams and events

- `zig/src/cuda/stream.zig` — blob `173396519316f06cef9be4540fc8a8e4bfad87ba`
  - `Stream.synchronize` delegates to the existing stream synchronization helper.
  - `Stream.deinit` also synchronizes before destroying the stream. This is an existing teardown behavior, not an invitation to add synchronization to ordinary operations.
  - Event record/query/synchronize APIs are present; event synchronization is an explicit blocking boundary.

**Instrumentation rule:** record launch/graph submissions as host-observed submissions. Only record completion when an existing event/query or external Nsight/CUPTI evidence actually establishes completion. Never add a device/stream/event synchronization for telemetry.

## 3. Memory, copies and error paths

- `zig/src/cuda/memory.zig` — blob `3685228a93eba8947dc3798ed262831bdb19b820`
  - Existing atomic counters track device bytes, pinned-host bytes, peaks and live driver allocations.
  - `DeviceBuffer.alloc` delegates to `allocVia`; allocation reservation and accounting are protected by the existing counts mutex. Failed driver allocations refund reservations.
  - The optional `memory.Hook` is a suballocator ownership interface (alloc/free), not an observability callback. Do not commandeer it as the NEPENTHES sink.
  - Usage snapshots are aggregate counters; they are not a per-allocation event stream.
- `zig/src/cuda/abi.zig` — blob `7c7d98a38e8b458f788768b989eb6eae81ed6283`
  - The ABI declares synchronous/asynchronous H2D, D2H and D2D operations, 2D async copies, host allocation/registration and memset APIs. Each actual callsite must be mapped before claiming complete transfer coverage.
- `zig/src/cuda/driver.zig` — blob `2ee2d530d7c82308f4fa235800e392dda89716a0`
  - `Driver.result` routes non-success results through the existing context-health observer and maps them to engine errors. This is a viable error observation seam, but must not cause extra driver calls on the success path.

**Instrumentation rule:** distinguish allocation request, successful allocation, release, and failed allocation. Do not infer OOM from a generic fallback/error. Preserve native error codes. Do not double-count the high-level buffer counters and driver allocation calls. Copy events describe API submission/return, not transfer completion or GPU duration.

## 4. Existing telemetry that is not a substitute

- HTTP status counters/hooks are not full request lifecycle traces.
- The optional request journal is content-bearing and privacy-sensitive; it is not a safe telemetry source.
- CUDA memory usage counters are aggregate snapshots, not per-operation events.
- CUDA launch and graph calls expose host submission boundaries, not GPU execution duration.
- No NEPENTHES event sink, canonical JSONL producer, opt-in no-op connector, NVTX bridge or runtime correlation token was found in the audited source files.

## 5. Implementation order and gates

1. **LEONES #207 first:** extract the shared strict envelope validator and explicit source registry. Preserve llama.cpp compatibility; unknown sources must fail closed.
2. **TensorFold host connector:** add a disabled-by-default no-op path, bounded sink and source identity only after the ATC area/overlap check is complete. Add host-only tests for sink accounting, IDs, privacy, concurrency and disabled-path behavior.
3. **Request lifecycle:** add logical request IDs at the per-request boundary and propagate them through streaming/background completion; test multiple requests on one keep-alive connection.
4. **CUDA probes:** separate change slices for launch/graph, memory/copy and synchronization/error observations. No extra synchronization and no claim of GPU completion from host submission.
5. **NVTX/Nsight:** only explicit shared correlation tokens and validated clock mapping; keep unmatched activity and never correlate by temporal proximity.
6. **Host acceptance before hardware:** run TensorFold host tests and LEONES shared-importer fixtures on the exact PR head. Record actual CI receipts.
7. **Physical qualification later:** Nsight/CUPTI coverage and paired overhead measurements are a separate hardware gate; they are not established by this source audit.

## 6. Current conclusion

The source exposes suitable, bounded observation seams, but the logical request ID propagation and the NEPENTHES producer/sink do not yet exist. The most important request-level correction is to distinguish HTTP connections, logical requests and response IDs. The CUDA layer can initially report host-observed submissions and existing aggregate counters; it cannot truthfully report kernel completion or per-copy GPU duration without external evidence.

**Acceptance status:** design/source audit only; no implementation acceptance, CI pass, runtime capture, GPU validation or overhead result is claimed.
