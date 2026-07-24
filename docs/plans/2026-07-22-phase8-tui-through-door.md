# Phase 8 — TUI through the front door (opencode-patched mini-plan)

Status: **PLANNING** (investigation done 2026-07-22; awaiting design decisions + fable review before any patch).
Parent epic: workstation `docs/plans/2026-07-12-serve-reverse-proxy-plan.md` "Phase 8"; bead `workstation-mlve.3`.

## Goal
Make the interactive attach TUI ride the opaque front door (`:4700`) instead of a raw serve, so Phase 9 can repoint `OPENCODE_URL`→door. Requires: move the client event stream `/global/event`→`/event?session_ids=<sid>`, drop the client `/route` self-resolve (the door owns ownership), jittered reconnect + backoff-reset-on-open (NEW-A), keep subagents interactive under session-scoping (NEW-B), migrate the mutating-global REST surface to session-scoped routes (NEW-P5-F1), and add a CI tripwire (NEW-G). Then cut `v1.17.13-patched.1` and bump the workstation pin.

## CRITICAL corrections from investigation (2026-07-22) — the epic is bigger than the parent-plan bullets

1. **Author patches against a FRESH `git clone --branch v1.17.13` of anomalyco/opencode — NOT `~/projects/opencode`.** The on-disk checkout is a *different* version (`v1.4.11-…`, pre-1.16 layout: TUI at `packages/opencode/src/cli/cmd/tui/**`, server `eventResponse(bus)`, no `packages/tui/`, no `util/route.ts`). `apply.sh` uses **zero-fuzz `git apply`**; patches written against on-disk paths/context will `.rej`. The on-disk tree is a **logic reference only**. `build-release.yml` clones v1.17.13 fresh and runs `patches/apply.sh .`.

2. **Server side is already DONE.** `event-session-scope.patch` (server-only) adds an optional `?session_ids=a,b,c` filter to `GET /event`. Semantics to design around: an event with **no string `sessionID`** (server/lifecycle/global) **always passes**; an event **with** a `sessionID` passes **only if in the set**; an **empty** set **blocks ALL session events** (never send empty). This is exactly what the door depends on.

3. **This is a patch-set REFACTOR that SUPERSEDES `tui-follow-owner.patch`, not an additive patch.** Prior partial work:
   - `attach-route-resolve.patch` (client): adds `packages/tui/src/util/route.ts` (`resolveServeUrl` via pigeon `/route`), `util/sse.ts` (`runSseAttempt`), rewrites `sdk.tsx` reconnect — **but still subscribes to `sdk.global.event(...)` = `/global/event` firehose.**
   - `tui-follow-owner.patch` (client): adds `evaluateOwnerDrift` + a `/route` re-poll, resets backoff **only on drift**; still `sdk.global.event(...)`.
   Phase 8 must **remove the client `/route` self-resolve** (`resolveServeUrl`/`evaluateOwnerDrift` call sites) — which directly conflicts with `tui-follow-owner`'s entire purpose. Decision needed: delete/replace `tui-follow-owner` (and the self-resolve in `attach-route-resolve`) vs keep as a non-door fallback. Any new TUI patch touching `sdk.tsx`/`sse.ts`/`route.ts` must land **after** those two in `apply.sh`'s `PATCHES=(…)` array and match their post-application context.

## Workstreams (with investigation file:line — OLD-layout logic refs; re-anchor on the v1.17.13 clone)

### W1 — Event move: client `/global/event` → `/event?session_ids=<sid>`
- The firehose open is `sdk.global.event({signal, sseMaxRetryAttempts:0})` in `sdk.tsx` `open()` (old ref `cli/cmd/tui/context/sdk.tsx:83`; patched tree `packages/tui/src/context/sdk.tsx`).
- **Gap:** the SDK v2 `Event.subscribe()` (`/event`) accepts only `directory`/`workspace` — **no `session_ids`**. → DECISION D1: SDK regen/extension to add `session_ids` (touches generated `packages/sdk/js/src/v2/gen/*`, cleaner) vs a raw-query bypass in `sdk.tsx` (lighter, hand-built URL).
- Must **never send an empty `session_ids`** (would blackhole the session's own events).
- Confirm the bootstrap `sync.start()`/workspace sync that rides the same stream (`sdk.tsx` `onOpen`) is compatible with a session-scoped `/event` (it may expect the firehose).

### W2 — Drop client `/route` self-resolve (door owns ownership)
- Remove `resolveServeUrl` call in `sdk.tsx` `open()` and `attach.ts`, and `evaluateOwnerDrift`/`poll` from `tui-follow-owner`. The TUI attaches to its single base URL (the door); the door resolves + drops-leg-on-drift. This supersedes W1 prior work.

### W3 — NEW-A backoff-reset-on-open + jittered reconnect
- `sdk.tsx`: `attempt` (old ref `:79`), `retryDelay=1000` (`:43`), `maxRetryDelay=30000` (`:44`), `attempt+=1` (`:101`), backoff `min(1000*2**(attempt-1),30000)` (`:105`). Reset `attempt=0` **on a successful stream open** (onOpen), and add jitter to the backoff (herd avoidance). Today it resets only on drift (tui-follow-owner). High conflict-risk region with W1/W2.

### W4 — NEW-B: keep subagents interactive under session-scoping (**CORRECTNESS, not staleness**)
- The active view's permission/question prompts are aggregated from **child** sids: `session/index.tsx:195-202` (`children().flatMap(x => sync.data.permission[x.id])`). Child/subagent sessions have **distinct sids**; their `permission.asked`/`question.asked`/`message.*`/`session.status`/`session.updated` events carry the **child** sid → dropped by `?session_ids=<primary>` → **subagent permission prompt never renders → subagent hangs.**
- → DECISION D2: include child sids in `session_ids`. Enumerate `GET /session/{id}/children` at attach; **dynamically re-subscribe** (reconnect with the extended set) when a new child session appears. Chicken-and-egg: a child born *after* attach won't emit on the scoped stream, so the trigger to add it can't come from the scoped stream itself — need a source (e.g. `session.updated` for the parent, or a periodic `children` poll, or keep a narrow global signal). The switcher's *other top-level* sessions can tolerate fetch-on-demand via `sync.session.refresh()`.

### W5 — NEW-P5-F1: migrate mutating-global REST → session-scoped
Call sites (old-layout refs) + server-route reality:
- **permission reply** (`routes/session/permission.tsx:171,182,421,428`, `sdk.client.permission.reply`, bare `POST /permission/{requestID}/reply`): session-scoped route **EXISTS** — `POST /session/{sid}/permissions/{permissionID}` (`permissionRespond`, server `groups/session.ts`; SDK `sdk.gen:2866`). `sessionID` available at call site. ✅ migratable.
- **question reply/reject** (`routes/session/question.tsx:50,57,72`, bare `POST /question/{requestID}/reply|reject`): **NO session-scoped server route exists.** → DECISION D3: add a NEW server-route patch (mirror `permissionRespond`) vs a door special-case for bare question routes.
- **NOT session-scopable** (name/provider/instance-scoped, cannot become `/session/{sid}/…`): `mcp.connect|disconnect` (`context/local.tsx:483,486`), `instance.dispose` (`dialog-provider.tsx`/`dialog-console-org.tsx`), `auth.set` (`PUT /auth/{providerID}`), `provider.oauth.authorize|callback`, `experimental.workspace.*`. → DECISION D4: door strategy for these — (a) door routes them to the owner of the *current* session (needs a "current sid" header/context), (b) keep them off-door (a narrow set the TUI still sends direct — but that reintroduces "another door"), or (c) door broadcasts/anchors them. Note `opencode-launch --mcp`'s `mcp connect` (workstation) has the same non-session-scopable problem.
- **`POST /experimental/control-plane/move-session`**: NOT in the on-disk tree — **verify it exists in v1.17.13** before writing door allow-list/client migration.

### W6 — NEW-G: CI tripwire
- Server contract test co-locates with `event-session-scope.patch` tests in `packages/opencode/test/server/httpapi-event.test.ts` (already the append target). Client contract (TUI subscribes to `/event?session_ids=<sid>`, NOT `/global/event`) → unit test by `packages/tui/test/util/sse.test.ts` / an sdk-level URL-shape assertion.
- **Inert unless wired to CI:** `build-release.yml` runs **no tests**. NEW-G must add BOTH the test AND a workflow step (release job or a separate PR-CI) that runs it, else the tripwire never fires.

## Release + pin (after patches land + gate passes)
- Cut `v1.17.13-patched.1`: `build-release.yml` (`workflow_dispatch`, `version=1.17.13`, `revision=1`) → clones, applies, builds 4 platforms, tags `v1.17.13-patched.1`, publishes artifacts + `checksums.sha256`.
- Bump workstation pin (`users/dev/home.base.nix`): set `patchedRevision="1"` (l.~239) + replace **all four** platform hashes (l.~34,39,44,49). Coordinate with `update-opencode-patched.yml` cron (tracks highest revision when `patchedRevision` non-empty) so the auto-updater doesn't fight the manual bump. This deliberately breaks the "no `patched.N` release cut during Phases 0–8" hold (that hold now ends — Phase 8 IS the release).
- Rollback = hold the pin to the previous release (`v1.17.13-patched`, current).

## Gate (from parent plan)
A migrated session's attach TUI: (1) survives idle owner-migration hand-off with **no reconnect-delay inflation across repeated migrations** (NEW-A), (2) **answers a mid-turn permission prompt through the front-door URL** (NEW-P5-F1), and (3) **a subagent's permission/question prompt renders + is answerable** (NEW-B). Plus the door's existing gate (`audit/gate.sh`) still green with a real TUI on the door.

## Decisions (user, 2026-07-22)
- **D1 — RESOLVED: cleaner.** Extend the SDK v2 to add a `session_ids` param to `Event.subscribe()` (regen the generated `packages/sdk/js/src/v2/gen/*`), not a hand-built raw-query bypass in `sdk.tsx`.
- **D2 — RESOLVED: polling.** NEW-B includes child sids in `session_ids`; discover children via a periodic `GET /session/{id}/children` **poll** (reconcile the subscription set on change), rather than an event-triggered re-subscribe. Never send an empty set. Switcher's other top-level sessions: fetch-on-demand via `sync.session.refresh()`.
- **D3 — RESOLVED: new server route.** Add a session-scoped question route (new server patch mirroring `permissionRespond`), e.g. `POST /session/{sid}/questions/{questionID}` reply/reject; migrate the TUI to it. **No door special-case.**
- **D4 — DIRECTION: broadcast (⚠️ needs per-route validation in fable).** For the non-session-scopable mutating routes the door fans out to all pool serves. CAUTION — broadcast is NOT uniformly correct and must be validated per route: `auth.set` (all serves need new auth → broadcast fits); `mcp.connect|disconnect` (per-process → broadcast connects on all K, wasteful but the owner ends up covered); `instance.dispose` (pool-wide reload — drastic but arguably intended for the auth-reload flow); **`provider.oauth.authorize|callback` is STATEFUL — authorize picks a serve and the callback MUST return to the SAME serve; naive broadcast breaks the pairing** (needs sticky, not broadcast); `experimental.workspace.*` (validate). Fable to stress each; the door fan-out response-aggregation semantics (first / all-ok / which body) also need definition.
- **D5 — RESOLVED: supersede.** Fully replace `tui-follow-owner.patch` and remove the `resolveServeUrl` self-resolve from `attach-route-resolve.patch`. **No non-door path, no fallbacks** — the TUI attaches only to its base URL (the door); the door owns resolution + drop-leg-on-drift.
- Still to verify: **`move-session`** route identity in real v1.17.13.

## Hazards
- Zero-fuzz `git apply`; author on a real v1.17.13 clone; new TUI patches after `tui-follow-owner` in the array; W1/W2/W3 all edit the same `open()`/reconnect region (high conflict) — likely fold into / carefully anchor after `attach-route-resolve`+`tui-follow-owner`.
- `build-release.yml` release body text is stale (says "six patches") — cosmetic.
- macOS build needs the ad-hoc codesign path (already in the workflow).
