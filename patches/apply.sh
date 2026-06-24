#!/usr/bin/env bash
# Apply local patches to opencode source for the v1.17 release line.
# Usage: ./apply.sh <path-to-opencode-source>
#
# TARGET UPSTREAM: opencode v1.17.7
#
# PATCH SET (v1.17 line, rebased 2026-06-11 from the v1.15 line):
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
#
# DROPPED on the v1.17 line (see workstation docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md):
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
  event-cold-start-directory
  project-copy-debounce
  step-end-diff-bound
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
