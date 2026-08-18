#!/usr/bin/env bash
# Apply local patches to opencode source for the v1.18 release line.
# Usage: ./apply.sh <path-to-opencode-source>
#
# TARGET UPSTREAM: opencode v1.18.18
#
# PATCH SET (v1.18 line; rebased 2026-06-11 from the v1.15 line, rolled forward
# v1.17.7 -> v1.17.13 on 2026-07-06, and v1.17.13 -> v1.18.18 on 2026-08-14 to
# pick up the 48-bit message-ID wrap fix db581e47a3 that muted live sessions --
# see workstation docs/plans/2026-08-14-opencode-118-rollforward-research.md).
#
# NUMBERING IS A STABLE IDENTITY, NOT A POSITION: a dropped patch keeps its
# number as a tombstone (see 4, 15, 24) and new patches take the next free
# number, so header numbers do NOT track the apply order in PATCHES below.
#   1. gemini-empty-parts.patch   (PR #28669) - pad empty Gemini/Vertex parts arrays
#                                               (gemini.ts lowerMessages + transform.ts normalizeMessages)
#   2. tool-fix.patch             (PR #16751) - synthetic step-start boundaries (tool_use/result mismatch)
#   3. cache-thinking-skip.patch  (#17883)    - cache breakpoint scans past trailing thinking/reasoning blocks
#   4. retry-cap.patch            REMOVED (2026-08-14, v1.18.18 roll-forward) — UPSTREAMED.
#                                               Upstream commit c78986831c (in v1.18.17) adds its own
#                                               retry cap. Verified BY CONTENT at the tag, not by
#                                               `git tag --contains` (unreliable on this repo, history
#                                               rewritten). Upstream MAX=5 is STRICTER than our 8, and
#                                               our patch was a cap where upstream previously had NONE,
#                                               so accepting upstream is strictly safer. Do not
#                                               re-litigate 5-vs-8.
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
#  24. opus5-adaptive-thinking.patch REMOVED (2026-08-14, v1.18.18 roll-forward) — UPSTREAMED.
#                                               Upstream commit 2b2aacc939 (in v1.18.5) replaces the
#                                               two-part-version regexes with a single predicate that
#                                               makes the minor OPTIONAL, so single-part ids like
#                                               claude-opus-5 are recognized natively. Verified by
#                                               content at v1.18.18.
#                                               DO NOT HAND-PORT the old hunk #3. Upstream moved PAST
#                                               our port to anthropicOpus45Effort() with real
#                                               budgetTokens; re-applying our version REGRESSES
#                                               opus-4-5. This tombstone exists mainly to say that.
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
#  26. registry-port-fence.patch (local)    - refuse to claim a pool slot this process does not own,
#                                               and fence markDead on identity so a restarting serve
#                                               cannot evict the live owner of its old port. Previously
#                                               undocumented in this list -- added here while numbering
#                                               the next patch, since an undocumented entry is how the
#                                               list silently stops describing the build.
#
#  27. plugin-loader-observability.patch (local) - make plugin load failures OBSERVABLE (bead
#                                               workstation-5yox step 3a). The loader could fail to load
#                                               a plugin and emit NOTHING ANYWHERE: report.error routes
#                                               every stage to publishPluginError, which only publishes a
#                                               Session.Event.Error that no log sink observes, and
#                                               report.missing is a bare no-op that does not even do that.
#                                               MEASURED on a real serve against three broken plugins: the
#                                               unpatched binary produced 0 log lines, 0 level=ERROR lines
#                                               and 118 bytes of stdout while answering HTTP 200. On this
#                                               host that silence covers 8 of the 9 deployed plugin files,
#                                               including two mkOutOfStoreSymlinks into other repos'
#                                               live checkouts that have no build-time cover at all.
#                                               Adds (a) logPluginError(), a structured logError beside the
#                                               existing publishPluginError, called from ALL FOUR
#                                               report.error stages AND from report.missing; (b) an INFO
#                                               "plugin loaded" line per successfully applied plugin --
#                                               INFO because a production log carries zero DEBUG lines, so
#                                               DEBUG would not be emitted at all. Deliberately reuses the
#                                               EXACT message text ("failed to load plugin") and `path`
#                                               field of the pre-existing load-failure logError, so a log
#                                               consumer needs no change to gain the new shapes; `stage`
#                                               is appended to distinguish them for a human. Note an
#                                               import-time throw arrives as stage "load", not the "entry"
#                                               one might predict -- which is why all stages are covered
#                                               rather than the interesting-looking one.
#                                               Tests: test/plugin/loader-observability.test.ts, run by the
#                                               "Plugin loader observability tests" step in
#                                               build-release.yml -- a patch-carried test that no workflow
#                                               names is inert. Verified non-vacuous by mutation: with the
#                                               source hunks reverted all 4 go red.
#                                               Disjoint from every other patch (no other patch touches
#                                               plugin/{index,loader,shared}.ts), so order-independent.
#                                               SUNSET: drop if upstream merges the equivalent; an upstream
#                                               PR carries the same three changes.
#
#  28. message-serve-provenance.patch (local) - stamp WHICH SERVE created an assistant row, so the
#                                               phantom-busy sweeper can finalize an orphan promptly
#                                               instead of deferring it up to ~24h (bead
#                                               workstation-63wo, the build branch of a pre-committed
#                                               decision rule).
#                                               A serve killed abruptly (kernel OOM, canary SIGKILL,
#                                               crash) never runs cleanup, leaving an assistant row with
#                                               time.completed unset and no error -- the session then
#                                               shimmers "working" forever in every TUI that loads it,
#                                               ~1 core each. The sweeper may only finalize such a row
#                                               once it is certain the CREATING process is gone, and
#                                               nothing in the row said who that was, so it fell back to
#                                               "older than the OLDEST live pool member" -- which cannot
#                                               see a fresh single-member orphan until the nightly
#                                               whole-pool restart.
#                                               Stamps {serveId, invocationId, port, pid} into the
#                                               assistant row's data blob in messageData(), the SINGLE
#                                               upsert path for both creation and every later update --
#                                               so it covers every assistant row the sweeper can sweep
#                                               (main agent loop, subtasks, compaction), and re-stamps on
#                                               each update so the stamp names the LAST writer. NOT shell
#                                               messages: those go through SessionMessageUpdater into the
#                                               separate session_message table, which the sweeper never
#                                               reads. MEASURED reason the choke point matters: of 91
#                                               sessions invisible to the front-door log in 24h, 60 were
#                                               subagent children, so a main-loop-only stamp would have
#                                               missed most of the orphan population.
#                                               Last-writer rather than creator is deliberate: a writer
#                                               is alive at the instant it writes, so a stamp naming a
#                                               DEAD invocation proves nothing has touched the row since
#                                               that invocation died. The else-branch STRIPS a foreign
#                                               stamp when the gate declines -- without it a declining
#                                               process would carry someone else's identity forward
#                                               (`serve` is a declared field, so it survives a
#                                               decode/re-publish cycle) and the row would name a process
#                                               that is not its last writer.
#                                               Keyed on systemd's INVOCATION_ID, NOT pid and NOT a
#                                               timestamp: the unit's MainPID is a wrapper script so
#                                               process.pid != MainPID, and Date.now() at start never
#                                               equals ActiveEnterTimestamp -- either comparison would
#                                               judge every LIVE row dead and abort running turns.
#                                               Verified on cloudbox that INVOCATION_ID reaches the
#                                               process and matches `systemctl show -p InvocationID`,
#                                               4/4 pool members.
#                                               THE GATE ESTABLISHES FATE-SHARING, NOT ANCESTRY, and the
#                                               obvious env-only version is WRONG -- adversarial review
#                                               falsified it by measurement. env vars say "descended from
#                                               a serve"; the stamp needs "dies with that serve". Every
#                                               agent tool subprocess inherits OPENCODE_SERVE_ID *and*
#                                               INVOCATION_ID while running in its own transient scope
#                                               under oc-agent.slice (workstation-yt0p), so it OUTLIVES a
#                                               serve restart and carries a scope invocation id that
#                                               appears in no opencode-serve@* unit -- measured: a tool
#                                               call reporting serve-3 with INVOCATION_ID=21efa50c...
#                                               while its serve was 8b8f626a.... Any opencode core process
#                                               started from there (`opencode run`, `opencode debug
#                                               agent`) boots the projector and would stamp an
#                                               always-dead-looking invocation onto LIVE rows, and the
#                                               sweeper would abort a running turn -- a case today's
#                                               min-cutoff gate handles CORRECTLY, so an env-only gate
#                                               would have made things strictly worse, not additive.
#                                               So the gate additionally requires /proc/self/cgroup to
#                                               name opencode-serve@<port>.service. With the default
#                                               KillMode=control-group everything in that cgroup dies
#                                               with the unit, which makes "invocation dead => writer
#                                               dead" true by systemd mechanics rather than env hygiene.
#                                               Outside it: no stamp, and the sweeper keeps its old
#                                               conservative cutoff -- so the change IS additive.
#                                               Inert on macOS (launchd sets OPENCODE_SERVE_ID but gives
#                                               no INVOCATION_ID and has no /proc/self/cgroup), which is
#                                               the correct outcome there.
#                                               Tests: test/session/serve-provenance{,-gate}.test.ts,
#                                               named by a step in build-release.yml -- a patch-carried
#                                               test that no workflow names is inert. 16 tests. Verified
#                                               non-vacuous by mutating the PRODUCTION lines one at a
#                                               time, not just the gate helper: removing the cgroup check
#                                               turns 5 red, removing the stamping block 1, removing the
#                                               strip else-branch 1.
#                                               NO REPLAY HAZARD (checked, because a re-projection would
#                                               re-stamp a dead row with a live identity and un-sweep the
#                                               worst rows): projector handlers run only inside the
#                                               transaction that FIRST persists an event; the replay path
#                                               dedupes and returns at event.ts:282 before reaching them.
#                                               The machinery that could change this is remove() plus
#                                               replayAll(); nothing calls that combination today.
#                                               Touches projector.ts, which sqlite-foreign-key-wrap also
#                                               patches, but at disjoint hunks (that one at ~23/270/321,
#                                               this at ~75); ordered after it regardless.
#  29. globalbus-maxlisteners.patch (local)  - raise the process-global EventEmitter max-listener
#                                               ceiling so a long-lived serve with many concurrent
#                                               sessions stops emitting MaxListenersExceededWarning
#                                               (bead workstation-qjk4). Applied since the v1.17 line
#                                               but never given a header entry; documented here on the
#                                               v1.18.18 roll-forward (bead workstation-dqng).
#                                               NOTE FOR THE NEXT PATCH AUTHOR: 29 is now TAKEN.
#                                               opencode-patched PR #42 (db-isolation-guard, held out
#                                               of this release deliberately) also claims 29 and must
#                                               renumber to 30 before it lands.
#
# DROPPED on the v1.18.18 roll-forward (2026-08-14; full rationale lives in the
# numbered tombstones above, not duplicated here):
#   - retry-cap.patch            -> tombstone  4. UPSTREAMED c78986831c / v1.18.17.
#   - opus5-adaptive-thinking.patch -> tombstone 24. UPSTREAMED 2b2aacc939 / v1.18.5.
#     Do NOT hand-port its hunk #3; doing so regresses opus-4-5.
#
#  30. db-isolation-guard.patch  (local)     - refuse to open a database that XDG_DATA_HOME says
#                                               should be isolated (incident 2026-08-14).
#                                               PRECEDENCE BUG: Database.path() checks
#                                               Flag.OPENCODE_DB FIRST and returns it verbatim when
#                                               absolute, BEFORE Global.Path.data (the only thing
#                                               XDG_DATA_HOME feeds) is consulted. On any host that
#                                               exports OPENCODE_DB as a session variable — ours does,
#                                               to defeat the channel-suffixed opencode-<channel>.db
#                                               default — every child inherits it, so the documented
#                                               "throwaway serve with XDG_DATA_HOME pointed at a COPY
#                                               of the DB" recipe isolates logs, config, state and
#                                               storage while the DATABASE stays production. The
#                                               scratch logfile lands exactly where expected, so the
#                                               isolation LOOKS like it worked; on 2026-08-14 a
#                                               throwaway serve mutated live session rows this way and
#                                               an assertion against the never-opened copy returned a
#                                               clean "0 rows" FALSE GREEN.
#                                               Guards the analogous hazard to the OPENCODE_SERVE_ID /
#                                               OPENCODE_ROUTING_DB fence in serve.ts (registry-port-
#                                               fence), which already refuses to start on an inherited
#                                               pool identity. That one corrupts a routing table; this
#                                               one writes the production database — the more dangerous
#                                               of the two was the unguarded one.
#                                               ARMED ONLY when XDG_DATA_HOME is explicitly set AND an
#                                               absolute OPENCODE_DB resolves outside it. MEASURED on
#                                               cloudbox 2026-08-14: all four pool serves run with
#                                               XDG_DATA_HOME UNSET (they export OPENCODE_DB +
#                                               OPENCODE_DISABLE_CHANNEL_DB and nothing XDG), so the
#                                               guard is unarmed for every legitimate production
#                                               consumer and CANNOT break the pool. `env -u OPENCODE_DB`
#                                               scratch serves (pkgs/opencode-frontdoor/route-gate.nix,
#                                               test.sh) are likewise unarmed — already isolated.
#                                               NOT an auto-fix: deriving the DB path from
#                                               XDG_DATA_HOME when the two disagree would silently
#                                               repoint the database of any process that sets
#                                               XDG_DATA_HOME for unrelated reasons, reintroducing the
#                                               split-brain that pinning OPENCODE_DB exists to prevent.
#                                               Trading a silent write to the wrong DB for a silent
#                                               write to a different wrong DB is not an improvement.
#                                               Escape hatch OPENCODE_DB_ALLOW_FOREIGN_XDG=1 downgrades
#                                               FATAL to a once-per-process WARNING.
#                                               Enforced in packages/core/src/database/database.ts
#                                               path() — the SINGLE choke point every consumer goes
#                                               through (serve, run, TUI, `db path`, stats, import) —
#                                               before any handle is opened; exits 22. Decision logic
#                                               lives in packages/core/src/database/isolation.ts with
#                                               NO imports beyond node builtins, so its 14 tests
#                                               (packages/core/test/database/isolation.test.ts) run
#                                               without a workspace install.
#                                               Touches database/database.ts, which no other patch
#                                               modifies (serve-lease only NAMES it in a comment), so
#                                               it is order-independent; listed last.
#                                               Applies clean to BOTH v1.17.13 (on top of the full
#                                               stack) and v1.18.18, so it survives the roll-forward.
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
  tui-reconcile-bound
  registry-port-fence
  plugin-loader-observability
  message-serve-provenance
  db-isolation-guard
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
