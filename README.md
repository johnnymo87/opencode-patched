# opencode-patched

**OpenCode with [Gemini empty parts fix](https://github.com/anomalyco/opencode/pull/28669) + [tool use/result fix](https://github.com/anomalyco/opencode/pull/16751) + [cache thinking-skip](https://github.com/anomalyco/opencode/issues/17883) + retry cap (local) + [vim keybindings](https://github.com/anomalyco/opencode/pull/12679)**

This repository layers a small set of local patches onto upstream OpenCode and builds a single binary automatically for 4 platforms.

## Patches Included

> **Prompt caching is now upstream.** The big `caching.patch` (formerly fetched at
> build time from [opencode-cached](https://github.com/johnnymo87/opencode-cached),
> [PR #5422](https://github.com/anomalyco/opencode/pull/5422)) was **dropped on
> 2026-06-02**. Upstream `applyCaching` already anchors the conversation cache
> breakpoint on the moving tail (`non-system.slice(-2)`), so the fork patch was
> redundant — and the fork's own unmerged variant had actually *introduced* an
> anchor regression. The only behavior upstream lacks (not marking a trailing
> reasoning/thinking block as the cache breakpoint) is preserved as the small local
> `cache-thinking-skip.patch`, section 3 below. `opencode-cached` has been archived.
> See `docs/plans/2026-06-02-paring-back-opencode-cached-caching.md` in the
> workstation repo for the analysis.

### 1. Gemini Empty Parts Fix ([PR #28669](https://github.com/anomalyco/opencode/pull/28669), [Issue #17519](https://github.com/anomalyco/opencode/issues/17519))

Stored locally as `patches/gemini-empty-parts.patch`. Vertex/Gemini rejects any
`contents[]` entry with `parts: []` with `Unable to submit request because it must
include at least one parts field`. This patch fixes that on **two independent code
paths**:

- **Native runtime** (`packages/llm/src/protocols/gemini.ts`): pads completely
  empty Gemini user, assistant, or tool messages with an empty-string text part
  before serialization. This is the PR #28669 fix, extended to cover an empty
  tool-message regression. NOTE: the native runtime gate
  (`session/llm/native-runtime.ts`) only admits `openai`/`anthropic`/`opencode*`
  providers, so Gemini never actually reaches this path today — this hunk tracks
  PR #28669 and is future-proofing if upstream ever routes Gemini natively.

- **AI SDK runtime** (`packages/opencode/src/provider/transform.ts`): this is the
  path Gemini actually uses (`google-vertex` / `google` via `@ai-sdk/google`).
  `ProviderTransform.message()` → `normalizeMessages()` now drops empty
  text/reasoning parts and any resulting empty message for `@ai-sdk/google` /
  `@ai-sdk/google-vertex`, exactly like the pre-existing `@ai-sdk/anthropic` and
  `@ai-sdk/amazon-bedrock` blocks. The `@ai-sdk/google` converter drops
  empty-text parts itself (`part.text.length === 0 ? undefined : ...`), so a turn
  whose only content is an empty part — e.g. the empty "structural separator"
  text part that Anthropic adaptive-thinking turns persist between `step-start`
  boundaries, replayed cross-model into a Gemini compaction request — serializes
  to `parts: []` and 400s the whole request. This is the intermittent
  compaction failure tracked in Issue #17519; the original `packages/llm` hunk
  alone never fixed it because Gemini doesn't use that path.

### 2. Tool Use/Result Mismatch Fix ([PR #16751](https://github.com/anomalyco/opencode/pull/16751))

Stored locally as `patches/tool-fix.patch`. Fixes the widespread `tool_use ids were found without tool_result blocks` error ([#16749](https://github.com/anomalyco/opencode/issues/16749)) that corrupts sessions when stream errors cause lost step boundaries. Injects synthetic step-start boundaries at message reconstruction time to prevent interleaved tool_use/text in assistant messages that the Anthropic API rejects.

### 3. Cache Thinking-Skip ([Issue #17883](https://github.com/anomalyco/opencode/issues/17883))

Stored locally as `patches/cache-thinking-skip.patch`. This is the **only
caching-related patch** that survived the 2026-06-02 drop of the big `caching.patch`
(see the note at the top of this section). Upstream `applyCaching` marks the
conversation cache breakpoint on `msg.content[msg.content.length - 1]` — blindly the
last content block. When the last block is a `reasoning`/`redacted-reasoning`
(thinking) block, Anthropic rejects the request with HTTP 400 because `cache_control`
isn't allowed on thinking blocks. This bites whenever adaptive reasoning is on (Opus
4.7+/4.8). The patch makes the breakpoint scan backwards to the last *cacheable*
content block instead, skipping trailing reasoning and tool-approval pseudo-blocks.

It's a ~15-line change to `applyCaching` in `provider/transform.ts`. Tracked upstream
as Issue [#17883](https://github.com/anomalyco/opencode/issues/17883); when upstream
fixes it, this patch can be dropped.

### 4. Retry Cap (local)

Stored locally as `patches/retry-cap.patch`. Caps the number of per-step model-stream re-issues at `MAX_RETRIES = 8`. Each retry is a full, billable provider request, so an uncapped schedule turned any persistently-retryable condition into an unbounded burst of provider calls — the runaway behind the 2026-06 Vertex/Gemini cost surge.

It also adds *downward-only* jitter (`RETRY_JITTER_RATIO = 0.2`) to the no-header exponential backoff so concurrent stuck sessions don't re-issue their streams in lockstep against a shared quota (avoiding a thundering herd). Explicit `retry-after` / `retry-after-ms` hints are honored exactly and never jittered.

Sunset: drop if upstream ever caps retries natively.

### 5. Vim Keybindings ([PR #12679](https://github.com/anomalyco/opencode/pull/12679))

Stored locally as `patches/vim.patch`. Adds optional vim motions to the prompt input. Disabled by default -- enable with `tui.vim: true` or toggle from the command palette.

Supported motions:
- Mode switching: `i I a A o O S`, `cc`, `cw`, `Esc`
- Motions: `h j k l`, `w b e`, `W B E`, `0 ^ $`
- Deletes: `x`, `dd`, `dw`
- Session navigation: `gg/G`
- Scrolling: `Ctrl+e/y/d/u/f/b`
- `Enter` in normal mode submits

## DROPPED patches (sunset history)

- **instance-state-partition.patch** — DROPPED on the v1.17.7 cutover. Upstream v1.17.7 ships commit `87c33b3` (`fix(plugin): reuse active server for client requests`, issue #29772), which routes plugin SDK calls through the active listener so plugins reuse its `InstanceStore` instead of materializing a second one via the in-process `Default` webHandler (the empirically observed trigger of the Question-tool hang). NOTE: upstream KEPT `Layer.makeMemoMapUnsafe()` at `server.ts:125` (the narrow plugin-bridge, not our memoMap approach; the unmerged `share-listener-runtime` branch = our approach was NOT taken). Verified droppable via upstream regression test (`httpapi-listen.test.ts` "plugin client requests reuse the listening server instance") + live Question-tool repro on v1.17.7-patched. See `docs/plans/2026-06-15-v1.17.7-cutover-drop-instance-partition-{design,plan}.md`.
- **prompt-loop-cache.patch (PR #25367)** — DROPPED on the v1.17.0 cutover. Cost-cache optimization touching the rewritten event-sourced `prompt.ts`; deferred pending a measured cache-economics pass on the 1.17 loop.
- **cache-aligned-compaction.patch (PR #25100)** — DROPPED on the v1.17.0 cutover. Cost-cache optimization touching the rewritten event-sourced `compaction.ts`; deferred pending a measured cache-economics pass on the 1.17 loop.
- **eager-input-streaming.patch** — DROPPED on the v1.17.0 cutover. SUPERSEDED by upstream — v1.17.2 `transform.ts` `options()` already sets `toolStreaming=false` for `@ai-sdk/google-vertex/anthropic` and non-claude `@ai-sdk/anthropic` (better scoped than our patch).
- **mcp-reconnect.patch** — DROPPED on the v1.17.0 cutover. Upstream 1.17 remote MCP is OAuth-aware (`McpOAuthProvider` + SSE fallback + Effect `connectTransport`); the patch's naive inline reconnect bypasses OAuth, so this is deferred.
- **caching.patch (PR #5422, via opencode-cached)** — DROPPED on 2026-06-02. Upstream `applyCaching` already implements the moving-tail conversation anchor (`non-system.slice(-2)`) that was the ~$500/day win, so the ~1100-line fork patch was redundant; the fork's own unmerged variant ([PR #5422](https://github.com/anomalyco/opencode/pull/5422)) had even *introduced* a stuck-anchor regression. A/B testing confirmed upstream matches the fork on Vertex (0% uncached input, low cache-write, no tool-prefix busting), so `sortTools` + the dedicated tool breakpoint were not load-bearing for our toolset, and the 1h-TTL tiering was marginal (~$27/day) on a workload that is 92–96% sub-5-minute turns. The single behavior worth keeping — skipping reasoning/thinking blocks at the cache breakpoint — survives as `cache-thinking-skip.patch` (section 3). The sibling repo `opencode-cached` was archived. Full analysis: `docs/plans/2026-06-02-paring-back-opencode-cached-caching.md` (workstation repo).
- **bus-eager-subscribe.patch (PR #27959)** — DROPPED on 2026-05-25 when this repo cut over from v1.15.0 to v1.15.10. PR #27959 (`fix(bus): acquire PubSub subscription eagerly`) was merged upstream on 2026-05-18 and shipped in v1.15.5. Any opencode release >= v1.15.5 contains the fix natively.
- **Bus instance context fix (PR #28051)** — never had its own patch in this repo, but the closely-related bug it fixes (sync events publishing on the wrong bus runtime, partitioning `message.updated` from `session.idle` across plugin instances) was the root cause of dropped Telegram stop notifications throughout April/May 2026. The load-bearing fix is actually PR #27825 (`fix(sync): publish events on injected project bus`), with #27757, #28051, and #28187 as supporting changes. ALL of these are in v1.15.5+. See `docs/plans/2026-05-22-bus-fix-investigation-HANDOFF.md` and `docs/plans/2026-05-25-28051-verification-report.md` in the pigeon repo for the full investigation chain.
- **prefill-fix.patch** — DROPPED on 2026-05-28 when this repo cut over to v1.15.12. v1.15.12's release notes line *"Used the persisted session directory for existing-session requests"* corresponds to an upstream implementation of the same fix in `packages/opencode/src/server/routes/instance/httpapi/middleware/workspace-routing.ts`: `planRequest`'s `Local` plan construction now does `directory: session?.directory || defaultDirectory(request, url)`, which closes the multi-cwd race our patch did by routing session-bound requests to the session's canonical directory. Upstream's implementation collapses the choice into the existing `directory` field rather than threading our richer `sessionDirectory` value through `RequestPlan.Local` + `WorkspaceRouteContext` + `InstanceContextMiddleware`, but the net behavior matches. See `docs/plans/2026-05-15-prefill-fix-redesign-{plan,question,answer}.md` for the original v1.15.0 redesign and `docs/plans/2026-04-21-opencode-prefill-fix-design.md` (workstation repo) for the root-cause analysis.

## Installation

### Linux (arm64)

```bash
curl -sL https://github.com/johnnymo87/opencode-patched/releases/latest/download/opencode-linux-arm64.tar.gz | tar xz
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### Linux (x64)

```bash
curl -sL https://github.com/johnnymo87/opencode-patched/releases/latest/download/opencode-linux-x64.tar.gz | tar xz
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### macOS (arm64)

```bash
curl -sL https://github.com/johnnymo87/opencode-patched/releases/latest/download/opencode-darwin-arm64.zip -o opencode.zip
unzip opencode.zip
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### macOS (x64)

```bash
curl -sL https://github.com/johnnymo87/opencode-patched/releases/latest/download/opencode-darwin-x64.zip -o opencode.zip
unzip opencode.zip
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### Nix

See the [workstation repo](https://github.com/johnnymo87/workstation) for Nix integration example.

## How It Works

```
Timing Chain (every 8 hours):

(upstream anomalyco/opencode publishes a release)

:01  opencode-patched/sync-upstream   -- detects new upstream release directly
        |-> builds v{VER}-patched       -- applies gemini-empty-parts + tool-fix + cache-thinking-skip + retry-cap + vim patches, publishes
:01  opencode-patched/sync-vim-pr     -- checks PR #12679 for changes
:01  opencode-patched/sync-tool-fix-pr -- checks PR #16751 for changes

:02  workstation/update-opencode-patched -- updates Nix config, opens PR
```

Until 2026-06-02 this chain had an extra upstream hop: `opencode-cached/sync-upstream`
built a `v{VER}-cached` release (applying the big `caching.patch`), and
`opencode-patched/sync-cached` watched *that*. With `caching.patch` dropped and
`opencode-cached` archived, `sync-cached.yml` was replaced by `sync-upstream.yml`,
which watches `anomalyco/opencode` releases directly.

### Build Process

1. Clone upstream OpenCode at the release tag
2. Apply the local patches in order: `gemini-empty-parts.patch`, `tool-fix.patch`, `cache-thinking-skip.patch`, `retry-cap.patch`, `vim.patch` (see `patches/apply.sh`)
3. Build with Bun for 4 platforms (linux/darwin x arm64/x64)
4. Publish release as `v{VERSION}-patched`

### Patch Independence

The patches modify different areas of the codebase:
- **Gemini empty parts**: `packages/llm/src/protocols/gemini.ts`, `packages/opencode/src/provider/transform.ts`
- **Tool fix**: `session/message-v2.ts`
- **Cache thinking-skip**: `provider/transform.ts` (the `applyCaching` breakpoint loop)
- **Retry cap**: `packages/opencode/src/session/retry.ts`, `packages/opencode/test/session/retry.test.ts`
- **Vim**: `cli/cmd/tui/...`

The file touched by more than one patch is `provider/transform.ts` (gemini-empty-parts in `normalizeMessages()` and cache-thinking-skip in `applyCaching()`). The overlapping patches modify disjoint regions and apply cleanly in the documented order.

## Patch Ownership

Each patch is owned by a specific repo. Do not edit a patch in the wrong repo.

| Patch | Owned by | Upstream PR guide |
|-------|----------|-------------------|
| `gemini-empty-parts.patch` | **this repo** (`patches/gemini-empty-parts.patch`) | PR #28669 |
| `tool-fix.patch` | **this repo** (`patches/tool-fix.patch`) | PR #16751 |
| `cache-thinking-skip.patch` | **this repo** (`patches/cache-thinking-skip.patch`) | Issue #17883 |
| `retry-cap.patch` | **this repo** (`patches/retry-cap.patch`) | local / original, no upstream PR |
| `vim.patch` | **this repo** (`patches/vim.patch`) | PR #12679 |

When an upstream PR is merged, the corresponding patch can be dropped. (The big
`caching.patch` formerly lived in the sibling repo `opencode-cached`; it was dropped
and that repo archived on 2026-06-02 — see the note at the top of "Patches Included".)

## Maintenance

### When the Cache Thinking-Skip Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

The patch targets `applyCaching` in `packages/opencode/src/provider/transform.ts`. If
upstream refactors that function, re-derive the hunk: the patch replaces the blind
`const lastContent = msg.content[msg.content.length - 1]` breakpoint pick with a
backward scan to the last *cacheable* block (skipping `reasoning`,
`redacted-reasoning`, and `tool-approval-*` blocks).

1. Check whether upstream has fixed [Issue #17883](https://github.com/anomalyco/opencode/issues/17883); if yes, remove `patches/cache-thinking-skip.patch` and update `patches/apply.sh`
2. If absent, re-derive the backward-scan hunk against the new `applyCaching`
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Gemini Empty Parts Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

The patch has **two hunks on two code paths** (see section 1 above); a refresh
must keep both unless upstream has fixed the corresponding path.

- **`packages/llm/src/protocols/gemini.ts`** (native runtime): use PR
  [#28669](https://github.com/anomalyco/opencode/pull/28669) as the behavioral
  guide. Pads empty user/assistant/tool messages with an empty-string text part.
- **`packages/opencode/src/provider/transform.ts`** (AI SDK runtime, the path
  Gemini actually uses): a `@ai-sdk/google` / `@ai-sdk/google-vertex` block in
  `normalizeMessages()` that drops empty text/reasoning parts and resulting-empty
  messages, mirroring the sibling `@ai-sdk/anthropic` / `@ai-sdk/amazon-bedrock`
  blocks. Tracked by Issue [#17519](https://github.com/anomalyco/opencode/issues/17519).
  Behavioral check: run `bun test test/provider/transform.test.ts -t "gemini empty parts"`
  from `packages/opencode`.

1. Check whether upstream already handles empty Gemini parts on **both** paths.
2. If a path is fixed upstream: drop that hunk; if both are fixed, remove
   `patches/gemini-empty-parts.patch` and update `patches/apply.sh`.
3. If absent: refresh the failing hunk (regenerate the `packages/llm` hunk from
   PR #28669, keep the empty tool-message regression coverage; re-derive the
   `transform.ts` hunk against the plain upstream + gemini ordering).
4. Review, commit, push.
5. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Vim Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

Use PR [#12679](https://github.com/anomalyco/opencode/pull/12679) as the behavioral guide when rebasing: the PR defines the intended vim motions and config surface. Port only behavior still missing upstream; drop anything already present.

1. Fetch the PR as a behavioral reference: `gh pr diff 12679 --repo anomalyco/opencode > /tmp/vim-pr-12679.patch`
2. Rebase `patches/vim.patch` onto the new upstream, using the PR diff as the source of truth for intended behavior
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Vim PR Drifts (Review Signal, Not Breakage)

`sync-vim-pr.yml` checks every 8 hours whether PR #12679's raw diff matches `patches/vim.patch`.
If the hashes differ, it opens a GitHub issue labeled `patch-drift`.

**Drift does not mean the build is broken.** The build continues to use the committed
`patches/vim.patch` as-is. The build/release workflow is the source of truth for whether
publication is blocked. The drift issue is a prompt to review what changed upstream and
decide whether to adopt it.

### When the Tool Fix Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

Use PR [#16751](https://github.com/anomalyco/opencode/pull/16751) as the behavioral guide when refreshing. If the upstream release already includes the fix (verify by running the regression test), **drop `patches/tool-fix.patch` entirely** rather than refreshing it.

1. Check whether upstream already has the fix: run the regression test from PR #16751 against a plain upstream checkout
2. If fix is present upstream: remove `patches/tool-fix.patch` and update `patches/apply.sh`
3. If fix is absent: regenerate from the PR: `gh pr diff 16751 --repo anomalyco/opencode > patches/tool-fix.patch`
4. Review, commit, push
5. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Tool Fix PR Drifts (Review Signal, Not Breakage)

`sync-tool-fix-pr.yml` checks every 8 hours whether PR #16751's raw diff matches `patches/tool-fix.patch`.
If the hashes differ, it opens a GitHub issue labeled `patch-drift`.

**Drift does not mean the build is broken.** The build continues to use the committed
`patches/tool-fix.patch` as-is. The build/release workflow is the source of truth for whether
publication is blocked. The drift issue is a prompt to review what changed upstream and
decide whether to adopt it.

### When the Retry Cap Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

The patch targets `packages/opencode/src/session/retry.ts` to cap model-stream retries at `MAX_RETRIES = 8` and add backoff jitter.

1. Check whether upstream already has retry-capping or configurable retry limits natively; if yes, remove `patches/retry-cap.patch` and update `patches/apply.sh`
2. If absent, re-derive the retry-cap and jitter logic against the new `packages/opencode/src/session/retry.ts`
3. Behavioral check: run `bun test test/session/retry.test.ts` from the `packages/opencode` folder to verify the capping and jitter behavior
4. Review, commit, push
5. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### Sunset Criteria

Monthly automated check (`check-sunset.yml`) monitors all upstream PRs/issues:
- **Any PR merged (or tracked issue closed)**: Drop the corresponding patch from `apply.sh`
- **All merged**: Switch workstation to upstream OpenCode, archive this repo (`opencode-cached` was already archived 2026-06-02)

## Credits

- **OpenCode**: [anomalyco/opencode](https://github.com/anomalyco/opencode)
- **Gemini empty parts PR**: [PR #28669](https://github.com/anomalyco/opencode/pull/28669)
- **Tool fix PR**: [PR #16751](https://github.com/anomalyco/opencode/pull/16751) by [@altendky](https://github.com/altendky)
- **Cache thinking-skip**: [Issue #17883](https://github.com/anomalyco/opencode/issues/17883) -- original patch (formerly part of the now-dropped `caching.patch` / [PR #5422](https://github.com/anomalyco/opencode/pull/5422) by [@ormandj](https://github.com/ormandj))
- **Retry cap**: local / original work
- **Vim PR**: [PR #12679](https://github.com/anomalyco/opencode/pull/12679) by [@leohenon](https://github.com/leohenon)

## License

MIT (same as upstream OpenCode)
