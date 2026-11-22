# TensorFold NEPENTHES — GitHub reconciliation

**Cut-off:** 2026-11-22  
**Scope:** remote GitHub state only. No MSI checkout, local worktree, stash or uncommitted file was inspected or changed.

## Executive result

The upstream TensorFold #1879 Qwen3.5 CUDA lazy-scratch work is treated as **resolved/upstreamed** and is not part of this NEPENTHES reconciliation. The MSI residue from that separate workstream is not a recovery target by default.

The NEPENTHES host-only runtime connector is already merged into the fork's `main` through PR [#6](https://github.com/robertosantosx2/TensorFold/pull/6), closing [issue #3](https://github.com/robertosantosx2/TensorFold/issues/3). The current `main` head is `50f1a34cbc1f111fa6e7afbedc199eee0d8643e5`; the PR implementation head was `c258ec930b4ea8f0d0bc785a984d2114bf041fb9`.

**Remote code status: merged. Remote acceptance evidence: incomplete.** GitHub reports zero check runs and zero submitted reviews for the exact PR head. The PR description documents the intended host test coverage and says cross-repository validation was being rerun, but no CI result is exposed by the inspected GitHub endpoints. No CUDA/NVTX/Nsight, MSI runtime, performance or overhead acceptance is claimed.

## Canonical remote references

| Item | Ref / SHA | Result |
|---|---|---|
| Fork default branch | `main` → `50f1a34cbc1f111fa6e7afbedc199eee0d8643e5` | Contains the merged connector |
| Contract and shared-envelope design | `9355b0ab65c11e69ce127e0402d17f52d028f69c` | Ancestor of PR #6 merge |
| PR #6 | [NEPENTHES host-only request trace connector](https://github.com/robertosantosx2/TensorFold/pull/6) | Closed, merged 2026-11-20 |
| PR #6 exact implementation head | `c258ec930b4ea8f0d0bc785a984d2114bf041fb9` | Source of merged code |
| Issue #3 | [Implement host-only request trace connector](https://github.com/robertosantosx2/TensorFold/issues/3) | Closed 2026-11-20 |
| Shared importer contract | [LEONES PR #210](https://github.com/robertosantosx2/LEONES/pull/210), merge `fcaf17005f7771c2521fc07387409a79c47f1b7b` | Shared envelope gate recorded as merged in TensorFold docs |

## What the merged runtime contains

PR #6 changes the server-side request lifecycle and adds `zig/src/server/nepenthes_trace.zig` (407 lines), three importer fixtures, and server integration. The PR description records:

- Opt-in `NEPENTHES_TRACE_JSONL` + `NEPENTHES_RUN_ID`; incomplete configuration fails closed.
- Disabled mode avoids formatting, clock reads, allocations, locks and file I/O at instrumentation call sites.
- Bounded 256-record queue, non-blocking producer `tryLock`, dedicated writer and drained/drop/write-error accounting.
- Exactly one terminal `sink_summary` after queue drain.
- Unique logical request IDs at the HTTP dispatch boundary; keep-alive requests get distinct IDs.
- `dispatch_end` separates the HTTP boundary from logical completion.
- Detached Responses background work inherits the owning request ID and original start timestamp; `request_end` follows background completion.
- Cancellation is distinguished from failure; payload excludes prompt/completion/token content, request bodies, headers, API keys and private identifiers.

The merge diff reports ten changed paths: the NEPENTHES README, three fixtures, server CLI, HTTP connection, new trace sink, background responses, serve and server files.

## Remote branch reconciliation

| Branch | Head | Compare against `main` | Interpretation |
|---|---|---|---|
| `nepenthes/host-trace-connector-2` | `c258ec930b4ea8f0d0bc785a984d2114bf041fb9` | 16 ahead / 1 behind; diff is the PR #6 implementation | Historical PR head, already merged. Keep as provenance; no need to merge again |
| `nepenthes/host-trace-issue3` | `387faf889d283a55a70f2a5da156ab0b5d3dd74d` | 2 ahead / 1 behind; adds only `docs/nepenthes/host-trace-issue3-implementation-notes.md` against merge base | Notes-only branch, not the runtime implementation. Its two commits are not present in `main`; preserve until reviewed |
| `nepenthes/tensorfold` | `c42f7ac181577e33a9cc66455522b3e2541f7078` | 7 ahead / 2 behind; compare reports only a README change | Older documentation branch; not the implementation branch. Preserve until reviewed |

These branches are intentionally not deleted, rebased or force-updated. The branch compare counts include divergent ancestry; the file lists are the decisive evidence for the content delta.

## MSI ↔ GitHub coherence: what is and is not proven

The published MSI package-content audit and reconciliation matrix describe a TensorFold checkout used for the separate #1879/Qwen3.5 workstream, including a large modified working tree. That inventory does **not** establish the content or cleanliness of a distinct MSI checkout/worktree for the NEPENTHES runtime adaptation. It would be incorrect to equate the #1879 checkout snapshot with the NEPENTHES implementation state.

Therefore:
- GitHub has a canonical merged implementation: `main@50f1a34...`.
- The historical implementation branch is identifiable: `nepenthes/host-trace-connector-2@c258ec9...`.
- The two remaining branches are documentation deltas and are not alternate runtime implementations.
- MSI-side equality is **not yet evidenced** by the published audit snapshot. No local state is inferred, discarded or declared synchronized.

To close this last gap without terminal work, the MSI-side NEPENTHES-specific snapshot (branch/HEAD, worktree status, changed/untracked paths and content hashes for the NEPENTHES files) must be published as a separate evidence artifact in GitHub. Compare that artifact against `main@50f1a34...`; do not use the #1879 checkout's old 512/286 file counts as evidence about NEPENTHES.

## Guardrails

No local checkout was accessed. No branch was deleted, rebased, force-pushed or merged by this audit. No runtime code was changed in this reconciliation branch; the only proposed source change is documentation that corrects the stale status in `docs/nepenthes/README.md`.


## Follow-up evidence ticket

The remaining MSI-side snapshot is tracked in [issue #8](https://github.com/robertosantosx2/TensorFold/issues/8). It defines the read-only evidence fields, per-file SHA-256 comparison, privacy exclusions and non-destructive guardrails. Until that artifact is attached or committed to an audit branch, the MSI↔GitHub coherence result remains **unproven**, not failed and not assumed.
