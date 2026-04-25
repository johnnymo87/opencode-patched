# opencode-patched

**OpenCode with [prompt caching](https://github.com/anomalyco/opencode/pull/5422) + [vim keybindings](https://github.com/anomalyco/opencode/pull/12679) + [tool use/result fix](https://github.com/anomalyco/opencode/pull/16751) + [MCP auto-reconnect](https://github.com/anomalyco/opencode/issues/15247) + [eager_input_streaming workaround](https://github.com/anomalyco/opencode/issues/23541)**

This repository combines five patches into a single OpenCode binary, built automatically for 4 platforms.

## Patches Included

### 1. Prompt Caching Improvements ([PR #5422](https://github.com/anomalyco/opencode/pull/5422))

Fetched at build time from [opencode-cached](https://github.com/johnnymo87/opencode-cached). Adds provider-specific cache configuration for 19+ providers, reducing cache write costs by ~44% and effective costs by ~73%.

### 2. Vim Keybindings ([PR #12679](https://github.com/anomalyco/opencode/pull/12679))

Stored locally as `patches/vim.patch`. Adds optional vim motions to the prompt input. Disabled by default -- enable with `tui.vim: true` or toggle from the command palette.

Supported motions:
- Mode switching: `i I a A o O S`, `cc`, `cw`, `Esc`
- Motions: `h j k l`, `w b e`, `W B E`, `0 ^ $`
- Deletes: `x`, `dd`, `dw`
- Session navigation: `gg/G`
- Scrolling: `Ctrl+e/y/d/u/f/b`
- `Enter` in normal mode submits

### 3. Tool Use/Result Mismatch Fix ([PR #16751](https://github.com/anomalyco/opencode/pull/16751))

Stored locally as `patches/tool-fix.patch`. Fixes the widespread `tool_use ids were found without tool_result blocks` error ([#16749](https://github.com/anomalyco/opencode/issues/16749)) that corrupts sessions when stream errors cause lost step boundaries. Injects synthetic step-start boundaries at message reconstruction time to prevent interleaved tool_use/text in assistant messages that the Anthropic API rejects.

### 4. MCP Auto-Reconnect ([Issue #15247](https://github.com/anomalyco/opencode/issues/15247))

Stored locally as `patches/mcp-reconnect.patch`. Automatically reconnects remote MCP servers when the server restarts and the session becomes stale. Without this patch, `callTool` fails at the transport layer with "Session not found" / HTTP 404 errors, requiring a manual MCP toggle (ctrl+p) or full OpenCode restart.

The patch wraps remote MCP tool execution with a try/catch that detects transport-level errors (stale sessions, connection refused, etc.), closes the stale client, creates a fresh transport + client, refreshes tool definitions, and retries the call once.

### 5. Eager Input Streaming Workaround ([Issue #23541](https://github.com/anomalyco/opencode/issues/23541), [#23257](https://github.com/anomalyco/opencode/issues/23257), [#23767](https://github.com/anomalyco/opencode/issues/23767))

Stored locally as `patches/eager-input-streaming.patch`. Disables `toolStreaming` for all `@ai-sdk/anthropic`-backed providers (including `@ai-sdk/google-vertex/anthropic`).

Since `@ai-sdk/anthropic >= 3.0.58`, the `fine-grained-tool-streaming-2025-05-14` beta header (hardcoded in `provider.ts`) causes the SDK to inject `eager_input_streaming: true` into every tool definition. Anthropic-shape endpoints with strict schema validation (Google Vertex Anthropic, AWS Bedrock proxies, GitHub Copilot's `/v1/messages` shim, corporate gateways) reject the unknown field with HTTP 400:

```
tools.0.custom.eager_input_streaming: Extra inputs are not permitted
```

Upstream only fixes this for github-copilot via the `chat.params` plugin hook (gated on `providerID`), leaving Vertex/Bedrock/etc. broken. PRs that proposed a generalized fix ([#23766](https://github.com/anomalyco/opencode/pull/23766), [#23542](https://github.com/anomalyco/opencode/pull/23542)) were rejected by upstream maintainers. This patch defaults `toolStreaming = false` in `ProviderTransform.options()` whenever the model uses `@ai-sdk/anthropic` or `@ai-sdk/google-vertex/anthropic`. Users can opt back in by setting `toolStreaming: true` in their model or agent options.

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

:00  opencode-cached/sync-upstream    -- detects new upstream release
      |-> builds v{VER}-cached        -- applies caching patch, publishes

:01  opencode-patched/sync-cached     -- detects new -cached release
       |-> builds v{VER}-patched       -- applies caching + vim + tool fix + mcp reconnect + eager-input-streaming patches, publishes
:01  opencode-patched/sync-vim-pr     -- checks PR #12679 for changes
:01  opencode-patched/sync-tool-fix-pr -- checks PR #16751 for changes

:02  workstation/update-opencode-patched -- updates Nix config, opens PR
```

### Build Process

1. Clone upstream OpenCode at the release tag
2. Fetch `caching.patch` from [opencode-cached](https://github.com/johnnymo87/opencode-cached) (always latest from `main`)
3. Apply `caching.patch`, then local `vim.patch`, then `tool-fix.patch`, then `mcp-reconnect.patch`, then `eager-input-streaming.patch`
4. Build with Bun for 4 platforms (linux/darwin x arm64/x64)
5. Publish release as `v{VERSION}-patched`

### Patch Independence

The five patches modify mostly different areas of the codebase:
- **Caching**: `config/agent.ts`, `config/provider.ts`, `provider/config.ts`, `provider/transform.ts`, `session/prompt.ts`
- **Vim**: `cli/cmd/tui/component/vim/*`, `cli/cmd/tui/component/prompt/index.tsx`, `cli/cmd/tui/app.tsx`, `cli/cmd/tui/config/tui-schema.ts`
- **Tool fix**: `session/message-v2.ts`, `test/session/message-v2.test.ts`
- **MCP reconnect**: `mcp/index.ts`
- **Eager input streaming**: `provider/transform.ts` (different region from caching -- inserts a single `toolStreaming = false` block at the end of `options()`)

The only file touched by more than one patch is `provider/transform.ts` (caching + eager-input-streaming). The two patches modify disjoint regions and apply cleanly in either order.

## Patch Ownership

Each patch is owned by a specific repo. Do not edit a patch in the wrong repo.

| Patch | Owned by | Upstream PR guide |
|-------|----------|-------------------|
| `caching.patch` | [opencode-cached](https://github.com/johnnymo87/opencode-cached) (`patches/caching.patch`) | PR #5422 |
| `vim.patch` | **this repo** (`patches/vim.patch`) | PR #12679 |
| `tool-fix.patch` | **this repo** (`patches/tool-fix.patch`) | PR #16751 |
| `mcp-reconnect.patch` | **this repo** (`patches/mcp-reconnect.patch`) | Issue #15247 |
| `eager-input-streaming.patch` | **this repo** (`patches/eager-input-streaming.patch`) | Issue #23541 / PR #23766 (rejected upstream) |

When an upstream PR is merged, the corresponding patch can be dropped. `caching.patch` is
managed in the sibling repo `~/projects/opencode-cached`; edits belong there, not here.

## Maintenance

### When the Caching Patch Breaks (Build Failure)

This is handled by [opencode-cached](https://github.com/johnnymo87/opencode-cached). If the caching patch fails on a new upstream version, opencode-cached won't release, and this repo won't attempt a build.

To refresh: edit `~/projects/opencode-cached/patches/caching.patch` (not this repo).

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

### When the MCP Reconnect Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

1. Review the upstream changes to `packages/opencode/src/mcp/index.ts`
2. Regenerate or manually update `patches/mcp-reconnect.patch`
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

**Sunset**: This patch can be dropped when [issue #15247](https://github.com/anomalyco/opencode/issues/15247) is resolved upstream. Unlike the other patches, this one has no upstream PR to track -- it is original work. If an upstream PR appears, add a sync workflow for it.

### When the Eager Input Streaming Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

1. Review the upstream changes to `packages/opencode/src/provider/transform.ts`. The patch inserts a small `toolStreaming = false` block at the end of `ProviderTransform.options()` -- look for where the function returns `result` and re-add the block before it.
2. Regenerate or manually update `patches/eager-input-streaming.patch`
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

**Sunset**: This patch can be dropped if upstream merges a generalized fix that defaults `toolStreaming = false` for all `@ai-sdk/anthropic`-backed providers (not just `github-copilot`). Track [issue #23541](https://github.com/anomalyco/opencode/issues/23541), [#23257](https://github.com/anomalyco/opencode/issues/23257), and [#23767](https://github.com/anomalyco/opencode/issues/23767). Note: the obvious upstream fixes ([PR #23766](https://github.com/anomalyco/opencode/pull/23766), [#23542](https://github.com/anomalyco/opencode/pull/23542)) were rejected by maintainers, so this patch may need to live indefinitely.

### Sunset Criteria

Monthly automated check (`check-sunset.yml`) monitors all upstream PRs:
- **Any PR merged**: Drop the corresponding patch from `apply.sh`
- **All merged**: Switch workstation to upstream OpenCode, archive this repo and opencode-cached

## Credits

- **OpenCode**: [anomalyco/opencode](https://github.com/anomalyco/opencode)
- **Caching PR**: [PR #5422](https://github.com/anomalyco/opencode/pull/5422) by [@ormandj](https://github.com/ormandj)
- **Caching builds**: [opencode-cached](https://github.com/johnnymo87/opencode-cached)
- **Vim PR**: [PR #12679](https://github.com/anomalyco/opencode/pull/12679) by [@leohenon](https://github.com/leohenon)
- **Tool fix PR**: [PR #16751](https://github.com/anomalyco/opencode/pull/16751) by [@altendky](https://github.com/altendky)
- **MCP reconnect**: [Issue #15247](https://github.com/anomalyco/opencode/issues/15247) -- original patch
- **Eager input streaming workaround**: [Issue #23541](https://github.com/anomalyco/opencode/issues/23541) -- original patch (upstream fixes rejected)

## License

MIT (same as upstream OpenCode)
