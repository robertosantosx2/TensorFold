# NEPENTHES architecture for inference engines

**Status:** design contract for TensorFold 1.2.10; implementation not yet accepted.
**Scope:** one shared NEPENTHES core in LEONES and thin, engine-owned connectors.

## 1. Goal and non-goals

NEPENTHES observes inference runs without becoming part of the inference algorithm. It must provide one run bundle, one event vocabulary and one evidence pipeline for multiple engines. Engine-specific probes translate native lifecycle and accelerator operations into that shared contract.

The first TensorFold slice is opt-in observability only. It must not change token output, scheduling, cache policy, kernel selection, arithmetic, driver state or CUDA synchronization. It adds no mandatory runtime dependency and does not require root.

## 2. Architecture

```text
                     NEPENTHES core (LEONES)
       run identity · wrapper · host telemetry · profiles
       bounded JSONL sink · manifest · hashes · reports
                            |
                versioned engine event contract
                            |
        +-------------------+-------------------+
        |                   |                   |
  Tandem.cpp connector  llama.cpp connector  TensorFold connector
  native probes/sink    native probes/sink   Zig server/CUDA probes
        |                   |                   |
        +-------------------+-------------------+
                            |
             optional NVTX + Nsight Systems evidence
                            |
        LEONES importers · correlation · AIPerf · reports
```

**Core (LEONES):**
- Owns run orchestration, `run_id`, host process sampling, device-wide telemetry, artifact manifests, SHA-256, verification, storage, comparison and report generation.
- Defines the canonical event schema, event vocabulary, profile semantics and correlation rules.
- Imports engine streams and Nsight data without silently upgrading inferred relationships to exact attribution.
- Reuses the existing CLI, AIPerf runner/evidence pipeline, Nsight SQLite importer, llama trace importer and report tools. It must not fork these into a TensorFold-only collector.

**Connector (inside each engine):**
- Owns native request identity and probes at safe lifecycle boundaries.
- Emits canonical events to the path supplied by the core; it does not create a second run manager, manifest, host sampler, report format or benchmark runner.
- Knows engine-specific operation names and maps them to stable event kinds plus bounded labels/values.
- Is disabled by default and has no per-operation instrumentation work when disabled.

**Evidence adapters (LEONES):**
- Convert each engine's native event stream to the canonical import model.
- Keep engine-native details in namespaced attributes or source-specific summaries; do not fork the common event envelope.
- Keep AIPerf request evidence, engine events and Nsight activity as distinct evidence sources joined only by explicit IDs and validated clock calibration.

## 3. Existing implementation to reuse

The following capabilities already exist in LEONES and are the implementation baseline, not a request to rewrite them:

| Existing capability | Reuse in the multi-engine design |
|---|---|
| `nepenthes run`, `NEPENTHES_RUN_ID`, `NEPENTHES_TRACE_JSONL` | Launch any supported engine and give its connector the run identity and event destination |
| Host CPU/RSS sampling and NVIDIA telemetry | Shared run-level telemetry, never attributed to a process/request unless measured |
| JSONL sink, run manifest, checksums and `nepenthes verify` | One bundle and integrity gate for every engine |
| Nsight SQLite inspection/import, including Nsight-only provenance | Shared GPU evidence path; preserve unknown/zero timestamps without fabricating durations |
| llama.cpp trace importer | First reference for request/event validation and explicit correlation semantics; generalize its engine-specific source checks before accepting TensorFold |
| Tandem.cpp universal event contract and probes | Reference for a reusable engine-side event sink and broad operation coverage |
| AIPerf 0.13.0 runner, evidence builder and overhead gates | Shared workload driver and measured performance/overhead receipts; engine adapters do not implement their own benchmark framework |
| OTLP export/transport and reports | Optional downstream export from canonical evidence, not a requirement for engine startup |

Important compatibility gap (verified against LEONES `main` on 2026-11-19): `scripts/nepenthes_llama_trace_import.py` requires `source == "llama.cpp"` for both ordinary events and `sink_summary`; it also restricts `clock_domain` to `steady_clock`. It is therefore not a generic multi-engine importer, and changing only the source field cannot make TensorFold traces acceptable. The required shared-validator work is tracked in [LEONES issue #207](https://github.com/robertosantosx2/LEONES/issues/207). That issue must extract a strict common envelope validator, register allowed connector identities explicitly, and retain source-specific semantics and llama.cpp compatibility. Do not work around this by pretending TensorFold events came from llama.cpp.

Tandem.cpp's existing work is a connector/reference implementation, not a second core. llama.cpp's current connector and AIPerf path are the second reference. Any differences between their actual event envelopes must be reconciled against repository code and fixtures before freezing the shared schema.

## 4. Canonical event envelope

The first compatible envelope is based on the fields already validated by the LEONES llama trace importer. It is deliberately small and contains no prompt, completion or token content.

Required event fields:

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | string | Canonical event schema version; initial compatible value `1.0` |
| `run_id` | non-empty string | One NEPENTHES run, shared with the manifest |
| `event_id` | non-empty string | Unique within the run and across all event streams after merge |
| `source` | string | Stable connector identity, e.g. `tensorfold`, `llama.cpp`, `tandem.cpp` |
| `timestamp_unix_ns` | unsigned integer | Wall-clock timestamp for cross-process display and calibration |
| `monotonic_ns` | unsigned integer | Monotonic timestamp in the declared host clock domain |
| `request_id` | unsigned integer | Engine request ID; zero means not associated with a request |
| `event_kind` | non-empty string | Stable common event kind |
| `label` | string | Bounded operation/backend label; no user text |
| `value0`, `value1` | unsigned integers | Event-specific numeric values with documented units |
| `duration_ns` | unsigned integer | Measured duration, or zero when this event has no measured duration |
| `flags` | unsigned 16-bit integer | Versioned, documented bit flags |

Optional fields:

- `correlation_token`: positive unsigned 64-bit token explicitly shared with an NVTX range or other evidence source.
- `attribution_level`: one of `exact`, `windowed`, `device_wide`, `estimated`.
- `clock_domain`: `steady_clock` for monotonic timestamps in the initial host contract.

Rules:
- An `exact` attribution requires a non-zero explicit `correlation_token`; a token is invalid with any other attribution level.
- A `windowed` attribution means only that an event lies inside a measured request window. It does not prove that the request caused the event.
- `device_wide` values (for example global GPU utilization) are not process or request measurements.
- `estimated` values must be labelled as estimates and must never be reported as measured.
- No request/kernel association may be inferred from temporal proximity alone.
- A final `sink_summary` record reports `events_drained`, `dropped_events` and `write_errors`; it must be the final record. Missing summary means incomplete capture unless an explicit interrupted-capture mode is selected.
- Reject duplicate event IDs, mixed run IDs, invalid identifiers, invalid integer ranges, unsupported schema versions, unexpected fields and privacy-forbidden text/token fields.

Example request lifecycle:

```json
{"schema_version":"1.0","run_id":"run-example-001","event_id":"tf-000001","source":"tensorfold","timestamp_unix_ns":1800000000000000000,"monotonic_ns":8100000000,"request_id":42,"event_kind":"request_start","label":"server.request","value0":128,"value1":0,"duration_ns":0,"flags":0,"clock_domain":"steady_clock"}
{"schema_version":"1.0","run_id":"run-example-001","event_id":"tf-000002","source":"tensorfold","timestamp_unix_ns":1800000000120000000,"monotonic_ns":8220000000,"request_id":42,"event_kind":"kernel_launch","label":"cuda.attention","value0":256,"value1":128,"duration_ns":0,"flags":0,"clock_domain":"steady_clock","correlation_token":9001,"attribution_level":"exact"}
{"schema_version":"1.0","run_id":"run-example-001","event_id":"tf-000003","source":"tensorfold","timestamp_unix_ns":1800000000500000000,"monotonic_ns":8600000000,"request_id":42,"event_kind":"request_end","label":"server.request","value0":64,"value1":64,"duration_ns":380000000,"flags":0,"clock_domain":"steady_clock"}
{"schema_version":"1.0","run_id":"run-example-001","event_id":"tf-summary-001","source":"tensorfold","timestamp_unix_ns":1800000000501000000,"event_kind":"sink_summary","events_drained":3,"dropped_events":0,"write_errors":0}
```

The numbers and operation labels above are illustrative fixtures, not measured TensorFold output. The example demonstrates the envelope only; production fixtures must be validated by the shared LEONES importer.

## 5. Event vocabulary and connector mapping

Common event kinds:

- Request lifecycle: `request_start`, `request_end`, `request_error`, `request_cancel`.
- Compute: `kernel_launch`, `kernel_complete` only when completion is actually observed.
- Memory: `alloc`, `free`, `memcpy`, `memset`, `oom`, `fallback`.
- Execution coordination: `sync`, `graph_capture_start`, `graph_capture_end`, `graph_instantiate`, `graph_launch`.
- Calibration and sink: `clock_calibration`, `sink_summary`.

A connector may emit only events for which it has an actual observation point. It must not manufacture completion events from launch return, infer an OOM from an allocation fallback, or describe an asynchronous submission duration as GPU execution time.

TensorFold 1.2.10 safe probe boundaries:

| TensorFold area | Candidate observation | Guardrail |
|---|---|---|
| `zig/src/server/server.zig` request dispatch/lifecycle | Request start/end/error and queue phases | Instrument each HTTP request, not each connection; keep-alive can carry multiple requests |
| `zig/src/cuda/launch.zig` / `abi.zig` | Kernel submission metadata and status | Submission is not kernel completion; no extra synchronization |
| `zig/src/cuda/memory.zig` | Existing allocation accounting and allocation failures | Prefer existing counters; do not double-count high-level and driver allocations |
| `zig/src/cuda/stream.zig` | Explicit stream/event operations | Do not add synchronization; `deinit` may already synchronize |
| `zig/src/cuda/graph.zig` | Capture, instantiate and launch boundaries | Record API operation boundaries, not assumed graph execution details |
| `zig/src/cuda/driver.zig` | Driver errors/status where already returned | Preserve native error codes and avoid additional driver calls |

These are candidate boundaries from the 1.2.10 source audit, not proof that probes have been implemented.

## 6. Profiles and disabled-path contract

The wrapper owns run-level sampling and chooses the profile. The connector reads only the resulting opt-in configuration.

| Profile | Engine connector behavior | Shared core behavior |
|---|---|---|
| `disabled` | No event emission; no per-operation clock reads, branches, locks or allocations on hot paths | No engine trace file; wrapper may still be used for ordinary process execution |
| `light` | Request lifecycle, errors and low-cost existing counters; bounded non-blocking sink | Standard host sampling; no Nsight unless explicitly requested |
| `diagnostic` | Detailed CUDA/API/graph/memory events; bounded sink and explicit NVTX tokens | High-frequency host sampling and optional Nsight capture |

Profile names are a connector contract, not a demand to rename LEONES' existing CLI profiles. The mapping from LEONES `smoke`, `standard`, `full`, `moe-deep` and `latency-critical` must be documented in one place in LEONES. A profile may not silently enable expensive probes in an engine that cannot honor its semantics.

The disabled path must be structurally cheap: a single initialization-time decision may select a no-op implementation, after which hot-path call sites do not read clocks, format labels, allocate, lock or write. The host test must verify zero emitted events and the implementation must include a code-level regression test for the no-op path.

## 7. NVTX, Nsight and clock correlation

- NVTX range names carry the run ID and an explicit correlation token; request ID is included only when the connector has a stable request identity.
- A token is allocated at the request/operation boundary and is emitted in both the engine JSONL and matching NVTX begin/end markers.
- The Nsight importer joins exact attribution only on that token and a validated run identity. It must retain unmatched events.
- Host monotonic-to-wall-clock calibration uses explicit paired calibration events. Nsight clock calibration is a separate conversion and must be supported by evidence from the capture; host calibration alone does not calibrate CUPTI timestamps.
- If calibration is absent or invalid, preserve source timestamps and report correlation unavailable. Never fit a conversion from arbitrary event proximity.

## 8. Privacy and bounded overhead

Never emit prompt text, generated text, token IDs, model inputs, API keys, environment dumps, local filesystem paths, private hostnames or user identifiers. Model/checkpoint identity is recorded only as a public revision or approved fingerprint in the run manifest, not copied into every event.

The sink must be bounded, non-blocking on inference threads and explicit about drops/write errors. It must not hold engine locks while performing file I/O. Event labels are static or drawn from bounded enums; no dynamically formatted request content.

No probe may add CUDA synchronization, host readback, device allocation, driver initialization or a mandatory dependency. Measure overhead with the existing AIPerf paired baseline/instrumented workflow before enabling diagnostic mode by default (which remains opt-in).

## 9. Host-only acceptance

Before any MSI/GPU work:

1. Validate schema and example fixtures with the same LEONES importer used for Tandem.cpp and llama.cpp.
2. Test missing/empty run IDs, event IDs, duplicate IDs, mixed run IDs, invalid request IDs/timestamps, unsigned boundaries, unknown event kinds, invalid attribution/token combinations and forbidden privacy fields.
3. Test request lifecycle balance and final sink summary, including drops, writer errors, interrupted traces and mismatched drain counts.
4. Test disabled mode emits no events and performs no hot-path instrumentation work.
5. Test the TensorFold connector's host-only build and no-CUDA configuration; GPU tests are not part of this contract slice.
6. Run the existing LEONES NEPENTHES suite and the existing TensorFold host suite on the exact PR head.
7. Record CI and host-test receipts. Do not describe them as physical inference or overhead measurements.

## 10. Delivery slices

Keep each engine/repository change isolated and stacked only where dependency requires it:

1. **Contract and importer generalization (LEONES + TensorFold docs):** freeze the shared envelope and fixtures; generalize source validation without weakening strict validation. No runtime probes.
2. **TensorFold core adapter (TensorFold):** opt-in configuration, no-op implementation, bounded sink integration and host tests. No CUDA instrumentation.
3. **TensorFold request lifecycle (TensorFold):** explicit per-request IDs and start/end/error/cancel events; host tests for concurrency and keep-alive.
4. **TensorFold CUDA connector (TensorFold):** add launch/memory/stream/graph observations in separate ATC-coordinated changes; no added synchronization.
5. **NVTX/Nsight bridge (TensorFold + LEONES):** explicit tokens and clock calibration, validated with synthetic host fixtures first.
6. **AIPerf and overhead acceptance (LEONES):** paired baseline/instrumented runs, then physical GPU qualification on authorized hardware.
7. **Documentation and release:** update LEONES engine matrix and TensorFold integration guide only after the corresponding acceptance gates pass.

Do not open one broad PR spanning the shared core, server, CUDA and Nsight layers. Follow TensorFold's one-change-per-PR and ATC area coordination rules; start each new implementation slice with its own issue/check/claim.

## 11. Current evidence boundary

This document is a design based on the current LEONES NEPENTHES implementation and the TensorFold 1.2.10 source audit. It does not claim a TensorFold connector, TensorFold event stream, CI pass, build, GPU capture or measured overhead exists. Those are separate acceptance gates.
