# Client-side request timeout for `opencode attach` (bead workstation-yoa2)

**Status:** design-only (no code, no commits, no beads). Target upstream: opencode
**v1.17.7** + the opencode-patched set (read from a worktree with `patches/apply.sh`).

## Problem (defense-in-depth)

When an `opencode serve` event loop **stalls** (historically pinned by O(N×M) event
fan-out, or by the project-copy / step-end-diff CPU spins that other patches address),
the kernel still completes TCP handshakes into the listen backlog — the connections go
`ESTABLISHED` — but the app never `accept()`s and never writes a byte. The `opencode
attach` TUI's periodic **non-SSE REST requests** then hang as `ESTABLISHED`
connections and accumulate up to the **256 per-origin keep-alive pool cap**. This is
the traffic that was misdiagnosed as the "lyj0 0.9 conn/min growth" (lyj0 was a
*reconnect leak*, since fixed in `util/sse.ts`; yoa2 is the *stall hang-and-pile*).

A bounded **client-side** request timeout makes those hung requests **fail fast**
instead of piling up, so a stalled serve degrades gracefully: the TUI surfaces an
error and/or the SSE reconnect re-resolves via pigeon `/route` to a healthy serve.

### Hard constraints (a blanket `fetch` timeout is WRONG)

1. MUST NOT time out the long-lived SSE stream — `GET /global/event` is intentionally infinite.
2. MUST NOT break legitimately long operations — agent turns / tool calls / compaction can take minutes.
3. opencode/SDK runs on Bun `fetch`, which has **no default timeout**.

---

## What I read (applied source, file:line)

- `packages/tui/src/context/sdk.tsx:31-39` — `createSDK()` → `createOpencodeClient({ baseUrl, signal: abort.signal, fetch: props.fetch, headers })`. **One chokepoint**: `props.fetch` is the single fetch used for *all* SDK traffic (REST and SSE).
- `packages/opencode/src/cli/cmd/attach.ts:82-111` — the `attach` command calls `validateSession({url,...})` and `run({url,..., headers})` **without a `fetch`** prop → `props.fetch` is `undefined` → the SDK falls back to **global Bun `fetch`** for every REST call and the SSE stream. This is the path that hangs-and-piles.
- `packages/opencode/src/cli/cmd/tui.ts:157-202` — the in-process `tui` command instead passes `fetch: createWorkerFetch(client)` (an RPC bridge to a worker, **not** a network socket) or, in `--external` mode, `fetch: undefined`. The worker path is in-process and is **not** subject to the TCP backlog, so it must NOT get a network timeout.
- SDK v2 client (`@opencode-ai/sdk/dist/v2/gen/client/client.gen.js`):
  - REST: `request()` resolves the effective fetch as `options.fetch ?? _config.fetch ?? globalThis.fetch` (`:17`) and calls `await _fetch(request)` with a single `Request` object (`:48,:56-59`).
  - SSE: `makeSseFn()` (`:185-204`) spreads `...opts` (which carries the same `fetch`) into `createSseClient`.
- SDK v2 SSE (`.../gen/core/serverSentEvents.gen.js:33-34`): `const _fetch = options.fetch ?? globalThis.fetch; const response = await _fetch(request)`. **Same fetch as REST**, also called with a single `Request`. So a wrapper installed as the client `fetch` intercepts BOTH; SSE must be exempted by inspecting the request.
- SSE endpoints (`.../gen/sdk.gen.js`): `global.event` → `sse.get({ url: "/global/event" })` (`:72-74`); the session-scoped `event` → `sse.get({ url: "/event" })` (`:2120-2121`). The attach TUI only opens `/global/event` (`sdk.tsx:128`).
- Default SDK headers are just `Content-Type: application/json` (`.../gen/client/utils.gen.js:217-219`) — **no `Accept: text/event-stream`** is set on the SSE request, so the SSE GET is **not** distinguishable by header. URL path is the reliable discriminator.
- `packages/tui/src/util/route.ts:48-82` (`resolveServeUrl`) — **precedent** for a bounded per-request timeout: `AbortSignal.timeout(timeoutMs)` (default `3000`) composed with the caller signal via `AbortSignal.any([opts.signal, timeoutSignal])`, all wrapped in `try/catch` so a runtime lacking those APIs degrades to "no bound" instead of throwing.
- `packages/tui/src/util/sse.ts:27-58` (`runSseAttempt`) — each SSE (re)connect runs under its own `AbortController`, aborted in `finally`; the comment confirms abort "forces the underlying fetch/connection closed instead of leaving it ESTABLISHED in the client's keep-alive pool." So **aborting a hung request frees the pooled connection** — exactly the mechanism we want.

### The decisive server-side fact (kills the naive "TTFB" plan)

`packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts`:

- `prompt` (`:293-307`): `const message = yield* promptSvc.prompt({...}); return HttpServerResponse.stream(...JSON.stringify(message)...)`. The handler **awaits the entire agent turn** and only THEN constructs the response. **Response headers are withheld until the turn completes (minutes).**
- Same shape for the other blocking ops: `command` (`:329-337`), `shell` (`:339-345`), `summarize` (`:271-291`, awaits `compactSvc.create` + `promptSvc.loop`), `init` (`:235-250`, awaits a `command`). All are **POST**.
- The non-blocking `promptAsync` (`:309-327`) returns `NoContent` immediately, but the TUI uses the **blocking** `session.prompt` (`prompt/index.tsx:1167-1185`).

**Consequence:** for opencode's long endpoints, **time-to-first-byte == end of the
operation**. A TTFB (headers-received) timeout therefore provides *no* way to tell a
legit multi-minute turn apart from a wedged serve — both look like "no headers for a
long time." So a TTFB-on-everything wrapper (the task's candidate (a)) would
false-abort real turns. We must classify endpoints, not just measure TTFB.

---

## Request inventory + classification (attach TUI)

All SDK calls go through the one `props.fetch` chokepoint. Classification by the
property that matters here — **does the server withhold the response for a long time?**

### A. Long / header-withholding (MUST NOT be timed out) — all **POST**

| SDK call | Route | Why long |
|---|---|---|
| `session.prompt` | POST `/session/:id/prompt` | awaits full agent turn |
| `session.command` | POST `/session/:id/command` | awaits a command turn |
| `session.shell` | POST `/session/:id/shell` | awaits shell command |
| `session.summarize` | POST `/session/:id/summarize` | awaits compaction loop (LLM) |
| `session.init` | POST `/session/:id/init` | awaits INIT command turn |

(Other POSTs — `permission.reply`, `question.reply`, `session.abort`, `session.fork`,
`auth.set`, `mcp.connect`, … — are short-ish but **user-initiated, not periodic**, so
they don't pile up; `mcp.connect` can itself be legitimately slow via OAuth.)

### B. Short control / metadata — **GET**, the pile-up source

The bootstrap fan-out in `packages/tui/src/context/sync.tsx:440-507` fires ~15
concurrent **GET**s and **re-runs on every `server.instance.disposed` event**
(`sync.tsx:162-166`) and on each fresh mount / reconnect:

`config.get`, `provider.list`, `provider.auth`, `app.agents`, `session.list`,
`command.list`, `lsp.status`, `mcp.status`, `formatter.status`, `session.status`,
`vcs.get`, plus on-demand `session.get` / `session.messages` / `session.diff` /
`vcs.status` / `find.files` / `project.current` / `project.directories` / `path.get`.

These are the periodic non-SSE requests that **hang `ESTABLISHED` and accumulate to
256** on a stalled serve. They all return promptly on a healthy serve. The very first
of them is `validateSession` → `session.get` (`validate-session.ts:23-28`), which on a
stalled serve hangs forever **at attach startup** (currently unbounded).

### C. The SSE stream (MUST stay infinite) — **GET** `/global/event`

Opened once per attempt at `sdk.tsx:128` via `sdk.global.event(...)`. Also `/event`
(session-scoped, from `event-session-scope.patch`) is infinite. Both are GET, so the
method rule below cannot exempt them — they need a **path** exemption.

**Observation that drives the design:** every dangerous-to-abort call (A) is a
**POST**; every pile-up call (B) and the SSE stream (C) are **GET**. So
"timeout GETs, except the SSE paths" cleanly separates "fix the pile-up" from "never
touch a long op."

---

## Recommended mechanism

A small **client-side fetch wrapper** installed **only on the `attach` network path**,
that bounds **GET requests only**, with the **SSE event-stream paths exempt**. Built
on the exact `AbortSignal.timeout` + `AbortSignal.any` composition the codebase
already uses in `resolveServeUrl` (the task's candidate (c)).

### Policy (decision table)

| Request | Rule | Result |
|---|---|---|
| `GET /global/event`, `GET /event` | exempt by path | **no timeout** (infinite SSE) |
| any other `GET` | bound | abort if no completed response within `N` |
| `POST` / `PUT` / `PATCH` / `DELETE` | pass through | **no timeout** (covers every long op) |

Why this is the safest of the candidates:

- **SSE-safe (constraint 1):** the infinite stream is exempt by exact pathname; and the
  SSE attempt keeps its own per-attempt controller (`sse.ts`) — we compose, never replace.
- **Long-op-safe (constraint 2):** all blocking endpoints are POST → never timed out.
  This is **robust to future endpoints**: a new agent/LLM/shell op is, by REST
  convention, a non-GET, so it is exempt *by default*. **Zero false-abort risk on a
  turn — by construction, not by enumeration.** (Contrast with a deny-list of named
  long endpoints, where a new unlisted blocking endpoint would be false-aborted; and
  with an allow-list of named short endpoints, which leaves new pollers unprotected and
  is ~35 entries to maintain. The method rule is one predicate and fails safe in the
  direction that matters.)
- **No reliance on Bun defaults (constraint 3):** we attach an explicit
  `AbortSignal.timeout`; abort tears the socket down (frees the pooled connection).
- **Fixes the pile-up:** the periodic bootstrap GET fan-out and any other hung GET
  fail after `N`s, freeing the connection long before 256 accumulate; existing
  `.catch`/resource-error handling surfaces it and the SSE loop re-resolves.

### Why NOT a TTFB (headers-received) timer

The task asks to weigh a TTFB timer that is *cleared once headers arrive* (so a
slow-but-progressing body survives). The Bun/WHATWG semantics are favorable in
principle — `await fetch()` resolves at headers-received, the body streams lazily, and
clearing the timer at that point means a mid-body abort can never fire, so a
progressing stream is never killed. **But it buys nothing here:** opencode's long
endpoints **withhold headers until the operation finishes** (`session.ts:293-307`), so
their TTFB == completion; a TTFB timer can't distinguish them from a wedged serve. And
the endpoints we *do* protect (control GETs) return small buffered JSON, so
whole-request ≈ TTFB for them anyway. TTFB adds complexity and a residual risk
(any future early-headers-then-long-body endpoint) for no benefit. Rejected in favor
of the method+path rule.

### Where it lives + constants

New file `packages/tui/src/util/fetch.ts`:

```ts
/** Bounded whole-request timeout for the attach TUI's short control GETs.
 *  Generous vs. the slowest legit control GET (find/messages on a huge repo);
 *  small vs. the time to accumulate the 256-conn pool cap (~0.9 conn/min). */
export const ATTACH_REST_TIMEOUT_MS = Number(process.env.OPENCODE_ATTACH_REST_TIMEOUT_MS) || 30_000

/** Infinite SSE streams — never bounded. (Matches sdk.gen.js sse.get urls.) */
const SSE_PATHS = new Set(["/global/event", "/event"])

export function withRequestTimeout(baseFetch: typeof fetch, timeoutMs = ATTACH_REST_TIMEOUT_MS): typeof fetch {
  return (input, init) => {
    const req = input instanceof Request && init === undefined ? input : new Request(input as any, init)
    const path = (() => { try { return new URL(req.url).pathname } catch { return "" } })()
    // Bound idempotent GETs only; exempt the infinite SSE stream and every
    // non-GET (covers all long agent/LLM/shell POSTs, present and future).
    if (req.method !== "GET" || SSE_PATHS.has(path)) return baseFetch(req)

    let signal: AbortSignal = req.signal
    try {
      const t = AbortSignal.timeout(timeoutMs)
      signal = req.signal ? AbortSignal.any([req.signal, t]) : t
    } catch {
      // Runtime without AbortSignal.timeout/any: degrade to the caller's signal
      // (no added bound) rather than throwing — mirrors resolveServeUrl.
    }
    return baseFetch(new Request(req, { signal }))
  }
}
```

Notes:
- The SDK always calls `_fetch(request)` with a single `Request` (REST `client.gen.js:59`,
  SSE `serverSentEvents.gen.js:34`), so the `input instanceof Request` branch is the hot
  path; the `(url, init)` branch is for direct callers (e.g. if we also wrap
  `resolveServeUrl`'s fetch — not required, it is already 3 s-bounded).
- `new Request(req, { signal })` clones method/url/headers/body and overrides only the
  signal. We only reach it for GETs (no body), so body re-stream concerns don't arise.
- The caller's signal here is `abort.signal` (TUI teardown, baked onto every SDK Request
  via `createSDK`'s `signal:`), so composition **preserves teardown-abort**.
- `ATTACH_REST_TIMEOUT_MS = 30_000`: lower bound must exceed the slowest legit control
  GET (a `find.files`/`session.messages` spike on a giant monorepo — typically <1 s,
  generous margin at 30 s); upper bound is irrelevant to safety (at ~0.9 conn/min even
  60 s keeps in-flight hung GETs ≈ 1). 10–30 s all acceptable; 30 s chosen to err
  hard against false-aborting a legit GET. Env-overridable like other patch tunables.

### Install point (scoping)

Edit `packages/opencode/src/cli/cmd/attach.ts` only — wrap the network fetch the
attach path uses:

```ts
import { withRequestTimeout } from "@opencode-ai/tui/util/fetch"
const wrappedFetch = withRequestTimeout(globalThis.fetch)
// ...
await validateSession({ url, sessionID: args.session, directory, headers, fetch: wrappedFetch })
// ...
await Effect.runPromise(run({ url, config, ..., headers, fetch: wrappedFetch }))
```

This deliberately does NOT touch `tui.ts`: the in-process worker-fetch path
(`createWorkerFetch`) is same-process RPC, not a TCP socket, and must not get a network
timeout. `sdk.tsx` is unchanged — it already threads `props.fetch` to both REST and SSE,
and the path exemption handles SSE. Wrapping `validateSession` also bounds the
otherwise-unbounded attach **startup** `session.get`.

---

## Patch shape

A **new** patch `patches/attach-request-timeout.patch`, applied **after**
`attach-route-resolve.patch` in `apply.sh`'s ordered list (both edit `attach.ts`):

1. **new** `packages/tui/src/util/fetch.ts` — `withRequestTimeout` + constants (above).
2. **new** `packages/tui/test/util/fetch.test.ts` — unit tests (below).
3. **edit** `packages/opencode/src/cli/cmd/attach.ts` — import + wrap `globalThis.fetch`,
   pass `fetch: wrappedFetch` to `validateSession` and `run`.

Rationale for a separate patch (not extending `attach-route-resolve.patch`): distinct
concern (request bounding vs. serve resolution), independently auditable and revertible,
small diff. Document the ordering dependency in the `apply.sh` header. Client-only — no
serve change.

## Test strategy

`packages/tui/test/util/fetch.test.ts` (bun:test, mirroring `route.test.ts`). Inject a
fake `baseFetch` so we don't need real sockets; use a small `timeoutMs` (e.g. 20 ms) or
fake timers for determinism. A "stalled serve" = a `baseFetch` whose returned promise
**never resolves**, and which records the `Request.signal` it was handed so the test can
assert on abort.

1. **GET is bounded:** `withRequestTimeout(neverResolving, 20)` on `GET /config` rejects
   with an abort/timeout error after ~20 ms (assert the handed signal aborted).
2. **SSE GET is exempt:** `GET /global/event` (and `/event`) — the handed signal never
   aborts within a window well past `timeoutMs`; the promise stays pending.
3. **POST is exempt:** `POST /session/x/prompt` — handed signal never aborts past
   `timeoutMs` (proves long turns survive).
4. **Caller-signal composition:** pass a `Request` carrying a caller `AbortController`'s
   signal on a GET; abort the caller → the fetch aborts immediately (teardown still works).
5. **Degradation:** stub `AbortSignal.timeout`/`any` to throw/undefined → wrapper does
   not throw and forwards with the caller's signal (no added bound).
6. (optional, integration) a real `Bun.serve` that `accept()`s but never writes, behind
   the wrapper: a GET rejects ~`timeoutMs`; an SSE GET stays open.

---

## Risks & open questions

**Risks**
- *False-aborting a legit slow GET (low / low-severity).* A control GET that spikes past
  `N`s (e.g. `find.files`/`session.messages`/`app.skills` on a huge repo under load)
  would be aborted; the SDK call rejects and the TUI shows a toast / the resource
  errors — recoverable, and unlikely at `N`=30 s. Mitigation: the value is generous and
  env-tunable. (Compare the catastrophic alternative — aborting a 5-minute turn — which
  the POST exemption makes **impossible**.)
- *A future LONG `GET` endpoint.* The method rule assumes no GET legitimately runs for
  minutes (true today: all blocking ops are POST; no streaming/large-file GET is called
  by the attach TUI). If upstream later adds a long-running GET that the TUI calls, it
  would be false-aborted. Mitigation: add its path to `SSE_PATHS`→ rename to an
  `EXEMPT_PATHS` set; audit the GET surface at each version cutover (grep handlers that
  `yield* promptSvc.*`/`compactSvc.*` and check their method).
- *Path-match fragility.* Exemption keys on exact pathname `/global/event` / `/event`;
  if a future SSE route is added it must be added to the exempt set. Low — SSE routes are
  rare and enumerable in `sdk.gen.js`.

**Open questions**
1. Confirm the empirical pile-up traffic is dominated by the bootstrap **GET** fan-out
   (and not, say, repeated user POSTs) by sampling a stalled-serve `ss -tnp` against the
   serve port — validates the method-based scoping end-to-end. (Strong code evidence:
   `sync.tsx:162-166` re-bootstraps on dispose; all bootstrap calls are GET.)
2. Should we *also* fast-fail the short **POST** control calls (`permission.reply`,
   `question.reply`, `session.abort`)? They don't pile up (user-initiated), but a hung
   `session.abort` on a stalled serve is annoying. Deferred — would reintroduce
   per-endpoint classification and the false-abort risk we just designed out; not needed
   for yoa2.
3. Timeout value: 30 s vs 10–15 s. 30 s maximizes safety against false-aborts; a smaller
   value frees connections faster but the pool math (~0.9 conn/min vs 256) makes the
   urgency negligible. Pick at implementation; expose `OPENCODE_ATTACH_REST_TIMEOUT_MS`.
4. Should `tui.ts --external` (network, `fetch: undefined`) also get the wrapper? It's the
   same network shape as attach, so likely yes for symmetry, but the reported pile-up is
   the `attach` pool; scope to `attach` first, consider `tui --external` as a follow-up.
```
