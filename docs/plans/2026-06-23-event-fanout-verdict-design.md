# GET /event O(N×M) fan-out: verdict + minimal-fix design

**Date:** 2026-06-23
**Author:** swarm worker 2 (qjk4 territory)
**Round constraint:** DESIGN/VERIFY ONLY — no implementation, no patch edits.
**Scope:** the `/event` fan-out half of `workstation-qjk4` (M3.1 filter-before-queue,
M3.3 setMaxListeners). The ProjectCopy half (M3.2) is owned by worker 1.

---

## Verdict: RESIDUAL GAP (structurally defused, not eliminated)

The catastrophic single-core O(N×M) event storm from
`OPENCODE-SERVE-MULTICORE-INVESTIGATION.md §1.A` is **structurally defused** by the
K-serve pool, but the two handler-level fixes qjk4 scoped (M3.1 filter-before-queue,
M3.3 setMaxListeners) were **NOT implemented**. They remain real (if smaller and
currently-dormant) gaps.

### Evidence

**The deployed `/event` handler still offers every event to every client's queue.**
After `event-session-scope.patch` (#7) and `event-cold-start-directory.patch` (#11),
the listener line is byte-for-byte the base v1.17.7 line:

```ts
const unsubscribe = yield* events.listen((event) => Effect.sync(() => Queue.offerUnsafe(queue, event)))
```

Both the directory filter AND the `?session_ids=` filter run **post-queue**, inside
`Stream.fromQueue(queue).pipe(Stream.filter(...))`. The cold-start patch merely *merged*
the directory filter into the same post-queue `Stream.filter` and added session-aggregate
gating — it did not move anything ahead of the queue offer. So per published event, every
connected client still:
1. fires its `events.listen` callback (EventV2 keeps listeners in a plain array, iterated
   for all N on every publish — `core/src/event.ts:421`), and
2. allocates a `Queue.offerUnsafe`,
…and only *then* is the event filtered before SSE serialization. The doc's §5 Step 1
("filter **before** offering to the queue", reduce to O(M_local)) was **not done**.

**`?session_ids=` is DEPLOYED-BUT-UNUSED by real clients.** The TUI SSE path
(`tui/src/context/sdk.tsx`, via `attach-route-resolve.patch`) and the bash clients
(`oc-auto-attach`, `opencode-launch`) all use pigeon `GET /route` only to extract
`.apiBase` and *attach to the owning serve*; the actual subscription is a bare
`sdk.global.event({ signal, sseMaxRetryAttempts: 0 })` with **no** `session_ids` param.
The only `?session_ids=` occurrences in 1.1M log lines are manual `probe`/grep commands,
never TUI traffic. Session isolation is therefore achieved **structurally** (each serve is
a separate process whose in-memory GlobalBus only carries its own sessions' events), not by
the filter. The filter is dead weight on the hot path today — and being post-queue, it
wouldn't kill the fan-out even if clients did use it.

**`setMaxListeners` is never raised.** Zero `setMaxListeners` references in base v1.17.7 or
in any patch; `bus/global.ts` is unmodified (default limit = 10). Each `/event` client
registers one `GlobalBus.on("event")` listener for `server.instance.disposed` detection
(`event.ts` `disposed` sub-stream), so a single serve with ≥11 concurrent clients emits
`MaxListenersExceededWarning`. Live evidence: **0 occurrences in 1.1M log lines** → on the
current 4-serve pool (ports 4096–4099, confirmed running + pigeon) no single serve has hit
11 concurrent clients. The warning is **dormant, not fixed** — a serve owning 11+
sessions/TUIs would still emit it.

### Why the storm is defused (the structural win, for the record)

| | Pre-pool (the §1.A scenario) | Deployed K=4 pool |
|---|---|---|
| Processes / event loops | 1 | 4 (separate GlobalBus each) |
| N (clients per bus) | all TUIs (11–20+) | only that serve's owners (single digits) |
| M (events per bus) | events from all active sessions | only that serve's sessions' events |
| Fan-out work | O(N×M) on one core | ~O((N/K)×(M/K)) spread over K cores |

Worst-case fan-out drops ~K² *and* moves off the single hot core. That is the real reason
the production warning/CPU-spin is gone — `serve-lease.patch` (HRW session sharding) +
`attach-route-resolve.patch` (TUI → owning serve), **not** the `?session_ids=` filter.

---

## Minimal fix design (the two still-open qjk4 items)

Both are small, low-risk, and independent. Recommend shipping M3.3 unconditionally and
M3.1 as a cheap defense-in-depth for "hot serve" cases.

### M3.3 — `GlobalBus.setMaxListeners` (trivial, unambiguous)

`packages/opencode/src/bus/global.ts`, one line after construction:

```ts
export const GlobalBus = new GlobalBusEmitter()
GlobalBus.setMaxListeners(0) // 0 = unlimited; or 100 per the investigation doc
```

Rationale: the disposed-listener-per-client pattern is legitimate fan-out, not a leak. `0`
(unlimited) is preferable to `100` because a busy multi-session serve has a genuinely
unbounded client count and we never want this false-positive to mask a *real* leak warning
elsewhere. Matches doc §5 Step 2. New patch file (e.g. `globalbus-maxlisteners.patch`),
applied any time after base; touches only `global.ts`.

### M3.1 — move the existing predicate ahead of the queue offer (yl00-safe)

The key correctness constraint: do **not** re-introduce the yl00 cold-start directory race.
That race is already handled by the cold-start predicate (session-scoped subs gate on
session-aggregate membership, directory-independent). The fix is simply to evaluate that
**same** predicate in the `listen` callback instead of in a downstream `Stream.filter`:

```ts
const shouldForward = (event: EventV2.Payload) => {
  const sid = (event.data as Record<string, unknown> | undefined)?.["sessionID"]
  if (sessionIds !== undefined && typeof sid === "string") return sessionIds.has(sid)
  return matchesDirectory(event)
}
const unsubscribe = yield* events.listen((event) =>
  shouldForward(event) ? Effect.sync(() => Queue.offerUnsafe(queue, event)) : Effect.void,
)
// ...the downstream Stream.filter becomes redundant; drop it (or keep as defense-in-depth).
```

Why this is safe and sufficient:
- It is the **identical predicate** already in `event-cold-start-directory.patch`, just
  evaluated earlier — so yl00 semantics are preserved exactly (session subs stay
  directory-independent; non-session subs keep directory scoping they always had).
- Non-matching events no longer allocate a queue offer or wake the client's stream fiber →
  per-serve fan-out becomes O(M_local) instead of O(N_serve × M_serve). This matters for a
  *hot serve* (e.g. a swarm coordinator + workers colocated on one serve via HRW).
- The `disposed` GlobalBus sub-stream is a separate path and is untouched.

This would land as an edit to `event-cold-start-directory.patch` (it owns the final shape of
that block) **or** a new follow-on patch that must apply after it. No client change required.

---

## Open decision for the coordinator / human

M3.3 is unambiguous, ~free, and currently-dormant-but-unmitigated → recommend ship.

M3.1 is the judgment call: the pool already defuses the *catastrophic* case, so the
remaining win is bounded (hot-serve only) and the change, while small, edits a patch that
two beads (qjk4 + yl00) already depend on. Decision to escalate: **ship M3.1 now as cheap
insurance, or close qjk4-M3.1 as "obviated by the pool" and keep only M3.3?** I lean
ship-both (both are low-risk and qjk4 is still OPEN scoping all three), but the
"obviated by pool" close is defensible given zero production warnings today.

No implementation performed this round.
