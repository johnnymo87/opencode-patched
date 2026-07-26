#!/usr/bin/env bash
# Apply local patches to opencode source for the v1.17 release line.
# Usage: ./apply.sh <path-to-opencode-source>
#
# TARGET UPSTREAM: opencode v1.17.13
#
# PATCH SET (v1.17 line; rebased 2026-06-11 from the v1.15 line, rolled forward
# from v1.17.7 to v1.17.13 on 2026-07-06):
#   1. gemini-empty-parts.patch   (PR #28669) - pad empty Gemini/Vertex parts arrays
#                                               (gemini.ts lowerMessages + transform.ts normalizeMessages)
#   2. tool-fix.patch             (PR #16751) - synthetic step-start boundaries (tool_use/result mismatch)
#   3. cache-thinking-skip.patch  (#17883)    - cache breakpoint scans past trailing thinking/reasoning blocks
#   4. retry-cap.patch            (local)     - MAX_RETRIES=8 + backoff jitter (Vertex/Gemini runaway cure)
#   5. vim.patch                  (PR #12679) - vim keybindings, re-ported to the new
#                                               packages/tui/ TUI package for 1.17 (TUI moved
#                                               out of packages/opencode in 1.16/1.17).
#                                               Re-ported to v1.17.4 2026-06-12 (prompt/index.tsx
#                                               hunk #9 context drift: the send-path .catch(() => {})
#                                               one-liner became a multi-line .catch((error) => {...});
#                                               the vimState.clearPending() insertion point before
#                                               history.append was otherwise intact).
#   6. sqlite-foreign-key-wrap.patch (local)  - catch nested/wrapped foreign key constraints
#                                               on modern effect-drizzle error wrappers
#   7. event-session-scope.patch (local)      - optional ?session_ids=a,b,c filter on GET /event
#                                               (pool-of-K-serves per-session SSE; bead workstation-x8wi)
#   8. createnext-readback.patch (local)      - Session.createNext reads the row back after
#                                               publishing Created, returning the durable canonical
#                                               row (fails loud on a lost write) instead of the
#                                               in-memory Info (bead workstation-p196; mn9r M3)
#   9. serve-lease.patch          (local)      - serve-side session-lease participation (mn9r M4):
#                                               OPENCODE_ROUTING_DB/OPENCODE_SERVE_ID flags +
#                                               packages/core/src/serve/routing-lease.ts adapter
#                                               (fenced lease CAS against pigeon-daemon.db),
#                                               serve.ts self-registration + self-heartbeat (D1a),
#                                               and a fenced acquire/renew/release wrap + per-iteration
#                                               deadline guard around the agent run loop (D2a). Whole
#                                               feature is gated on OPENCODE_ROUTING_DB; unset = no-op
#                                               (bead workstation-mn9r). Fix D (bead workstation-oqa1):
#                                               the renewal fiber re-acquires on a failed renew (rotating
#                                               the lease token via a Ref) when the assignment still points
#                                               at this serve — benign owner_generation churn no longer
#                                               fail-closes the run; only a genuine reassignment to another
#                                               serve dies "session lease lost mid-run". Fix C (bead
#                                               workstation-uzig): the self-heartbeat moved OFF the agent
#                                               event loop onto a worker_threads Worker (inline blob, static
#                                               import bun:sqlite, own DB handle + busy_timeout) so a
#                                               CPU-heavy/synchronous turn can't starve it -> no false
#                                               dead-serve. packages/opencode/src/serve/heartbeat.ts; first-
#                                               beat handshake + main-thread fallback if the worker can't
#                                               boot (degrades to pre-Fix-C behavior, never to no heartbeat);
#                                               worker terminated before markDead. New flags
#                                               OPENCODE_HEARTBEAT_INTERVAL_MS (prod tunable, default 5000)
#                                               and OPENCODE_TEST_BLOCK_MAIN_LOOP_MS /
#                                               OPENCODE_TEST_FORCE_HEARTBEAT_FALLBACK (test-only seams).
#  10. attach-route-resolve.patch (local)      - pool-aware `opencode attach` (mn9r M7, bead
#                                               workstation-7zr7): packages/tui/src/util/route.ts
#                                               (parseServeUrl + resolveServeUrl via pigeon GET /route,
#                                               PIGEON_DAEMON_URL default :4731, degrade to fallback),
#                                               attach.ts `[url]` optional + self-resolve from --session,
#                                               and a startSSE re-resolve + try/catch reconnect in
#                                               context/sdk.tsx so the TUI follows a session that
#                                               migrates serves (idle-migration / pool-health reshuffle)
#                                               and survives 409/410/421/503/connection-refused drops.
#                                               LEAK FIX (bead workstation-lyj0): the first cut shared ONE
#                                               long-lived AbortController across every reconnect and never
#                                               closed a finished attempt's stream, so each reconnect leaked
#                                               one ESTABLISHED connection up to the per-origin pool cap (256);
#                                               18 idle attach TUIs that all fell back to the default serve
#                                               thereby pinned a single serve's event loop with ~4600 conns.
#                                               It also called resolveServeUrl with that long-lived signal,
#                                               accumulating one un-removed AbortSignal.any listener per
#                                               reconnect (MaxListenersExceededWarning). Fix: new
#                                               packages/tui/src/util/sse.ts runSseAttempt() runs each
#                                               (re)connect as a discrete attempt with its OWN controller,
#                                               aborted in finally (force-closes the connection before the
#                                               next opens), with a balanced add/remove parent->attempt abort
#                                               bridge; resolveServeUrl + sdk.global.event now take the
#                                               short-lived per-attempt signal. Unit-tested in
#                                               packages/tui/test/util/sse.test.ts.
#  11. event-cold-start-directory.patch (local) - fix the cold-start live-delivery race on GET /event
#                                               (bead workstation-yl00). Builds on event-session-scope:
#                                               when ?session_ids= is present, session-scoped events are
#                                               gated purely on session-aggregate membership instead of
#                                               an exact-string directory match. A subscriber whose
#                                               captured instance.directory differs from the directory
#                                               the forked agent loop stamps on its events (FSUtil.resolve
#                                               realpaths an existing dir but only normalizes a not-yet-
#                                               existing one) was silently dropping all message.*/session.*
#                                               for the watched session. sessionID is globally unique, so
#                                               no cross-directory leak. MUST apply after event-session-scope.
#  12. project-copy-debounce.patch (local)    - tame the 1.17.x reconnect-storm wedge (bead
#                                               workstation-sqd5). ProjectCopy.refreshAfterBoot runs once
#                                               per location boot; a reconnect/poll storm fired N concurrent
#                                               refreshes for the SAME projectID, each with unbounded-
#                                               concurrency fs.isDir + a `git worktree list` subprocess per
#                                               source dir (one refresh touched 136 dirs), blocking the Bun
#                                               event loop (RSS ~19.6 GB, HTTP wedge). Fix in
#                                               packages/core/src/project/copy.ts: (a) a module-scope
#                                               single-flight Map<projectID, Deferred> so concurrent
#                                               refreshes coalesce onto one run (each location boot builds a
#                                               FRESH Service via LayerMap+Layer.fresh, so the dedup MUST be
#                                               module-level), and (b) replace concurrency:"unbounded" with
#                                               REFRESH_CONCURRENCY=4 at both fan-out sites. Disjoint from
#                                               all other patches (only file touched besides its test).
#                                               EXTENDED (bead workstation-wvv2): also DISABLE the per-boot
#                                               refresh BY DEFAULT to kill its per-boot O(#dirs) cost
#                                               (~136 dirs / ~300 git subprocesses = a core pegged for
#                                               minutes on every cold boot). A guard at the head of
#                                               refreshAfterBoot returns early unless
#                                               OPENCODE_PROJECT_COPY_REFRESH_ON_BOOT === "1" (unset =
#                                               disabled = fork default; ="1" restores upstream every-boot
#                                               behavior). Safe headless: source dirs self-register via
#                                               Project.saveProjectDirectory on open, the Move Session
#                                               dialog refreshes on demand, project identity is git-derived;
#                                               the explicit refresh() API is untouched (gate is only at the
#                                               boot entry). Consumer-inventory + verdict in
#                                               docs/plans/2026-06-23-projectcopy-refresh-cost-design.md.
#  13. step-end-diff-bound.patch (local)     - bound the step-end summary diff that pins one core at 100%
#                                               CPU forever (upstream anomalyco/opencode#29762; bead
#                                               workstation-0lik). Snapshot.diffFull (packages/opencode/src/
#                                               snapshot/index.ts) built per-file unified diffs at step-end
#                                               summary time via jsdiff structuredPatch(...,{context:
#                                               MAX_SAFE_INTEGER}) with NO bound. jsdiff Myers diff is
#                                               O(N*D); a full-file rewrite of a sub-2MB file drives D~=N+M,
#                                               pinning the single JS thread for minutes + ~1GB path-array
#                                               alloc while the Bun event loop is blocked (silent, zero I/O,
#                                               matches the gdb fixed-PC profile). summary runs via
#                                               Effect.forkIn but that's a cooperative fiber on the SAME
#                                               thread, so a synchronous jsdiff call still freezes the loop.
#                                               Fix: new exported boundedFilePatch() + named constants
#                                               (SNAPSHOT_DIFF_MAX_BYTES=1MiB, _MAX_EDIT_LENGTH=4000,
#                                               _TIMEOUT_MS=1000) compose a cheap size pre-guard with jsdiff's
#                                               own {maxEditLength,timeout}; when any cap trips it returns
#                                               undefined so the OPTIONAL FileDiff.patch field is omitted
#                                               (counts-only) — consumers already guard typeof patch!=="string"
#                                               (app/src/utils/diffs.ts), so omission is parser-safe. Only
#                                               touches snapshot/index.ts + its new test; disjoint from all
#                                               other patches. DOES NOT address the distinct, uncharacterized
#                                               flat-RSS read-only-subagent spin variant (#32965) — deferred.
#  14. bootstrap-disposed-filter.patch (local) - prevent connection and CPU-amplification storms by
#                                               filtering and debouncing server.instance.disposed event
#                                               handling in the TUI (bead workstation-y69t). Re-runs of
#                                               bootstrap() are only triggered when the event's directory
#                                               matches this TUI's workspace and directory, and qualifying
#                                               disposals within 250ms are coalesced into a single run.
#  15. tui-follow-owner.patch    REMOVED (2026-07-24, Phase 8) — SUPERSEDED by tui-door-attach.patch below.
#                                               Its /route-drift self-resolve (evaluateOwnerDrift + poll) is
#                                               obsolete once the TUI rides the opaque front door: the door
#                                               owns ownership and drops the SSE leg on a confirmed owner
#                                               migration, so the client never self-resolves pigeon /route.
#                                               (bead workstation-mlve.3 / D5.)
#  16. event-log-gate.patch      (local)      - gate the durable event LOG (event table inserts in
#                                               core/src/event.ts commitSyncEvent) behind
#                                               Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (bead
#                                               workstation-bm1i). In v1.17.7 every durable event
#                                               commit unconditionally INSERTs a full event row
#                                               (message.updated.1 = complete message snapshot ->
#                                               O(n^2) bytes per long session; 2.8GB of a 4.3GB
#                                               opencode.db on devbox) plus a dup-check SELECT,
#                                               all synchronously inside the main-thread commit
#                                               transaction. The only readers in v1.17.7 are the
#                                               remote-workspace sync paths (/sync/history,
#                                               /sync/replay, workspace warp) and the UNEXPOSED
#                                               V2Session.events — nothing reads the log when
#                                               workspaces are off. EventSequenceTable (seq
#                                               counters, one tiny row per aggregate) is still
#                                               maintained unconditionally. Mirrors upstream's own
#                                               later gate (commit b0017bf1b9, sync/index.ts).
#                                               SUNSET: drop on cutover to an upstream that ships
#                                               b0017bf1b9 or successor gating.
#  17. compaction-bounded-load.patch (local)   - bound the prompt loop's per-iteration message load
#                                               to the compaction window (bead workstation-g3iy).
#                                               v1.17's loop calls filterCompactedEffect every
#                                               iteration; upstream materializes the ENTIRE session
#                                               history (stream() pages all messages + parts, JSON-
#                                               decodes everything) and only then lets
#                                               filterCompacted discard everything before the last
#                                               completed compaction boundary. A 17k-message session
#                                               = multi-minute synchronous main-thread JS per touch:
#                                               observed freezing devbox serve-0 (94% usermode CPU,
#                                               flat read_bytes, GC helpers idle) until the canary
#                                               SIGKILLed it. Fix: extract the newest-first walk into
#                                               an incremental compactedWalk() closure and make
#                                               filterCompactedEffect page 50-at-a-time, feeding the
#                                               walk and STOPPING pagination the moment the walk hits
#                                               the boundary — O(window) instead of O(history);
#                                               output provably identical (the walk's break depends
#                                               only on the newest-first prefix; the reorder phase
#                                               only sees the collected prefix). filterCompacted
#                                               (eager, Iterable) keeps its exact signature/behavior
#                                               for existing callers. Optional {pageSize,onPage} test
#                                               seams. Tests: messages-pagination.test.ts (boundary
#                                               stops paging; no-compaction loads all). MUST apply
#                                               after tool-fix (same file, disjoint regions).
#                                               SUNSET: drop if upstream bounds the loop load or
#                                               revives prompt-loop-cache (#25367).
#  18. available-cache.patch (local)          - herd-collapse cache for CatalogV2 provider/model
#                                               availability (bead workstation-g3iy, layer 2).
#                                               Even with integration-list-batch, every /api/model
#                                               call recomputes the full availability projection —
#                                               ~5,331 projectModel() constructions + sort = ~300ms
#                                               of synchronous JS per call. A TUI SSE reconnect herd
#                                               after a serve restart (every attached TUI refetching
#                                               bootstrap, with retry amplification as the serve
#                                               slows: observed 349 /api/provider+model calls in one
#                                               storm) stacks minutes of blocking JS -> the wedge
#                                               persists. Fix in catalog.ts: provider.available() and
#                                               model.available() serve from
#                                               Effect.cachedInvalidateWithTTL values; every catalog
#                                               rebuild (State finalize, via a TDZ-safe hook) and
#                                               every Integration.Event.Updated (connection changes)
#                                               invalidates; AVAILABLE_CACHE_TTL=30s is only a
#                                               backstop for out-of-band changes (e.g. process.env
#                                               mutation). Herd cost collapses to one recompute per
#                                               invalidation. MUST apply with (order-independent of)
#                                               integration-list-batch; only touches catalog.ts +
#                                               catalog.test.ts. SUNSET: revisit on upstream cutover;
#                                               upstream >= v1.17.13 still recomputes per call as of
#                                               2026-07-04.
#  19. session-door-routes.patch (local)      - Phase 8 server + SDK surface for the front-door TUI
#                                               (bead workstation-mlve.3). (a) event.subscribe group gains
#                                               an optional ?session_ids= query field — REQUIRED because
#                                               HttpApi rejects undeclared query params with 400, so a
#                                               scoped subscribe would 400 without it (the handler already
#                                               reads it raw via event-session-scope). (b) NEW session-
#                                               scoped routes on the session group, so the front door can
#                                               owner-route them by path (a child resolves to the parent's
#                                               owner): GET /session/:id/permissions and GET
#                                               /session/:id/questions (pending lists for the D2 fetch-on-
#                                               reconnect reconcile) + POST /session/:id/questions/:qid/
#                                               reply|reject (mirror the bare /question routes). (c) the
#                                               existing session-scoped permissionRespond gains an optional
#                                               `message` for reject-with-feedback parity. (d) regenerated
#                                               packages/sdk/js/src/v2/gen/{sdk,types}.gen.ts via the tree's
#                                               own generator (script/build.ts → hey-api). Server-only +
#                                               generated SDK; disjoint from every other patch.
#  20. tui-door-attach.patch     (local)      - Phase 8 TUI rewrite (bead workstation-mlve.3), SUPERSEDES
#                                               tui-follow-owner. The attached TUI rides the opaque front
#                                               door: (a) it subscribes to the SESSION-SCOPED
#                                               /event?session_ids=<root ∪ live children> stream instead of
#                                               the /global/event firehose (context/sdk.tsx), wrapping the
#                                               bare payloads into the GlobalEvent envelope the useEvent
#                                               layer expects; (b) it DROPS the client pigeon-/route self-
#                                               resolve (resolveServeUrl/evaluateOwnerDrift) — the door owns
#                                               ownership and drops the SSE leg on a confirmed migration, so
#                                               the client just reconnects to the same door url (D5); (c) D2
#                                               poll GET /session/:root/children (~5s) keeps the set current
#                                               AND reconciles child Session.Info into the store so
#                                               children() renders subagent prompts, with fetch-on-reconnect
#                                               (GET pending permissions+questions) closing the no-replay
#                                               race (a prompt asked in the poll/reconnect gap is lost, not
#                                               late → subagent hang) — CRITICAL; (d) NEW-A resets the
#                                               reconnect backoff only after a stream stays open ≥10s
#                                               (OPENCODE_SSE_MIN_OPEN_MS) + adds jitter; (e) migrates
#                                               permission/question replies to the session-scoped routes
#                                               (permission.respond, session.questionReply/Reject) so the
#                                               door can route them (W5); (f) attach.ts drops the /route
#                                               self-resolve and defaults the url to OPENCODE_FRONTDOOR_URL.
#                                               util/sse.ts keeps the runSseAttempt poll/drifted machinery
#                                               (ported from the removed tui-follow-owner, repurposed for
#                                               child-set changes). MUST apply after attach-route-resolve.
#  21. tui-door-tests.patch      (local)      - NEW-G client contract tripwire (bead workstation-mlve.3):
#                                               packages/sdk/js/test/door-scope.test.ts asserts the client
#                                               subscribes to /event?session_ids= (never /global/event) and
#                                               that permission/question replies + pending reads hit the
#                                               session-scoped door routes. Run by the build-release.yml
#                                               "Phase 8 contract tests" step (build-release ran no tests
#                                               before, so the tripwire would be inert without it).
#  22. session-mcp-routes.patch (local)       - Phase 10 server + SDK surface for session-scoped MCP routes
#                                               (bead workstation-mlve.11). Adds GET /session/:sessionID/mcp,
#                                               POST /session/:sessionID/mcp/:name/connect, and
#                                               POST /session/:sessionID/mcp/:name/disconnect so the front door
#                                               can owner-route MCP status/toggle requests by session. Response
#                                               is process-global (sessionID is a routing key). Includes SDK gen.
#  23. tui-mcp-dialog.patch     (local)      - Phase 10 TUI patch for session-scoped MCP routes
#                                               (bead workstation-mlve.11). Adds fetch-on-dialog-open on mount,
#                                               repoints toggle + post-toggle refresh to session-scoped SDK methods,
#                                               resolves root session ID for child/subagent sessions, and leaves
#                                               bootstrap status call global.
#  24. opus5-adaptive-thinking.patch (PR #38757) - generalize Claude adaptive-thinking gating in
#                                               provider/transform.ts. Upstream commit 2b2aacc9 (in v1.18.5)
#                                               replaces the two-part-version regexes anthropicOpus47OrLater
#                                               (/opus-(\d+)[.-](\d+)/) and anthropicSonnet5OrLater with a single
#                                               anthropicUsesModernAdaptiveThinking that makes the minor OPTIONAL
#                                               (/claude-(?:[a-z]+-)?(\d+)(?:[.-](\d{1,2}))?/), so single-part IDs
#                                               like claude-opus-5 are recognized (major 5 > 4 -> adaptive).
#                                               WHY: on v1.17.13 claude-opus-5 fell through anthropicAdaptiveEfforts
#                                               (=null), so variants() emitted the legacy {thinking:{type:"enabled",
#                                               budgetTokens}} for the high/max variants. Vertex/Anthropic opus-5
#                                               REJECTS type:"enabled" ("use thinking.type.adaptive + output_config.
#                                               effort") -> 400 on any build/plan turn carrying variant high/max.
#                                               Only the transform.ts source hunks are ported (the upstream test hunk
#                                               and the opus-4-5 anthropicEffort/reasoningEffort hunks target a later
#                                               refactor not present in v1.17.13; opus-4-5 keeps its v1.17.13 {effort}
#                                               body via the new anthropicOpus45 predicate). SUNSET: drop on the
#                                               upstream bump to >= v1.18.5.
#  25. tui-reconcile-bound.patch (local)     - PART B (bead workstation-fdb1): bound the TUI's
#                                               fetch-on-reconnect pending reconcile so a PERSISTENT reconcile
#                                               error can no longer brick the TUI. tui-door-attach's
#                                               reconcilePending threw on ANY error, and the throw ends the SSE
#                                               attempt BEFORE the event pump starts -- correct for a transient
#                                               failure (a reconnect delivers only FUTURE events, so a prompt
#                                               asked in the gap is lost, not late), catastrophic for a
#                                               persistent one: throw -> reconnect -> same error -> infinite
#                                               reconnect -> a TUI that never pumps a single event, frozen on a
#                                               spinner until an operator restarts the serve pool (which kills
#                                               every other live session). Adds packages/tui/src/util/reconcile.ts:
#                                               (a) createReconcileGuard counts CONSECUTIVE failures of ANY kind
#                                               (deliberately NO transient/permanent taxonomy) and after N=3
#                                               (OPENCODE_RECONCILE_MAX_FAILURES, riding the loop's existing
#                                               ~1s+~2s jittered backoff) PROCEEDS DEGRADED: swallow, start the
#                                               pump, one toast per episode ("Pending requests unavailable -
#                                               retrying in background"), console.error every degraded attempt for
#                                               post-hoc diagnosis; degraded + the toast latch clear on the first
#                                               successful reconcile; (b) shouldReconnect() drives recovery as a
#                                               slow-cadence FULL RECONNECT (~3 min, OPENCODE_RECONCILE_DEGRADED_
#                                               RETRY_MS) piggy-backed on the existing per-attempt drift poller --
#                                               NOT a periodic re-fetch, which would run concurrently with the
#                                               live pump and break the "injects strictly precede pumped events"
#                                               ordering the reconcile depends on; (c) reconcileDeadline() puts a
#                                               10s deadline (OPENCODE_RECONCILE_TIMEOUT_MS) on the whole batch --
#                                               CRITICAL, because the SDK's default fetch sets req.timeout=false
#                                               and attach passes no override, so a HUNG read would never resolve,
#                                               never reject, and never be counted, leaving `await onOpen` pending
#                                               forever (the bound would never engage at all); ONE AbortSignal.any
#                                               per batch, never per request (bead workstation-lyj0); (d) settleAll
#                                               replaces Promise.all in the per-session fan-out, so one dead child
#                                               session neither aborts its healthy siblings' in-flight reads nor
#                                               lets their injects land after the attempt was torn down. Also:
#                                               sse.ts hands onOpen the per-attempt signal (so teardown actually
#                                               cancels the reconcile instead of leaving stragglers that poison the
#                                               failure counter); sdk.tsx stamps openedAt AFTER the reconcile, not
#                                               before -- stamped before, a reconcile that failed SLOWLY counted as
#                                               ">= OPENCODE_SSE_MIN_OPEN_MS open", reset `attempt` to 0 every
#                                               iteration and collapsed the exponential backoff into a ~1s
#                                               reconnect hammer against an already-sick door; sync.tsx's
#                                               non-blocking bootstrap Promise.all -> allSettled (one rejection
#                                               used to strand status before "complete", silently breaking
#                                               `--session X --fork`, AND surface as an unhandled rejection because
#                                               that promise is void'ed rather than returned into bootstrap's
#                                               .catch). NOTE this redefines status "complete" as ATTEMPTED, not
#                                               LOADED: a failed non-blocking read now yields complete-with-empty
#                                               (logged, not retried). Do not later assume complete => loaded. FIXES A SHIPPED TEST REGRESSION: tui-door-attach calls
#                                               useRoute() in SDKProvider's init but test/fixture/tui-environment
#                                               .tsx provides no RouteProvider, so patched.1..4 shipped with 19 red
#                                               packages/tui tests (clean v1.17.13 = 191 pass/0 fail; patched.4 =
#                                               245 pass/19 fail, every one "Route context must be used within a
#                                               context provider") -- including our own bootstrap-disposed-filter
#                                               test, which had never passed. The fixture now provides
#                                               RouteProvider + ToastProvider. MUST apply LAST (it diffs against
#                                               the full stack; tui-mcp-dialog also edits sync.tsx).
#
# DROPPED on the v1.17 line (see workstation docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md):
#   - integration-list-batch.patch: DROPPED on the v1.17.13 roll-forward (2026-07-06).
#     UPSTREAMED — v1.17.13 Integration.list now does the bulk shape natively:
#     `Map.groupBy(yield* credentials.all(), (c) => c.integrationID)` then one
#     project() per integration, instead of a credentials.list() SELECT per
#     integration. This was the "layer 1" half of the workstation-g3iy wedge fix;
#     it becomes upstream exactly at v1.17.13 (the sunset target called out in
#     bead workstation-hbc3). Layer 2 (available-cache) is still needed: upstream
#     >= v1.17.13 still recomputes the full ~5k-model availability projection per
#     /api/model call.
#   - prompt-loop-cache.patch (#25367) + cache-aligned-compaction.patch (#25100):
#     cost-cache optimizations that touch the rewritten event-sourced prompt.ts/compaction.ts.
#     Not redundant-by-upstreaming (1.17 still full-reloads each loop iteration), but dropped
#     pending a measured cache-economics pass on 1.17 (tracking-cache-costs skill) — whether they
#     still help on the rewritten loop is unknown, and a wrong cache patch silently burns money.
#   - eager-input-streaming.patch: SUPERSEDED by upstream. v1.17.2 transform.ts options() sets
#     toolStreaming=false for @ai-sdk/google-vertex/anthropic and non-claude @ai-sdk/anthropic
#     (better scoped than our patch, which also disabled it for first-party claude).
#   - instance-state-partition.patch: DROPPED on the v1.17.7 cutover. Upstream
#     v1.17.7 ships commit 87c33b3 (fix(plugin): reuse active server for client
#     requests, issue #29772), which routes plugin SDK calls through the active
#     listener so plugins reuse its InstanceStore instead of materializing a
#     second one via the in-process Default webHandler. That was the empirically
#     observed trigger of the Question-tool hang. NOTE: upstream KEPT
#     Layer.makeMemoMapUnsafe() at server.ts:125 (the narrow plugin-bridge, not
#     our memoMap approach; the unmerged share-listener-runtime branch = our
#     approach was NOT taken). Verified droppable via upstream regression test
#     (httpapi-listen.test.ts "plugin client requests reuse the listening server
#     instance") + live Question-tool repro on v1.17.7-patched. See
#     docs/plans/2026-06-15-v1.17.7-cutover-drop-instance-partition-{design,plan}.md.
#   - mcp-reconnect.patch: 1.17 remote MCP connection is oauth-aware (McpOAuthProvider + SSE
#     fallback + connectTransport Effect); the patch's naive inline transport reconnect bypasses
#     oauth and can't call the Effect connect helpers from an async execute() without re-architecting
#     through EffectBridge. Deferred (QoL, not safety-critical).
#
# History (v1.15 line): the big caching.patch (opencode-cached PR #5422) was dropped 2026-06-02
# (upstream applyCaching does the moving-tail anchor); bus-eager-subscribe (#27959) + bus
# instance-context (#28051) dropped as upstream-merged in v1.15.5+; prefill-fix dropped at v1.15.12.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Error: Missing argument"
  echo "Usage: $0 <path-to-opencode-source>"
  exit 1
fi

SOURCE_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source directory not found: $SOURCE_DIR"
  exit 1
fi

cd "$SOURCE_DIR"

# Ordered patch list. Order matters where patches touch the same file:
# gemini-empty-parts and cache-thinking-skip both edit provider/transform.ts in
# disjoint regions, and gemini-empty-parts must apply first.
PATCHES=(
  gemini-empty-parts
  tool-fix
  cache-thinking-skip
  retry-cap
  vim
  sqlite-foreign-key-wrap
  event-session-scope
  createnext-readback
  serve-lease
  attach-route-resolve
  bootstrap-disposed-filter
  event-cold-start-directory
  project-copy-debounce
  step-end-diff-bound
  globalbus-maxlisteners
  event-log-gate
  compaction-bounded-load
  available-cache
  session-door-routes
  tui-door-attach
  tui-door-tests
  session-mcp-routes
  tui-mcp-dialog
  opus5-adaptive-thinking
  tui-reconcile-bound
)

for name in "${PATCHES[@]}"; do
  patch="$SCRIPT_DIR/$name.patch"
  if [ ! -f "$patch" ]; then
    echo "❌ Patch file not found: $patch"
    exit 1
  fi
  echo "Applying $name.patch..."
  if ! git apply --check "$patch" 2>/dev/null; then
    echo ""
    echo "❌ $name PATCH FAILED TO APPLY"
    echo ""
    echo "Attempting to apply for diagnostics..."
    git apply "$patch" 2>&1 || true
    echo ""
    echo "Failed files (.rej):"
    find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
    echo ""
    echo "The $name patch may need updating for this upstream version."
    exit 1
  fi
  git apply "$patch"
  echo "✓ $name patch applied"
done

echo ""
echo "✓ All patches applied successfully"
echo ""
echo "Files modified:"
git status --short
