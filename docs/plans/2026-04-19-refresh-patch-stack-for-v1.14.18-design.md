# Refresh Patch Stack for v1.14.18 — Design

**Date:** 2026-04-19
**Status:** Approved
**Upstream target:** `anomalyco/opencode` `v1.14.18` (fallback: `v1.14.17`)
**Current production state:** `workstation` pins `opencode-patched v1.4.3` (Apr 12); `opencode-cached` and `opencode-patched` have both been stuck at `v1.4.3-{cached,patched}` since upstream broke `caching.patch` with the v1.4.4 release.

---

## Compaction-Resilience Notes

This plan is written so it **survives memory compaction during execution**. Anyone (human or agent) picking this up fresh should be able to:

1. Read this design doc end-to-end and understand the full scope.
2. Read the matching execution plan files (listed below under "Related Plans") for task-by-task instructions.
3. Run `bd ready --json` in `~/projects/workstation` to see tracked task state.

If you are resuming after compaction, **start here**, then pick the next unchecked task from the relevant execution plan. Do not rely on any information not written in these files, beads issues, or the repos themselves.

### Related Plans

Written as companions to this design:

- [x] `~/projects/opencode-cached/docs/plans/2026-04-19-refresh-caching-patch-for-v1.14.18.md` — caching.patch rebase (in the owning repo)
- [x] `~/projects/opencode-patched/docs/plans/2026-04-19-refresh-patch-stack-for-v1.14.18.md` — opencode-patched patch stack + release + workstation bump + devbox rebuild

### Tracked Tasks (beads in `~/projects/workstation`)

Cross-repo task state lives in workstation's beads DB (the sibling repos don't have `.beads/`). Run `bd list --status open --json | jq '.[] | select(.title | contains("v1.14.18"))'` to see them. Created 2026-04-19.

**Important**: `~/projects/workstation/.beads/` is gitignored, so the task state is **local to this devbox**. If you ever need to work on this plan from a different machine, you'll need to recreate the beads tasks from this design doc, or make the plan files (committed below) the source of truth. The plan `.md` files DO survive git; they're the durable layer. Beads is the in-session ergonomic layer.

| ID | Title | Covers |
|----|-------|--------|
| `workstation-3fq` | Refresh opencode patch stack for v1.14.18 (epic) | parent |
| `workstation-5k6` | Rebase caching.patch against upstream v1.14.18 | caching plan |
| `workstation-80r` | Drop obsolete opus-4-7.patch from opencode-patched | patched plan Task B |
| `workstation-b0p` | Verify or refresh tool-fix.patch against v1.14.18 | patched plan Task C |
| `workstation-97f` | Rebase vim.patch against upstream v1.14.18 | patched plan Task D |
| `workstation-e1a` | Verify or rebase mcp-reconnect.patch against v1.14.18 | patched plan Task E |
| `workstation-e39` | Cut v1.14.18-patched release and verify CI | patched plan Task H |
| `workstation-57y` | Bump workstation to v1.14.18 and rebuild devbox | patched plan Task I |

Dependency graph: all patch tasks block `workstation-e39` (cut release); `workstation-e39` blocks `workstation-57y` (bump); epic `workstation-3fq` blocks everything for visibility. Run `bd ready --json` to get the next unblocked task.

---

## Goal

Refresh the opencode patch stack so a new `opencode-patched` release cuts from upstream `v1.14.18`, then bump `workstation` to consume it and rebuild the devbox. Stops only when `opencode --version` on devbox reports `1.14.18`.

---

## Why This Is Needed

The automated update cron has been firing successfully since v1.4.3 (Apr 12), but the `caching.patch` fails to apply on every upstream release since v1.4.4. Evidence:

- `opencode-cached` has 10 open "Release blocked: build failed" issues (v1.4.4 through v1.14.17). Latest: issue #28 for v1.14.17.
- `opencode-patched` waits on `opencode-cached` releases, so it's transitively stuck too. It also has fresh patch-drift alerts (2026-04-19): issue #4 (tool-fix.patch) and #5 (vim.patch).
- `workstation` `users/dev/home.base.nix` still pins `version = "1.4.3"` because no newer `opencode-patched` release exists.

This is exactly the "patch breaks 3+ consecutive releases" signal the READMEs describe. Self-healing stopped; a human (or agent) has to rebase each patch.

Upstream between v1.4.3 and v1.14.18 shipped 20+ releases. The version jump from v1.4.11 → v1.14.17 on 2026-04-19 was an upstream re-versioning; the intervening commits still exist and the code has drifted substantially.

---

## Repositories and Ownership

These repos are cloned on the local devbox at `~/projects/`:

| Repo | Purpose | Owns patches |
|------|---------|--------------|
| `~/projects/opencode-cached` | First link: applies `caching.patch` only, releases `v{VER}-cached` | `patches/caching.patch` |
| `~/projects/opencode-patched` | Second link: pulls `caching.patch` from cached, applies local patches, releases `v{VER}-patched` | `patches/vim.patch`, `patches/tool-fix.patch`, `patches/mcp-reconnect.patch`, `patches/opus-4-7.patch` |
| `~/projects/workstation` | Consumer: pins `opencode-patched` release in `users/dev/home.base.nix` | N/A |

GitHub equivalents:

- `johnnymo87/opencode-cached`
- `johnnymo87/opencode-patched`
- `johnnymo87/workstation`

**Do not edit a patch in the wrong repo.** `caching.patch` lives in `opencode-cached`; everything else lives in `opencode-patched`.

---

## Patch Inventory and Refresh Decisions

Assessed 2026-04-19 against upstream `v1.14.18`.

### 1. `caching.patch` (in `opencode-cached`) — REBASE

Upstream PR #5422 ([anomalyco/opencode#5422](https://github.com/anomalyco/opencode/pull/5422)), still open, not merged.

**Assessment evidence** (from `git apply --reject` against upstream `v1.14.18`):

```
packages/opencode/src/config/config.ts:                5 hunks rejected
packages/opencode/src/provider/config.ts:              applied cleanly (new file)
packages/opencode/src/provider/transform.ts:           4 hunks rejected
packages/opencode/src/session/prompt.ts:               2 hunks rejected
packages/opencode/test/provider/config.test.ts:        applied cleanly (new file)
packages/opencode/test/provider/transform.test.ts:     2 hunks rejected
```

13 of ~17 hunks drift across 4 files. New files (`provider/config.ts`, `test/provider/config.test.ts`) are fine. True rebase is required for the 4 modified files. The 2140-line patch is mostly stable content in those new files; the actual rebase work is concentrated in the modified-file hunks.

### 2. `opus-4-7.patch` (in `opencode-patched`) — DROP

Upstream `v1.14.18/packages/opencode/src/provider/transform.ts` already contains:

```typescript
if (["opus-4-7", "opus-4.7"].some((v) => apiId.includes(v))) {
  return ["low", "medium", "high", "xhigh", "max"]
```

Matches the sunset criterion in `opencode-patched/README.md` ("Drop this patch as soon as upstream adds `opus-4-7` to the `isAnthropicAdaptive` array"). No rebase needed; just remove.

### 3. `tool-fix.patch` (in `opencode-patched`) — VERIFY THEN REFRESH OR DROP

Upstream PR #16751 ([anomalyco/opencode#16751](https://github.com/anomalyco/opencode/pull/16751)), still open, mergeable, not merged. Patch-drift issue #4 was opened 2026-04-19 because the PR's raw diff hash no longer matches the committed patch.

**Required first step**: Run the regression test from PR #16751 against a plain upstream v1.14.18 checkout. If the test passes without the patch, the fix is already present upstream via some other change — drop the patch. If it fails, refresh the patch from the current PR diff.

### 4. `vim.patch` (in `opencode-patched`) — REBASE

Upstream PR #12679 ([anomalyco/opencode#12679](https://github.com/anomalyco/opencode/pull/12679)), still open, not merged. Patch-drift issue #5 opened 2026-04-19.

The patch has been rebased multiple times (see `opencode-patched` commit `9a8732c`, `fd5f8be`, `1178a65`). Expected to need a rebase again — use PR #12679's current diff as the behavioral guide, not the old local patch.

### 5. `mcp-reconnect.patch` (in `opencode-patched`) — VERIFY THEN REBASE IF NEEDED

No upstream PR (original patch tracking [issue #15247](https://github.com/anomalyco/opencode/issues/15247)). Touches only `packages/opencode/src/mcp/index.ts`.

**Required first step**: `git apply --check patches/mcp-reconnect.patch` against upstream v1.14.18. If it applies cleanly, no action needed. If it fails, rebase against current `mcp/index.ts` — the patch's behavior is well-documented in `opencode-patched/README.md §4`.

---

## Refresh Order

Driven by the build chain (`opencode-patched` can't cut a release until `opencode-cached` does):

1. **`caching.patch`** in `opencode-cached` → cut `v1.14.18-cached` release.
2. **`opus-4-7.patch`** drop (trivial, do while waiting for cached CI build).
3. **`tool-fix.patch`** verify-or-refresh.
4. **`vim.patch`** rebase.
5. **`mcp-reconnect.patch`** verify-or-rebase.
6. **`opencode-patched` full-stack build** → cut `v1.14.18-patched` release.
7. **`workstation` bump** → trigger `update-opencode-patched.yml` workflow (or wait ≤ 8h for cron). Merge PR. Rebuild devbox.

This order gets the critical-path blocker moving first while context on upstream v1.14.18 is fresh.

---

## Refresh Mechanics (Approach A: Commit-Based Rebase)

For each patch that needs refreshing, use this procedure. It matches the `opencode-cached/README.md §Development → Update Patch for New Version` workflow.

```bash
# Working directory for all patch-refresh work
mkdir -p /tmp/opencode-refresh
cd /tmp/opencode-refresh

# Clone upstream at target version (once per session; reuse across patches)
git clone --depth 1 --branch v1.14.18 https://github.com/anomalyco/opencode.git opencode-v1.14.18
cd opencode-v1.14.18

# Per patch: apply with --reject to see what conflicts
git apply --reject ~/projects/<owning-repo>/patches/<name>.patch
# Inspect *.rej files, resolve hunks by hand guided by the upstream PR diff:
#   gh pr diff <PR_NUM> --repo anomalyco/opencode

# Once code is in the desired state:
git add -A
git commit -m "WIP: refresh <name>.patch for v1.14.18"

# Regenerate patch (excludes packages/web/, matches existing convention):
git diff v1.14.18..HEAD -- . ':(exclude)packages/web/' > ~/projects/<owning-repo>/patches/<name>.patch

# Validate by re-applying from scratch in a fresh checkout:
git stash  # or clone fresh
git apply ~/projects/<owning-repo>/patches/<name>.patch  # must succeed cleanly
bun install
bun --cwd packages/opencode typecheck  # must pass
```

**Do not hand-edit `.patch` files.** Always regenerate from `git diff`.

**The `packages/web/` filter** matters: `opencode-patched`'s drift-detection scripts compare patches excluding `packages/web/`, so keep that convention.

---

## Validation Strategy

### Per-patch (local, fast)

After each refresh, in a fresh upstream v1.14.18 checkout:

```bash
cd ~/projects/<owning-repo>
./patches/apply.sh /tmp/opencode-refresh/opencode-v1.14.18-fresh
cd /tmp/opencode-refresh/opencode-v1.14.18-fresh
bun install
bun --cwd packages/opencode typecheck
```

Typecheck must pass. For `tool-fix.patch` specifically, also run the PR #16751 regression test.

### Per-repo (CI, authoritative)

After committing+pushing the patch, trigger the build workflow:

```bash
# opencode-cached:
gh workflow run build-release.yml \
  --repo johnnymo87/opencode-cached \
  --field version=1.14.18

# opencode-patched (after cached release exists):
gh workflow run build-release.yml \
  --repo johnnymo87/opencode-patched \
  --field version=1.14.18
```

Watch with `gh run watch --repo johnnymo87/<repo>`. CI builds all 4 platforms (linux/darwin × arm64/x64), signs darwin binaries (see `@darwin-signing` skill in `opencode-patched`), smoke-tests them, and publishes the release. **Do not bump workstation until the patched release exists and its darwin smoke test passed.**

### Whole-stack (workstation)

Once `v1.14.18-patched` exists:

```bash
cd ~/projects/workstation
gh workflow run update-opencode-patched.yml  # or wait ≤ 8h for scheduled cron
# Merge the resulting PR auto-opened by the workflow
sudo nixos-rebuild switch --flake .#devbox  # if system changes
nix run home-manager -- switch --flake .#dev  # for home.base.nix changes (no sudo)
opencode --version  # should report 1.14.18
```

---

## Fallback: Target v1.14.17

If v1.14.18 proves unusually difficult (some upstream refactor we can't sensibly port), fall back to **v1.14.17** (Apr 19 early). Changelog delta v1.14.17→v1.14.18 is minor: "Restore the native ripgrep backend" + docs. Either version unsticks the pipeline; v1.14.17 vs v1.14.18 is a rounding error for our purposes.

Execute the fallback by substituting `1.14.17` for `1.14.18` in every command above, including the upstream clone tag. The `workstation` auto-update cron will eventually bump us to v1.14.18+ on a later cycle anyway.

---

## Rollback Plan

All patch-refresh changes are commits on `main` in their respective repos. If CI fails or a release turns out bad:

- **Patch refresh commit bad**: `git revert <sha>` in the repo, push, re-run build workflow. Or `git reset --hard HEAD~1 && git push --force-with-lease` if the bad commit is the tip and nothing downstream consumed it yet.
- **Released binary bad**: `gh release delete v1.14.18-<tier>` on the offending repo. Refresh the patch correctly, re-run build. Workstation pin continues to reference v1.4.3 until a known-good release exists.
- **Workstation PR auto-merged a bad version**: revert the auto-merge commit, push. The next cron run will re-attempt when a fixed release exists.

`workstation`'s home.base.nix pins by version string and asset hashes, so there is no silent-upgrade risk — any change is observable in git.

---

## Non-Goals

- **Do not move `caching.patch` ownership into `opencode-patched`.** It stays in `opencode-cached`.
- **Do not preserve old patch text when upstream structure has moved.** Rebase onto current behavior; regenerate from clean `git diff`. (Same rule as the v1.4.0 plan.)
- **Do not treat patch-drift alerts as proof of breakage.** Drift issues #4, #5 say "review needed", not "build broken". The build is broken because of `caching.patch` upstream of them. Once upstream v1.14.18 is the target, drift may or may not require adopting the upstream changes — judgment call per patch.
- **Do not chase v1.14.19+** if upstream cuts another release mid-refresh. Land v1.14.18 first; let the cron pick up later versions on its own cycle.
- **Do not rebuild macOS** as part of this plan. Scope is the devbox (aarch64-linux). macOS hosts will pick up the bump through their normal `darwin-rebuild switch` flow, same as always.

---

## Current Known State (captured 2026-04-19)

- `~/projects/opencode-cached` on `main`, clean working tree. Last release: `v1.4.3-cached`. Build workflow failing on every trigger since v1.4.4.
- `~/projects/opencode-patched` on `main`. `Session.vim` file untracked (nvim session — ignore, not part of this work). Last release: `v1.4.3-patched`. Drift issues #4, #5 open. Build-failure issue #6 open for v1.4.3 (delete when current refresh lands, or close with a note).
- `~/projects/workstation` — pins `version = "1.4.3"` in `users/dev/home.base.nix:117`, platform hashes captured at that version. Auto-update cron runs every 8h but finds no newer patched release to consume.
- `/tmp/opencode-refresh/opencode-v1.14.18` — already cloned (depth 1) as of 2026-04-19. Safe to delete and recreate; cheap.

Environment:

- Devbox runs NixOS aarch64-linux. The asset that matters here is `opencode-linux-arm64.tar.gz`.
- `gh` is authenticated as `johnnymo87`. `gh workflow run` works against all three repos.
- `bun` is on `$PATH`. Use whichever version Nix provides; do not try to match the CI's Bun version locally (CI uses `bun-version: latest` with the `BUN_NO_CODESIGN_MACHO_BINARY` workaround — not relevant for local typechecks).

---

## Documentation Changes Required

These go in the execution plan for `opencode-patched` (not this design):

- `README.md`: remove `opus-4-7.patch` from the "Patches Included" section and the "Patch Ownership" table once the patch is dropped.
- `.github/workflows/build-release.yml` or `patches/apply.sh`: remove the `opus-4-7.patch` apply step.
- Consider a `docs/plans/2026-04-19-refresh-patch-stack-for-v1.14.18.md` journal entry of what was done (for future archaeology — matches prior plans' structure).

---

## Open Decision Log

Captured during the 2026-04-19 brainstorming session:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Plan location | Design here in `opencode-patched`; execution plans split per-repo | Matches prior cross-repo convention |
| Scope | Full chain until devbox runs v1.14.18 | Matches user's stated goal |
| Order | Caching first, then opencode-patched stack | Critical-path unblocker first |
| Rebase philosophy | True rebase (behavior-first) | Matches `.opencode/skills/patch-refresh.md` and v1.4.0 design |
| Execution mode | Subagent-driven in this session | Fresh context per patch; code review between |
| Worktrees | No; work on `main` in existing checkouts | Matches prior refreshes |
| Target version | v1.14.18 with v1.14.17 as fallback | 18 is latest; 17 is proven overnight |
| Compaction | Plan files exhaustively self-contained; beads tracks cross-repo state | Survive mid-execution compaction |

---

## Success Criteria

1. `opencode-cached` has published release `v1.14.18-cached` (or `-v1.14.17-cached` fallback).
2. `opencode-patched` has published release `v1.14.18-patched` with all 4 platform assets and passing darwin smoke test.
3. `workstation` `users/dev/home.base.nix` pins the new version with fresh asset hashes, merged to main.
4. `ssh devbox 'opencode --version'` reports the new version.
5. All tracked beads tasks are closed.
6. Both open build-failure issues in `opencode-cached` for v1.14.17 (#28) and earlier are either closed or commented with pointers to the resolving release. Same for `opencode-patched` issue #6.
