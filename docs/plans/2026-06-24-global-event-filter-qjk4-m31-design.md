# GET /global/event filter-before-queue (qjk4 M3.1, CORRECTED handler): design + verdict

**Date:** 2026-06-24
**Author:** swarm worker (qjk4 / M3.1 territory)
**Round constraint:** DESIGN/VERIFY ONLY — no implementation, no patch edits, no beads, no commits.
**Supersedes the targeting of:** `docs/plans/2026-06-23-event-fanout-verdict-design.md`
(that doc designed the fix against `handlers/event.ts` = `/event`, which real clients
do **not** use). This doc re-points M3.1 at the handler real clients actually hold open:
`handlers/global.ts` = `/global/event`.

---

## TL;DR

- **The hot path is `GET /global/event`, not `GET /event`.** The deployed `/event`
  `?session_ids=` filter (event-session-scope + event-cold-start-directory patches) is
  dead weight: the TUI never connects to `/event`. Proof: SDK `sdk.global.event()` →
  `/global/event` (`sdk.gen.ts:1265-1269`); the deployed serve log shows `global event
  connected ×1109` vs plain `event connected ×1`.
- **`/global/event` has ZERO filter.** Every published `GlobalEvent` is offered to every
  client's queue and serialized per client (`handlers/global.ts:36-42`). This is the
  O(N×M) amplification M3 was about, and it is currently 100% un-mitigated for real
  clients (only structurally bounded by the K-serve pool capping N per serve).
- **A `?session_ids=` filter on `/global/event`, evaluated inside the `GlobalBus.on`
  callback (before `Queue.offerUnsafe`), removes the N× *serialization* amplification on
  the hot serve** (the expensive part: JSON.stringify + SSE encode per client), while the
  EventEmitter's O(N) listener iteration remains as an unavoidable floor.
- **Forward/backward compatible**: an old client (no param) → server forwards all (today's
  behavior); a new client param against an old server → unknown query param ignored. The
  only real risk is *correctness of the session_ids set* (child/sub-sessions).
- **Recommendation: DEFER (design-ready, ship-on-trigger).** The catastrophic single-core
  storm is already defused by the pool (iwpj/serve-lease); there are zero production
  `MaxListenersExceededWarning`s today; and shipping requires a *coordinated 3-part change*
  (server + generated SDK + TUI) whose correctness hinges on an unresolved question (what
  is the complete set of sessionIDs a TUI renders?). Keep iwpj (load distribution) as the
  primary lever — it cuts the O(N) floor too, which M3.1 cannot. Hold M3.1 fully specified
  and deploy it in <1 day **if** a hot serve is measured stalling on `/global/event`
  serialization.

---

## 1. Why does the TUI use `/global/event` instead of the filtered `/event`?

Both endpoints exist and consume **different event sources**:

| | `/event` (`handlers/event.ts`) | `/global/event` (`handlers/global.ts`) |
|---|---|---|
| Source | `EventV2Bridge.Service` (`events.listen`) — one **instance's** EventV2 stream | `GlobalBus` (Node `EventEmitter`) directly |
| Event shape | flat `EventV2.Payload` `{ id, type, properties }` | `GlobalEvent` `{ directory, project, workspace, payload:{id,type,properties} }` |
| Scope | single instance (needs resolved `instance.directory`); directory/workspace-scoped | **all instances on that serve** + genuinely global lifecycle events |
| Filter today | `?session_ids=` + directory (post-queue `Stream.filter`) | **none** |
| Global lifecycle | only `server.instance.disposed` (via a side GlobalBus sub-stream) | `installation.updated`, `server.instance.disposed`, `workspace.status`, `project.*`, `worktree.*` natively |

The TUI needs three things only `/global/event` provides:

1. **The per-event location envelope `{ directory, project, workspace }`.** `useEvent()`
   (`tui/src/context/event.ts:12-19`) hands every consumer `metadata:{directory,workspace}`.
   `data.tsx` uses `metadata.directory`/`metadata.workspace` to refresh model/provider
   catalogs on `catalog.updated` (`context/data.tsx:124-129`); `project.tsx` routes
   `workspace.status` by `properties.workspaceID` (`context/project.tsx:70-73`). The flat
   `/event` payload carries **no** per-event directory/workspace, so the TUI's metadata
   plumbing would break on `/event`.

2. **Genuinely global events that never flow through a single instance's EventV2 stream.**
   `installation.updated` is emitted *directly* to GlobalBus by the upgrade handler
   (`handlers/global.ts:119-125`); `server.instance.disposed` is emitted with
   `directory:"global"` (`server/global-lifecycle.ts:6-14`); `workspace.status` /
   `project.*` / `worktree.*` are emitted straight to GlobalBus by the control plane and
   worktree code (`GlobalBus.emit` sites: `control-plane/workspace.ts`, `worktree/index.ts`,
   `project/project.ts`, `project/instance-store.ts`). The TUI consumes several of these:
   `installation.update-available`/`installation.updated` (`app.tsx:1010`), `workspace.status`
   (`project.tsx`), `tui.command.execute` / `tui.toast.show` / `tui.session.select`
   (`app.tsx:964-985`).

3. **A cross-instance view.** Under HRW session sharding a single serve can own several
   sessions/directories (e.g. a swarm coordinator colocated with workers). `/event` is
   single-instance-scoped; `/global/event` carries all of that serve's sessions, which the
   TUI stores keyed by `sessionID` in `data.tsx` (the experimental-workspaces / sub-session
   model relies on this).

**Is `/event` sufficient? No.** Not without restructuring `/event` to (a) attach the
location envelope per event and (b) multiplex the global lifecycle events. The TUI
genuinely needs the global stream. So the fix must filter `/global/event` in place — we
cannot just migrate the TUI to the already-filtered `/event`.

**Does the TUI filter client-side?** No meaningful pre-filter. `handleEvent`
(`context/sdk.tsx:76-88`) only batches (16 ms coalescing) and fans out to handlers;
`useEvent()` drops only `payload.type === "sync"` and dispatches everything else by type.
Per-session routing happens *downstream* (`data.tsx` stores by `event.properties.sessionID`).
So today every colocated session's every event is serialized by the serve, shipped over the
wire, parsed by the TUI, and only then bucketed — N× wasted serialize + ship for the N−1
clients that don't render that session.

---

## 2. Filter protocol design (server + SDK + TUI)

### 2.1 Server — `handlers/global.ts`, filter inside the `GlobalBus.on` callback

The single hot line today:

```ts
// handlers/global.ts:36-42
const events = Stream.callback<GlobalBusEvent>((queue) => {
  const handler = (event: GlobalBusEvent) => Queue.offerUnsafe(queue, event)   // NO FILTER
  return Effect.acquireRelease(
    Effect.sync(() => GlobalBus.on("event", handler)),
    () => Effect.sync(() => GlobalBus.off("event", handler)),
  )
})
```

Proposed shape (filter-before-queue, session-scoped, yl00-safe):

```ts
// parse once, before opening the stream
const searchParams = yield* HttpServerRequest.ParsedSearchParams
const raw = searchParams["session_ids"]
const sessionIds = raw !== undefined
  ? new Set((Array.isArray(raw) ? raw.join(",") : raw).split(",").map(s => s.trim()).filter(Boolean))
  : undefined

const shouldForward = (event: GlobalBusEvent) => {
  if (sessionIds === undefined) return true                       // unfiltered (today's behavior)
  const sid = (event.payload?.properties as Record<string, unknown> | undefined)?.["sessionID"]
  // Session-scoped events: gate on membership. Globally-unique sessionID, so it
  // cannot leak another session, and it is directory-INDEPENDENT → immune to the
  // yl00 cold-start directory-resolution race (do NOT add a directory clause).
  if (typeof sid === "string") return sessionIds.has(sid)
  // Non-session events (installation.updated, server.instance.disposed,
  // workspace.status, project.*, worktree.*, sync, …) are low-frequency global
  // lifecycle: ALWAYS forward to preserve the global character of this stream.
  return true
}

const events = Stream.callback<GlobalBusEvent>((queue) => {
  const handler = (event: GlobalBusEvent) =>
    shouldForward(event) ? Queue.offerUnsafe(queue, event) : undefined
  return Effect.acquireRelease(
    Effect.sync(() => GlobalBus.on("event", handler)),
    () => Effect.sync(() => GlobalBus.off("event", handler)),
  )
})
```

Design rules (and why):

- **session_ids only; no `directory` param.** The `/event` design had to fall back to
  directory scoping for non-session events; for `/global/event` we instead **always
  forward** non-session events. This (a) keeps the stream's global semantics intact —
  cross-directory lifecycle events the TUI needs (installation, workspace.status) are never
  dropped — and (b) sidesteps the yl00 directory-race entirely. This is a *cleaner* story
  than the `/event` filter, not just a port of it.
- **`server.connected` / `server.heartbeat` are synthesized in the stream**
  (`handlers/global.ts:45,49`), not emitted on the bus, so they are unaffected by the
  filter — always delivered.
- **Filter is the *only* place to add scope.** The existing `disposed` detection lives in
  `handlers/event.ts`; `/global/event` already carries `server.instance.disposed` as a
  normal non-session event, so it is preserved by the "always forward non-session" rule.

### 2.2 SDK — `@opencode-ai/sdk` v2 (generated, in-tree at `packages/sdk/js/src/v2`)

`Global.event()` today:

```ts
// sdk.gen.ts:1265-1269
public event<ThrowOnError extends boolean = false>(options?: Options<never, ThrowOnError>) {
  return (options?.client ?? this.client).sse.get<...>({ url: "/global/event", ...options })
}
```

Two facts settle the "can we add the param without regenerating the SDK?" question:

1. **Runtime: yes, already works.** `event()` spreads `...options` into `sse.get`, which
   runs `beforeRequest → buildUrl(opts)`, and `buildUrl` serializes `opts.query` into the
   URL (`client/utils.gen.ts:146-154` → `getUrl`). So at runtime
   `sdk.global.event({ signal, sseMaxRetryAttempts:0, query:{ session_ids:"a,b" } })`
   already produces `GET /global/event?session_ids=a,b`. No regen, no SDK edit needed for
   the wire behavior.
2. **Types: `query` is omitted.** `Options<never, …>` resolves to
   `OmitKeys<RequestOptions, "body"|"path"|"query"|"url">` (`client/types.gen.ts:196-202`),
   so `query` is **not** an allowed key. A plain `{ query: … }` won't typecheck.

Two ways to bridge the type gap:

- **Option B (minimal, no SDK change): cast at the one call site.** In `context/sdk.tsx`,
  pass `query` through a localized cast. Zero generated-file churn; the coupling lives
  entirely in the TUI. Downside: bypasses the generated type (slightly fragile, but the
  runtime contract is stable and covered by `buildUrl`).
- **Option A (cleaner, edits one generated method): give `event()` a typed parameter.**
  Mirror `Event.subscribe()` (`sdk.gen.ts:1320-1343`), which already takes
  `parameters?: { directory?; workspace? }` and maps them via `buildClientParams([...],
  [{ args:[{ in:"query", key:"directory" }, …] }])`. Add `parameters?: { session_ids?:
  string }` to `Global.event()` and a matching `{ in:"query", key:"session_ids" }`. This is
  a hand-edit to a `// auto-generated` file — durable enough as a patch, but it will need
  re-application if the SDK is ever regenerated from the OpenAPI spec. To make it
  *regenerable*, also add `session_ids` to the `/global/event` endpoint's query schema in
  `groups/global.ts` so a future `openapi-ts` run reproduces it.

**Recommended:** Option A's *server schema* change (so the param is first-class in the spec)
plus Option A's generated-method edit, OR — if minimizing generated-file churn matters more
— Option B's cast. Either ships the same wire request.

### 2.3 TUI — `context/sdk.tsx`, pass the session id

```ts
// in startSSE().open, where it currently calls sdk.global.event({signal, sseMaxRetryAttempts:0})
return sdk.global.event({
  signal,
  sseMaxRetryAttempts: 0,
  ...(props.sessionID ? { query: { session_ids: sessionIdsForFilter() } } : {}),
})
```

`sessionIdsForFilter()` must return **every** sessionID the TUI renders (see §5 open
question). At minimum `props.sessionID`. Only attach the param when `props.sessionID` is
set, so non-session TUIs / tools keep the unfiltered stream.

### 2.4 Compatibility & rollout

- New server + old client: client sends no `session_ids` → `shouldForward` returns `true`
  for all → **identical to today**. Safe.
- Old server + new client: `session_ids` is an unknown query param → ignored → unfiltered.
  Safe.
- New server + new client: filtered. The *only* hazard is an **incomplete** session_ids set
  silently dropping events the TUI needs (child sessions) — a correctness bug, not a compat
  bug. This is the gating risk (§5).

---

## 3. The EventEmitter O(N) floor, and what the filter actually buys

`GlobalBus` is a Node `EventEmitter` (`bus/global.ts:11-22`). `emit("event", e)`
**synchronously iterates every registered listener** regardless of any filter. Listeners on
a serve = one per `/global/event` client (`handlers/global.ts:39`) + one `disposed`
listener per `/event` client (`handlers/event.ts:84`). So:

```
per published event:  O(N) listener invocations            ← UNAVOIDABLE FLOOR (filter can't remove it)
                    + O(N) Queue.offerUnsafe + SSE serialize ← what the filter removes for non-matching clients
```

The filter changes the **second** term only. For a session-scoped event watched by `m`
clients (typically `m = 1`, the owning TUI):

| | per session-scoped event | dominant cost |
|---|---|---|
| Today | N × (cheap listener call + **offer + JSON.stringify + Sse.encode + encodeText**) | the serialize, ×N |
| With filter | N × (cheap listener call + `Set.has(sid)`) + **m** × (offer + serialize) | the serialize, ×m |

The expensive work — `JSON.stringify(eventData(...))` + `Sse.encode` per client, which is
what spins the single event loop on a hot serve — drops from **×N to ×m**. The cheap floor
(N function calls + N `Set.has`) remains.

### Worked estimate (the M3 scenario: ~16 TUIs + ~16 busy sessions on one serve)

Assume 16 busy sessions each emitting streaming `message.part.updated` at ~50 ev/s ⇒
~800 session-events/s on that serve's bus, N≈16 SSE clients:

- **Today:** ~800 × 16 ≈ **12,800 serialize+offer ops/s** (the amplification that stalls
  the loop).
- **With filter (m≈1):** ~800 × 1 ≈ **800 serialize ops/s** + a 12,800-iteration/s cheap
  floor (function call + `Set.has`). ⇒ ~**16× reduction in the expensive work**, floor
  stays.

### M3.1 vs load-distribution (iwpj) vs M3.3

- **iwpj (HRW load distribution)** spreads clients/sessions across K serves, shrinking both
  N **and** M per serve by ~K ⇒ it attacks the **floor too**, and is the only lever that
  does. But it cannot help a serve that is *unavoidably* hot (a coordinator + its workers
  HRW-colocated by sessionID hashing onto one serve).
- **M3.1** does nothing for the floor but kills the N× serialize amplification on
  *whichever* serve ends up hot. **Complementary to iwpj, not redundant.**
- **M3.3 (`setMaxListeners(0)`, already shipped, `bus/global.ts:31`)** is orthogonal: it
  only silences the false-positive `MaxListenersExceededWarning`; it changes no fan-out cost.

**Is M3.1 obviated by iwpj + M3.3?** Not fully. iwpj reduces the floor but a colocated swarm
can still pin one serve; M3.1 is the surgical fix for exactly that residual. But the
residual is *hot-serve-only* and currently *unobserved* in production.

---

## 4. Patch shape

Three coupled pieces; client+server must ship together (compat-safe either direction, §2.4):

1. **`global-event-session-scope.patch`** (new) — edits
   `handlers/global.ts` (parse `?session_ids=`, add `shouldForward`, gate the
   `GlobalBus.on` callback) and `groups/global.ts` (declare the `session_ids` query param on
   the `event` endpoint so it is spec-first and regenerable). Self-contained; applies after
   base; independent of the `/event` patches.
2. **SDK param** — either fold into the same patch (edit `sdk.gen.ts` `Global.event()` to
   take `parameters?: { session_ids?: string }` à la `Event.subscribe`) **or** skip the SDK
   edit and use the TUI cast (Option B). Prefer the spec+generated edit so types are honest.
3. **`tui` change** — fold into the same patch or a sibling: `context/sdk.tsx` passes
   `query.session_ids` when `props.sessionID` is set.

Naming/scope note: keep this **separate** from `event-session-scope.patch` /
`event-cold-start-directory.patch` — those own the (unused) `/event` filter and two beads
(qjk4 + yl00) already depend on them. A fresh `global-event-session-scope.patch` avoids
disturbing that dependency surface.

---

## 5. Test strategy

Mirror `test/server/httpapi-event.test.ts` (the `/event` `?session_ids=` suite,
lines ~118-230), retargeted at `/global/event`:

1. **Filters foreign session events, delivers watched ones.** Two sessions A,B; subscribe
   `/global/event?session_ids=A`; emit session-scoped events for A and B on GlobalBus;
   assert only A's arrive.
2. **Always-forward for non-session lifecycle.** With `?session_ids=A` active, emit
   `installation.updated`, `server.instance.disposed`, `workspace.status` (no
   `properties.sessionID`); assert all are delivered. This is the rule that protects
   app.tsx / project.tsx.
3. **Empty `session_ids`** (`?session_ids=`) ⇒ no session events but lifecycle still flows
   (note: differs from `/event`'s "block all" because non-session always-forwards).
4. **No param ⇒ unchanged behavior** (everything forwarded) — the back-compat guarantee.
5. **yl00 regression:** emit a watched session's event whose `directory` differs from the
   subscriber's instance directory; assert it is **still delivered** (session_ids is
   directory-independent; no directory clause was added).
6. **TUI-level (optional):** a `context/sdk.tsx` test asserting the request URL carries
   `session_ids` only when `props.sessionID` is set.

---

## 6. Recommendation: DEFER (design-ready, ship-on-trigger)

**Ship M3.3:** already shipped (`bus/global.ts:31`). Nothing to do.

**M3.1: DEFER, but keep this design ready to deploy in <1 day.** Rationale:

For DEFER:
- The **catastrophic** O(N×M) single-core storm is already structurally defused by the pool
  (serve-lease HRW + attach-route-resolve); the residual is **hot-serve-only**.
- **Zero** production `MaxListenersExceededWarning`s and no observed `/global/event` stall
  post-pool ⇒ the failure mode is currently *theoretical*, not biting.
- Shipping is a **coordinated 3-part change** (server + generated SDK + TUI), more surface
  than the dormant benefit justifies right now, and the SDK piece edits a generated file.
- **iwpj is the better primary lever** — it reduces the O(N) *floor*, which M3.1 cannot.
- The gating correctness question (§5 / open question below) is unresolved; shipping a
  naive `session_ids = {props.sessionID}` filter risks dropping child/sub-session events.

For "keep ready / don't close":
- Correctly targeted at `/global/event`, the win is **real and larger than the prior doc
  implied** — that doc fixed `/event`, which no client uses, so its win was literally zero
  for real traffic. This design is the *only* one that reduces real-client per-serve fan-out.
- It is **forward/backward compatible**, so it can be deployed on demand with low rollout
  risk the moment a hot serve is measured stalling.

**Concrete trigger to flip DEFER→SHIP:** a single serve observed with (a) ≥~10 concurrent
`/global/event` clients AND (b) event-loop lag / CPU spin correlated with
`message.part.updated` serialization (e.g. a swarm colocated by HRW). At that point, ship
the §4 patch.

---

## 7. Open questions

1. **(Gating) What is the complete set of sessionIDs a TUI must pass?** `data.tsx` stores
   events keyed by arbitrary `event.properties.sessionID` and renders the focused session
   **plus child/sub-sessions** (task tool, sub-agents). Filtering to only `props.sessionID`
   would drop child-session events and break sub-agent display. Options: (a) TUI enumerates
   descendants and refreshes `session_ids` when children spawn (needs a re-subscribe on
   change — the SSE stream's param is fixed at connect, so a new child ⇒ tear down + reopen
   with the new set); (b) server expands `session_ids` to include descendants
   (needs parent→child lookup on the serve, adds coupling); (c) fall back to
   directory/project scoping for the filter (simpler, but reintroduces the yl00 race for
   live session events). **This must be resolved before shipping.**

2. **SDK churn vs honesty:** accept the hand-edit to generated `sdk.gen.ts` + spec change in
   `groups/global.ts` (regenerable, typed), or keep the TUI cast (no generated churn, weaker
   types)? Leaning spec+generated for honesty, but it adds a regeneration-fragility surface.

3. **Re-subscribe cost on session-set change:** if the TUI must reopen the SSE stream every
   time its descendant set changes, does that reconnect churn (and the lyj0 connection-leak
   risk it already guards against in `sdk.tsx`) cost more than the fan-out it saves on a
   *non-hot* serve? Likely fine (child spawns are infrequent vs message deltas), but worth a
   measurement before shipping.

4. **Is a coarser, safer filter preferable?** A `project`/`directory`-scoped filter avoids
   the descendant-enumeration problem (children typically share the worktree) at the cost of
   the yl00 directory-race and less precision. Worth weighing against the session_ids
   approach if §7.1 proves expensive to solve.

---

## Appendix — key citations (v1.17.7 + applied patches, read in `/tmp/m31-design`)

- Hot path, no filter: `packages/opencode/src/server/routes/instance/httpapi/handlers/global.ts:36-42`
- Upgrade emits `installation.updated` to GlobalBus: `handlers/global.ts:119-125`
- GlobalBus = Node EventEmitter, M3.3 `setMaxListeners(0)`: `packages/opencode/src/bus/global.ts:11-31`
- `/event` `?session_ids=` filter (post-queue) + yl00 note: `handlers/event.ts:33-68`, `71-87`
- Session events published to GlobalBus with location: `packages/opencode/src/event-v2-bridge.ts:38-67`
- `server.instance.disposed` emitted `directory:"global"`: `packages/opencode/src/server/global-lifecycle.ts:6-14`
- Global event schema (no session_ids param today): `packages/opencode/src/server/routes/instance/httpapi/groups/global.ts:36-95`
- TUI SSE call site: `packages/tui/src/context/sdk.tsx:128-131` (`sdk.global.event({signal, sseMaxRetryAttempts:0})`)
- TUI consumes envelope metadata: `packages/tui/src/context/event.ts:12-19`; `context/data.tsx:124-129`; `context/project.tsx:70-73`; `app.tsx:964-985,1010`
- SDK `Global.event()` spreads `...options` into `sse.get`: `packages/sdk/js/src/v2/gen/sdk.gen.ts:1265-1269`
- SDK `Event.subscribe()` query-param precedent (`buildClientParams`): `sdk.gen.ts:1320-1343`
- `Options` omits `query`: `packages/sdk/js/src/v2/gen/client/types.gen.ts:196-202`
- `buildUrl` serializes `opts.query`: `packages/sdk/js/src/v2/gen/client/utils.gen.ts:146-154`
- `/event` test precedent for the suite: `packages/opencode/test/server/httpapi-event.test.ts:118-230`
