# Refresh Caching Patch for Upstream v1.3.13

**Date:** 2026-04-01
**Status:** Not started
**Pipeline stuck at:** v1.3.7-patched (v1.3.9 through v1.3.13 all fail)
**Decision:** Keep patching (user chose option 1 over dropping to upstream caching)

## Problem

The `opencode-cached` caching patch (`patches/caching.patch`) fails to apply to
upstream v1.3.9+. Two files conflict:

1. `packages/opencode/src/provider/transform.ts:255` -- the `message()` function
2. `packages/opencode/src/session/prompt.ts:644` -- tool sorting / cache breakpoints

## Root Causes

### transform.ts (small fix)

v1.3.12 added `google-vertex-anthropic` to the hardcoded caching provider list
in the `message()` function. The caching patch REPLACES that entire hardcoded
check with `ProviderConfig.supportsExplicitCaching()`, so the context lines no
longer match. Same class of fix we did twice before -- update context lines in
the hunk.

The patch's hunk 4 (`@@ -255,15 +325,11 @@`) expects:
```ts
if (
  (model.providerID === "anthropic" ||
    model.api.id.includes("anthropic") ||
    ...
```
But v1.3.12+ has `google-vertex-anthropic` inserted in that block.

### prompt.ts (major rewrite -- the hard one)

Between v1.3.8 and v1.3.13, `prompt.ts` was massively refactored to use the
Effect system. Nearly every function was rewritten. The file went from ~2058
lines (v1.3.6) to ~1902 lines (v1.3.13) with completely different structure.

The caching patch adds a 30-line block at the old line 644 that:
1. Sorts tools alphabetically for cache prefix stability (`promptOrder.sortTools`)
2. Applies cache breakpoint to the last tool (`promptOrder.toolCaching`)

This needs to be ported into the new Effect-based `resolveTools` function.

## What the Caching Patch Does (for reference)

6 files, 2120 insertions, 51 deletions:

| File | Role | Conflict? |
|------|------|-----------|
| `config/config.ts` | Adds `cache` config schema fields | No (5 hunks, offset-based) |
| `provider/config.ts` | NEW FILE: 970-line ProviderConfig system | No (new file) |
| `provider/transform.ts` | Replaces hardcoded caching with ProviderConfig | **Yes** (hunk 4) |
| `session/prompt.ts` | Tool sorting + tool cache breakpoints | **Yes** (hunk 2) |
| `test/provider/config.test.ts` | NEW FILE: 934-line test suite | No (new file) |
| `test/provider/transform.test.ts` | Updates transform tests | No |

## Approach

### Step 1: Fix transform.ts hunk 4 (quick)

Same pattern as the v1.3.4 fix we did on Mar 29. Update the context lines in
hunk 4 to include `model.providerID === "google-vertex-anthropic" ||`. Adjust
hunk header line counts.

Check if any other transform.ts hunks also drifted (hunks 1-3 were fine on
v1.3.7 but upstream may have changed more since then).

### Step 2: Port prompt.ts changes into Effect-based code (substantial)

The old code at line 644 was:
```ts
// Sort tools for cache prefix stability when provider config requires it
const providerID = ProviderConfig.getConfigProviderID(model)
const providerConfig = ProviderConfig.getConfig(providerID, model)
if (providerConfig.promptOrder.sortTools) {
  const entries = Object.entries(tools).sort(([a], [b]) => a.localeCompare(b))
  for (const key of Object.keys(tools)) delete tools[key]
  for (const [key, value] of entries) tools[key] = value
}

// Apply cache breakpoint to last tool for explicit-caching providers
if (
  providerConfig.cache.enabled &&
  providerConfig.promptOrder.toolCaching &&
  ProviderConfig.supportsExplicitCaching(providerID)
) {
  const toolKeys = Object.keys(tools)
  const lastToolKey = toolKeys[toolKeys.length - 1]
  if (lastToolKey) {
    const cacheOptions = ProviderTransform.buildToolCacheOptions(model)
    if (Object.keys(cacheOptions).length > 0) {
      // ... applies providerOptions to last tool
    }
  }
}
```

Need to find the equivalent location in v1.3.13's Effect-based `resolveTools`
function and insert similar logic. The function signature changed but the concept
(tool dict is built, then returned) should still have a clear insertion point
just before the `return tools` statement.

### Step 3: Test the full patch stack

```bash
# Clone v1.3.13, apply all 3 patches in order
git clone --depth 1 --branch v1.3.13 https://github.com/anomalyco/opencode.git /tmp/opencode-test
cd /tmp/opencode-test
# Apply caching (from opencode-cached)
git apply /path/to/fixed/caching.patch
# Apply vim (from opencode-patched)
git apply /path/to/opencode-patched/patches/vim.patch
# Apply tool-fix (from opencode-patched)
git apply /path/to/opencode-patched/patches/tool-fix.patch
```

Note: vim.patch and tool-fix.patch may ALSO need refreshing for v1.3.13.
Check them too. The opencode-patched repo has open patch-drift issues for both.

### Step 4: Push and trigger pipeline

1. Push caching.patch fix to `opencode-cached`
2. Push any vim.patch / tool-fix.patch fixes to `opencode-patched`
3. Trigger: `gh workflow run build-release.yml --repo johnnymo87/opencode-cached --field version=1.3.13`
4. Then: `gh workflow run sync-cached.yml --repo johnnymo87/opencode-patched`
5. Then: `gh workflow run update-opencode-patched.yml --repo johnnymo87/workstation`

## Key Files on Disk

- `/tmp/transform-v1.3.6.ts` / `/tmp/transform-v1.3.13.ts` -- upstream transform.ts at both versions
- `/tmp/prompt-v1.3.6.ts` / `/tmp/prompt-v1.3.13.ts` -- upstream prompt.ts at both versions
- `/tmp/caching.patch` -- the original (pre-fix) caching patch for diffing
- `/tmp/caching-fixed.patch` -- the v1.3.6 fix (for reference, NOT for v1.3.13)
- `/home/dev/projects/opencode-cached/patches/caching.patch` -- the live patch to edit
- `/home/dev/projects/opencode-patched/patches/vim.patch` -- may also need refresh
- `/home/dev/projects/opencode-patched/patches/tool-fix.patch` -- may also need refresh

## Context from Prior Fixes

We've fixed this pipeline twice before in this session:

1. **v1.3.4 caching patch drift** (transform.ts only): Upstream added
   `tool-approval-request`/`tool-approval-response` guards to a condition.
   Fix was updating 1 context line + hunk header counts. Tested against v1.3.4/5/6.

2. **v1.3.6 vim patch drift** (app.tsx + prompt/index.tsx): Upstream had major
   TUI refactors. Used `git apply --3way` with full repo history to resolve 5
   merge conflicts (all parallel additions, kept both sides). Generated clean
   patch from resolved state via `git diff v1.3.6`.

The 3-way merge approach is likely needed again for prompt.ts given the scale
of changes.

## User Context

- Uses Google Vertex Anthropic on work machines (the v1.3.12 change is relevant)
- Uses Claude Max subscriptions on personal machines
- Cares about cost reduction from the caching patch (~44% cache write reduction, ~73% cost reduction)
- Prefers to keep patching rather than drop to upstream-only caching
