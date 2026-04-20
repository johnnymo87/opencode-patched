# Refresh Patch Stack for v1.14.18 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. **Read the design doc first**: `~/projects/opencode-patched/docs/plans/2026-04-19-refresh-patch-stack-for-v1.14.18-design.md`. **This plan depends on `workstation-5k6` (the caching.patch refresh) completing first** — if that beads task is not yet `closed`, stop and work on that plan first.

**Goal:** Drop `opus-4-7.patch` (now obsolete upstream), refresh the remaining three patches (`tool-fix`, `vim`, `mcp-reconnect`), cut `v1.14.18-patched` release, bump `workstation` to consume it, and rebuild the devbox.

**Architecture:** Work directly on `main` in `~/projects/opencode-patched`. Each patch is refreshed in `/tmp/opencode-refresh/opencode-v1.14.18-stack` (a fresh checkout with caching.patch already applied, to mirror CI conditions). Patches stack: caching → vim → tool-fix → mcp-reconnect (order in `patches/apply.sh`; opus-4-7 removed).

**Tech Stack:** Upstream opencode (TypeScript, Bun), git, bash, gh CLI, Nix (for workstation), NixOS rebuild.

---

## Compaction-Resilience Checklist

If resuming this plan after memory compaction:

1. Read the design doc at `~/projects/opencode-patched/docs/plans/2026-04-19-refresh-patch-stack-for-v1.14.18-design.md` end-to-end.
2. Check beads: `cd ~/projects/workstation && bd list --status open --priority 1 --json | jq '.[] | {id, title, status}'`. Identify which tasks in this plan are still open (IDs listed below).
3. Check `gh release list --repo johnnymo87/opencode-cached --limit 1` — if there's no `v1.14.18-cached`, go back to the caching plan first.
4. Check `gh release list --repo johnnymo87/opencode-patched --limit 1` — if there's already `v1.14.18-patched`, skip to Task "Bump workstation".
5. Check current patches dir state: `ls -la ~/projects/opencode-patched/patches/ && cat ~/projects/opencode-patched/patches/apply.sh`.
6. Resume at the first unchecked task below.

**Current known state (2026-04-19):**
- `~/projects/opencode-patched` on `main`, clean working tree (`Session.vim` untracked is nvim leftover, ignore).
- Last release: `v1.4.3-patched` (Apr 12).
- Patches dir: `apply.sh`, `mcp-reconnect.patch`, `opus-4-7.patch`, `tool-fix.patch`, `vim.patch`.
- Upstream `v1.14.18/packages/opencode/src/provider/transform.ts` already contains `opus-4-7`/`opus-4.7` with `xhigh` effort → `opus-4-7.patch` is verifiably obsolete.
- Open drift issues: #4 (tool-fix.patch drift vs PR #16751), #5 (vim.patch drift vs PR #12679). Both opened 2026-04-19.
- Open build-failure issue: #6 (v1.4.3 darwin smoke test flake from Apr 16 — stale, harmless).

---

## Task Tracking

Beads tasks (in `~/projects/workstation`):

- `workstation-80r`: Drop opus-4-7.patch
- `workstation-b0p`: Verify/refresh tool-fix.patch
- `workstation-97f`: Rebase vim.patch
- `workstation-e1a`: Verify/rebase mcp-reconnect.patch
- `workstation-e39`: Cut v1.14.18-patched release
- `workstation-57y`: Bump workstation + rebuild devbox

Update with `bd update <id> --status in_progress` when starting, `bd close <id>` when done. After each commit, note progress with `bd update <id> --notes "<summary>"`.

Plan task list:

- [ ] Task A: Prepare upstream+caching checkout
- [ ] Task B: Drop opus-4-7.patch (beads: workstation-80r)
- [ ] Task C: Verify or refresh tool-fix.patch (beads: workstation-b0p)
- [ ] Task D: Rebase vim.patch (beads: workstation-97f)
- [ ] Task E: Verify or rebase mcp-reconnect.patch (beads: workstation-e1a)
- [ ] Task F: Update README and apply.sh to match final patch set
- [ ] Task G: Local full-stack dry run
- [ ] Task H: Commit everything, push, trigger build-release.yml (beads: workstation-e39)
- [ ] Task I: Bump workstation to v1.14.18 and rebuild devbox (beads: workstation-57y)
- [ ] Task J: Close stale issues across all repos

---

### Task A: Prepare upstream+caching checkout

**Prerequisite:** `v1.14.18-cached` release must exist. Verify:

```bash
gh release view v1.14.18-cached --repo johnnymo87/opencode-cached >/dev/null && echo OK || echo MISSING
```

If `MISSING`, stop and work on the caching plan first (`~/projects/opencode-cached/docs/plans/2026-04-19-refresh-caching-patch-for-v1.14.18.md`).

**Step 1: Fresh upstream clone + caching.patch pre-applied**

This mirrors what `opencode-patched`'s CI does: it clones upstream, pulls `caching.patch` from `opencode-cached`'s `main`, and applies it before applying the local patches.

```bash
rm -rf /tmp/opencode-refresh/opencode-v1.14.18-stack
mkdir -p /tmp/opencode-refresh
cd /tmp/opencode-refresh
git clone --depth 1 --branch v1.14.18 https://github.com/anomalyco/opencode.git opencode-v1.14.18-stack
cd opencode-v1.14.18-stack

# Apply caching.patch from the owning repo (local checkout, matches CI which fetches from GitHub raw)
git apply ~/projects/opencode-cached/patches/caching.patch
git add -A
git commit -m "baseline: v1.14.18 + caching"
```

Expected: patch applies cleanly (it must; that was the whole point of the caching refresh).

**Step 2: Install deps once (cached across tasks)**

```bash
bun install
bun --cwd packages/opencode typecheck  # should pass
```

---

### Task B: Drop `opus-4-7.patch` (beads: `workstation-80r`)

Upstream v1.14.18 already contains `opus-4-7` handling. Verified with:

```bash
curl -sfL "https://raw.githubusercontent.com/anomalyco/opencode/v1.14.18/packages/opencode/src/provider/transform.ts" | grep 'opus-4-7'
# Prints lines showing opus-4-7 is in the isAnthropicAdaptive equivalent.
```

**Step 1: Mark beads in-progress**

```bash
cd ~/projects/workstation
bd update workstation-80r --status in_progress
```

**Step 2: Remove the patch file**

```bash
cd ~/projects/opencode-patched
git rm patches/opus-4-7.patch
```

**Step 3: Update `patches/apply.sh` to stop applying opus-4-7**

```bash
cat patches/apply.sh
```

Look for a line that applies `opus-4-7.patch` (likely something like `git apply ../patches/opus-4-7.patch`). Remove that line.

Edit with:

```bash
# Check the exact syntax first, then use Edit tool or sed.
grep -n 'opus-4-7' patches/apply.sh
```

Use the `Edit` tool to delete the opus-4-7 line precisely.

**Step 4: Update `README.md`**

Remove all references to the opus-4-7 patch:

```bash
grep -n 'opus-4-7\|Opus 4.7' README.md
```

- Section "### 5. Claude Opus 4.7 Adaptive Reasoning + xhigh Effort" (currently lines 35-45): **delete entirely**.
- "Patch Ownership" table row for `opus-4-7.patch` (currently line 131): **delete**.
- "Patches Included" lead sentence at line 3 mentions "+ Opus 4.7 support" — **remove that term**.
- "When the Opus 4.7 Patch Breaks" subsection (currently lines 198-210): **delete entirely**.
- "Sunset Criteria" subsection line 216 mentions opus-4-7: **delete that bullet**.
- "Credits" line 227 mentions "Opus 4.7 patch": **delete that credit line**.
- "Patch Independence" subsection (around lines 110-120): **remove the opus-4-7 bullet**; also revise the sentence "Zero file overlap between any pair of patches. Note: caching and opus-4-7 both touch `transform.ts`..." — just say "Zero file overlap between any pair of patches."
- Anywhere else the patch count "five patches" appears (e.g., README.md line 5): **change to "four patches"**.

Use the Edit tool for each. Re-check with `grep -n 'opus\|Opus\|five patches\|5 patches' README.md` to catch stragglers.

**Step 5: Sanity check — `patches/apply.sh` works in the stack checkout**

```bash
cd /tmp/opencode-refresh/opencode-v1.14.18-stack
# Reset to the caching-only baseline
git reset --hard HEAD
~/projects/opencode-patched/patches/apply.sh .
```

Expected: `apply.sh` reports applying vim + tool-fix + mcp-reconnect (in whatever its order is) and exits 0. **It's OK** if one of these three still fails — the next tasks address them. The only thing that should NOT happen here is a "file not found: opus-4-7.patch" error.

If it does happen, you missed an `opus-4-7` reference in apply.sh. Fix and retry.

**Step 6: Do NOT commit yet** — batch all patch changes into one push at Task H.

**Step 7: Mark beads ready to close (but wait for CI)**

```bash
cd ~/projects/workstation
bd update workstation-80r --notes "opus-4-7.patch removed locally; will close after CI build succeeds"
```

---

### Task C: Verify or refresh `tool-fix.patch` (beads: `workstation-b0p`)

Patch tracks [PR #16751](https://github.com/anomalyco/opencode/pull/16751). PR is still open and mergeable as of 2026-04-19. Drift issue #4 is open.

**Step 1: Mark beads**

```bash
bd update workstation-b0p --status in_progress
```

**Step 2: First verify — does upstream v1.14.18 still have the bug?**

Per `opencode-patched/README.md §"When the Tool Fix Patch Breaks"`, run the regression test from the PR against plain upstream:

```bash
cd /tmp/opencode-refresh/opencode-v1.14.18-stack
git reset --hard HEAD  # back to caching-only baseline
# Fetch the PR test addition as a reference:
gh pr diff 16751 --repo anomalyco/opencode > /tmp/opencode-refresh/pr-16751.patch
# The PR adds a test to test/session/message-v2.test.ts. Extract the test:
grep -A 200 "test/session/message-v2.test.ts" /tmp/opencode-refresh/pr-16751.patch | head -240
```

Find the specific regression test case (it asserts that `tool_use` without a matching `tool_result` gets a synthetic `step-start` boundary injected). Copy just that test block into `/tmp/opencode-refresh/opencode-v1.14.18-stack/packages/opencode/test/session/message-v2.test.ts` manually (or apply the full PR diff and isolate just the test).

Run it:

```bash
bun --cwd packages/opencode test test/session/message-v2.test.ts 2>&1 | tail -40
```

**Interpretation:**

- **Test passes without the patch**: upstream has incorporated the fix by some other means. **Drop `tool-fix.patch`**, remove it from `apply.sh`, update README to remove tool-fix references (analogous to opus-4-7 removal).
- **Test fails without the patch**: fix is still needed; refresh the patch (Step 3).

**Step 3: If needed, refresh the patch**

Reset the test file to upstream:

```bash
git checkout HEAD -- packages/opencode/test/session/message-v2.test.ts
```

Try applying the existing local patch:

```bash
git apply --reject ~/projects/opencode-patched/patches/tool-fix.patch
```

If it applies cleanly, no rebase needed (unlikely if drift issue #4 is valid). If it has rejects:

- Read `.rej` files.
- Cross-reference with PR #16751's current diff (`/tmp/opencode-refresh/pr-16751.patch`).
- The README says: "Use PR #16751 as the behavioral guide when refreshing." So regenerate from the PR diff if the existing patch is too stale:

```bash
cd /tmp/opencode-refresh/opencode-v1.14.18-stack
git reset --hard HEAD
gh pr diff 16751 --repo anomalyco/opencode | git apply --reject
# Resolve rejects, stage, commit:
git add -A
git commit -m "tool-fix: rebased onto v1.14.18"
# Regenerate patch (exclude caching-touched files to keep patches independent):
git diff HEAD~..HEAD -- packages/opencode/src/session/message-v2.ts packages/opencode/test/session/message-v2.test.ts > ~/projects/opencode-patched/patches/tool-fix.patch
```

The patch scope should stay narrow (per README §Patch Independence, tool-fix only touches `session/message-v2.ts` + its test).

**Step 4: Verify**

Reset and re-apply the full stack:

```bash
git reset --hard HEAD~  # back to caching-only baseline (not all the way to upstream)
~/projects/opencode-patched/patches/apply.sh .
bun --cwd packages/opencode typecheck
bun --cwd packages/opencode test test/session/message-v2.test.ts
```

All should pass.

**Step 5: Notes in beads**

```bash
bd update workstation-b0p --notes "tool-fix refreshed/dropped (record which). Verified typecheck + regression test."
```

---

### Task D: Rebase `vim.patch` (beads: `workstation-97f`)

Patch tracks [PR #12679](https://github.com/anomalyco/opencode/pull/12679). Still open upstream. Drift issue #5 open.

**Step 1: Mark beads**

```bash
bd update workstation-97f --status in_progress
```

**Step 2: Check if upstream already has vim**

```bash
curl -sfL "https://raw.githubusercontent.com/anomalyco/opencode/v1.14.18/packages/opencode/src/cli/cmd/tui/app.tsx" 2>/dev/null | grep -i 'vim' | head -10
# Also check for vim/ directory:
curl -sfL "https://api.github.com/repos/anomalyco/opencode/contents/packages/opencode/src/cli/cmd/tui/component/vim?ref=v1.14.18" 2>/dev/null | head -20
```

If upstream has vim support, inspect whether it's the same PR's behavior or something different. If it's the same, drop our patch. If absent, refresh.

**Step 3: Try the existing patch**

```bash
cd /tmp/opencode-refresh/opencode-v1.14.18-stack
git reset --hard HEAD  # caching-only baseline
git apply --reject ~/projects/opencode-patched/patches/vim.patch 2>&1 | tee /tmp/opencode-refresh/vim-apply.log
find . -name "*.rej"
```

If zero rejects: fantastic, patch still applies. Skip to Step 5 (verify + package).

If rejects: rebase.

**Step 4: Rebase (if needed)**

Per the README: "Use PR #12679 as the behavioral guide." Fetch current PR diff:

```bash
gh pr diff 12679 --repo anomalyco/opencode > /tmp/opencode-refresh/pr-12679.patch
```

Approach:

1. Start from clean caching-only baseline.
2. Apply the PR diff with `git apply --reject` — this is likely to have its own conflicts because upstream has moved since the PR was last rebased.
3. Resolve those conflicts by understanding what vim files each hunk wants to create/modify, and placing them in the v1.14.18 TUI structure.
4. Files touched (per README §Patch Independence): `cli/cmd/tui/component/vim/*`, `cli/cmd/tui/component/prompt/index.tsx`, `cli/cmd/tui/app.tsx`, plus any config surface (look for `tui.vim` config option and schema entry).

Once code is in place:

```bash
git add -A
git commit -m "vim: rebased onto v1.14.18"
# Narrow patch scope to vim-only files; exclude caching-touched files:
git diff HEAD~..HEAD -- packages/opencode/src/cli packages/opencode/src/config/config.ts > ~/projects/opencode-patched/patches/vim.patch
```

If the patch now double-touches `config.ts` (because vim adds a `tui.vim` config option and caching also modifies config.ts), that's fine as long as their hunks don't overlap. The README confirms this is tolerable: "Zero file overlap between any pair of patches" — *within the same hunk* is the spirit here; different hunks in the same file are OK.

**Step 5: Verify**

```bash
cd /tmp/opencode-refresh/opencode-v1.14.18-stack
git reset --hard HEAD~  # back to caching-only
~/projects/opencode-patched/patches/apply.sh .
bun --cwd packages/opencode typecheck
# Optional: manually verify vim config option is accepted:
grep -r "tui.*vim" packages/opencode/src/config/ | head -5
```

Expected: typecheck passes; schema mentions vim.

**Step 6: Notes**

```bash
bd update workstation-97f --notes "vim.patch rebased onto v1.14.18. Typecheck green."
```

---

### Task E: Verify or rebase `mcp-reconnect.patch` (beads: `workstation-e1a`)

No upstream PR — original patch. Only touches `packages/opencode/src/mcp/index.ts`.

**Step 1: Mark beads**

```bash
bd update workstation-e1a --status in_progress
```

**Step 2: Try applying the existing patch on top of the full stack so far**

```bash
cd /tmp/opencode-refresh/opencode-v1.14.18-stack
git reset --hard HEAD  # caching-only baseline, with vim and tool-fix already dropped from this scratch tree
# Re-apply just caching is already committed. Now apply vim + tool-fix + mcp-reconnect via apply.sh, but apply.sh handles all three. Use it:
~/projects/opencode-patched/patches/apply.sh . 2>&1 | tee /tmp/opencode-refresh/stack-apply.log
```

**Interpretation:**

- If `apply.sh` succeeds end-to-end, including mcp-reconnect — no work needed. Skip to Step 4.
- If `apply.sh` fails specifically at the mcp-reconnect step, rebase (Step 3).

**Step 3: Rebase (if needed)**

Read upstream's current `mcp/index.ts`:

```bash
git reset --hard HEAD  # caching-only
cat packages/opencode/src/mcp/index.ts | head -200
```

Compare to our patch's expectations:

```bash
cat ~/projects/opencode-patched/patches/mcp-reconnect.patch
```

The patch wraps remote MCP tool execution with a try/catch that detects transport-level errors (stale session, connection refused), closes the stale client, creates a fresh transport+client, refreshes tool definitions, and retries the call once.

Find the function where remote tool execution happens in the current upstream file. Port the wrap-with-retry logic there, preserving the patch's intent. Since the behavior is self-contained (one function), the rebase is usually small.

Commit and regenerate:

```bash
git add packages/opencode/src/mcp/index.ts
git commit -m "mcp-reconnect: rebased onto v1.14.18"
git diff HEAD~..HEAD -- packages/opencode/src/mcp/index.ts > ~/projects/opencode-patched/patches/mcp-reconnect.patch
```

**Step 4: Verify**

```bash
git reset --hard HEAD~  # caching-only
~/projects/opencode-patched/patches/apply.sh .
bun --cwd packages/opencode typecheck
```

**Step 5: Notes**

```bash
bd update workstation-e1a --notes "mcp-reconnect verified/rebased. Typecheck green."
```

---

### Task F: Update README and apply.sh to match final patch set

By now, `patches/` should contain some subset of: `vim.patch`, `tool-fix.patch` (maybe dropped), `mcp-reconnect.patch`. The `apply.sh` script should only apply patches that exist. `README.md` should document exactly the set that ships.

**Step 1: Verify patch inventory**

```bash
cd ~/projects/opencode-patched
ls patches/
cat patches/apply.sh
grep -c '^- \*\*' README.md  # rough check of "Patches Included" bullet count
```

**Step 2: Make sure README sections correspond to reality**

For every patch in `patches/`, README should have:

- A bullet in the top-of-file summary (line ~3).
- A "Patches Included" subsection.
- An entry in "Patch Ownership" table.
- A "When X Breaks" maintenance subsection.

For every patch that was dropped (opus-4-7 always; possibly tool-fix):

- Remove all the above.

**Step 3: Ensure `apply.sh` halts on errors** (it should already). Quick check:

```bash
head -5 patches/apply.sh  # expect `set -e` or similar
```

---

### Task G: Local full-stack dry run

**Step 1: Fresh upstream + full stack + typecheck**

```bash
rm -rf /tmp/opencode-refresh/opencode-v1.14.18-final
cd /tmp/opencode-refresh
git clone --depth 1 --branch v1.14.18 https://github.com/anomalyco/opencode.git opencode-v1.14.18-final
cd opencode-v1.14.18-final

# Apply caching (from cached repo):
git apply ~/projects/opencode-cached/patches/caching.patch
# Apply the remaining stack:
~/projects/opencode-patched/patches/apply.sh .

bun install
bun --cwd packages/opencode typecheck
bun --cwd packages/opencode test 2>&1 | tail -30
```

Expected: typecheck passes, tests pass (or the only failing tests are unrelated pre-existing upstream flakes — check HEAD tests before patches for baseline).

**Step 2: Smoke-build the binary for this architecture**

```bash
# Roughly what CI does, scaled to local:
bun --cwd packages/opencode build-cli  # or whatever command CI runs; check .github/workflows/build-release.yml
```

If there's no easy local build target, skip — CI will catch it. Not a hard gate.

---

### Task H: Commit, push, trigger build workflow (beads: `workstation-e39`)

**Step 1: Mark beads**

```bash
cd ~/projects/workstation
bd update workstation-e39 --status in_progress
```

**Step 2: Review changes in opencode-patched**

```bash
cd ~/projects/opencode-patched
git status
git diff --stat
```

Expected: `patches/opus-4-7.patch` deleted; `patches/apply.sh`, `patches/vim.patch`, `patches/tool-fix.patch` (or deleted), `patches/mcp-reconnect.patch`, `README.md` modified.

**Step 3: Commit**

Break into logical commits where possible:

```bash
# Commit 1: drop obsolete patch
git rm patches/opus-4-7.patch  # if not already staged
git add patches/apply.sh README.md
git commit -m "refactor: drop opus-4-7.patch (upstream v1.14.18 added opus-4-7 support)"

# Commit 2: refreshed patches
git add patches/vim.patch patches/tool-fix.patch patches/mcp-reconnect.patch
# Also any README changes that aren't part of the drop:
git add README.md
git commit -m "fix: refresh patch stack onto upstream v1.14.18"
```

If tool-fix was dropped, include that in commit 1 instead:

```bash
git rm patches/tool-fix.patch
# commit message becomes something like: "refactor: drop opus-4-7 + tool-fix (both now upstream in v1.14.18)"
```

**Step 4: Push**

```bash
git pull --rebase
git push
```

**Step 5: Trigger build workflow**

```bash
gh workflow run build-release.yml --repo johnnymo87/opencode-patched --field version=1.14.18
```

**Step 6: Watch**

```bash
RUN_ID=$(gh run list --repo johnnymo87/opencode-patched --workflow build-release.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN_ID" --repo johnnymo87/opencode-patched
```

Expected: all 4 platform builds succeed; darwin smoke test (verifies signed binary starts) passes; release `v1.14.18-patched` created.

**If darwin smoke test fails with `Killed: 9`**: this is the Bun Mach-O signing regression. See `.opencode/skills/darwin-signing.md`. Verify `BUN_NO_CODESIGN_MACHO_BINARY=1` is set in the build step env and explicit `codesign --force --sign -` runs after build. This should already be set (workflow hasn't changed), but if it regressed, fix it in a separate commit.

**Step 7: Verify release**

```bash
gh release view v1.14.18-patched --repo johnnymo87/opencode-patched
```

Expected: 4 assets — `opencode-linux-arm64.tar.gz`, `opencode-linux-x64.tar.gz`, `opencode-darwin-arm64.zip`, `opencode-darwin-x64.zip`.

**Step 8: Close beads task**

```bash
cd ~/projects/workstation
bd close workstation-e39 --reason "v1.14.18-patched released"
# Also close the per-patch tasks that were really waiting on CI:
bd close workstation-80r --reason "opus-4-7.patch dropped; v1.14.18-patched built successfully"
bd close workstation-b0p --reason "tool-fix resolved (refreshed or dropped); CI green"
bd close workstation-97f --reason "vim.patch refreshed; CI green"
bd close workstation-e1a --reason "mcp-reconnect verified/refreshed; CI green"
```

---

### Task I: Bump workstation and rebuild devbox (beads: `workstation-57y`)

**Step 1: Mark beads**

```bash
cd ~/projects/workstation
bd update workstation-57y --status in_progress
```

**Step 2: Trigger workstation auto-update workflow**

Instead of waiting up to 8h for the cron:

```bash
gh workflow run update-opencode-patched.yml --repo johnnymo87/workstation
```

This workflow:

1. Reads the latest `opencode-patched` release (now `v1.14.18-patched`).
2. Computes SHA256 for each platform asset.
3. Updates `users/dev/home.base.nix` with new version string + hashes.
4. Opens a PR with auto-merge enabled.

Watch it:

```bash
RUN_ID=$(gh run list --repo johnnymo87/workstation --workflow update-opencode-patched.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN_ID" --repo johnnymo87/workstation
```

**Step 3: Find and review the PR**

```bash
gh pr list --repo johnnymo87/workstation --state open --search 'auto/update-opencode-patched'
PR_NUM=$(gh pr list --repo johnnymo87/workstation --state open --search 'auto/update-opencode-patched' --json number -q '.[0].number')
gh pr view "$PR_NUM" --repo johnnymo87/workstation
gh pr diff "$PR_NUM" --repo johnnymo87/workstation
```

Expected: a single file change in `users/dev/home.base.nix` bumping `version = "1.4.3"` to `"1.14.18"` and updating 4 sha256 hashes.

**Step 4: Merge**

Auto-merge should fire after CI. If it doesn't (e.g., protection requires manual approval), merge manually:

```bash
gh pr merge "$PR_NUM" --repo johnnymo87/workstation --squash
```

**Step 5: Pull locally and rebuild devbox**

```bash
cd ~/projects/workstation
git pull --rebase
nix run home-manager -- switch --flake .#dev
```

Expected: home-manager downloads the new `opencode-linux-arm64.tar.gz`, places the binary in `~/.nix-profile/bin/opencode`. No sudo, fast.

If `flake.lock` needs updating first (unlikely — this is a `fetchurl` with explicit hashes, not a flake input), home-manager will complain about hash mismatch. Double-check the PR updated all 4 platform hashes.

**Step 6: Verify**

```bash
which opencode
opencode --version
```

Expected: path in `~/.nix-profile/bin/opencode`, version reports `1.14.18` (or whatever string the patched binary injects; it should NOT be `1.4.3`).

**Step 7: Close beads**

```bash
bd close workstation-57y --reason "devbox running opencode v1.14.18"
bd close workstation-3fq --reason "patch stack refresh complete: devbox on v1.14.18"
bd sync
```

---

### Task J: Close stale issues across all repos

**Step 1: opencode-cached build-failure issues** — already handled in caching plan Task 11. Double-check nothing remains:

```bash
gh issue list --repo johnnymo87/opencode-cached --label build-failure --state open
```

**Step 2: opencode-patched drift and build-failure issues**

```bash
gh issue list --repo johnnymo87/opencode-patched --state open
# Close each with a pointer to the v1.14.18-patched release:
for N in $(gh issue list --repo johnnymo87/opencode-patched --state open --json number -q '.[].number'); do
  gh issue close "$N" --repo johnnymo87/opencode-patched --comment "Resolved by v1.14.18-patched release."
done
```

Be careful: only close issues related to this refresh. If there are issues about unrelated features/bugs, leave them alone. Read titles first; close selectively.

**Step 3: workstation open PRs (if any stragglers)**

Shouldn't be any — the auto-update PR from Task I was merged. But check:

```bash
gh pr list --repo johnnymo87/workstation --state open
```

Cancel or close anything stale related to older opencode versions.

---

## Gotchas to Watch For

- **Upstream cuts v1.14.19 mid-flight**: Don't chase. Land v1.14.18 first, let the cron pick up later versions on its next cycle.
- **Darwin signing regression**: see `.opencode/skills/darwin-signing.md`. Reproduced locally means Bun Mach-O issue; keep `BUN_NO_CODESIGN_MACHO_BINARY=1` in workflow env.
- **`apply.sh` forgets a deleted patch**: if you drop a patch file but `apply.sh` still references it, CI fails at "file not found". Double-check with `bash -x patches/apply.sh .` in the stack checkout.
- **`packages/web/` creeping into patches**: when regenerating with `git diff`, narrow the paths you export. Use `git diff HEAD~..HEAD -- <specific files or dirs>` — not the unqualified form — unless you've verified no web changes crept in.
- **Patch order matters**: `apply.sh` currently applies caching first (from opencode-cached), then local patches. If you reorder local patches, verify they still apply — caching and vim both touch `config/config.ts`, so vim's patch must reference caching's post-state context, not upstream's raw config.ts.
- **`bd sync` pushes to the workstation remote**: if you've got dirty workstation commits that shouldn't go out, don't run `bd sync` until cleaned up.

---

## Fallback to v1.14.17

If v1.14.18 proves too hairy (e.g., major refactor breaks a whole patch and the rebase grows beyond the time budget), fall back to v1.14.17:

1. Substitute `1.14.17` for `1.14.18` everywhere.
2. Confirm `v1.14.17-cached` exists (or go refresh caching onto v1.14.17 first — the caching plan has an analogous fallback).
3. Update the design doc and beads notes to reflect the retargeted version.
4. Continue.

v1.14.18 vs v1.14.17 is rounding-error-level for our purposes.

---

## Rollback Plan

**If `v1.14.18-patched` has a runtime bug after workstation merged the bump:**

```bash
# 1. Revert workstation PR:
cd ~/projects/workstation
git log --oneline -5
git revert <bump-sha>
git push
nix run home-manager -- switch --flake .#dev  # reverts devbox to v1.4.3

# 2. Delete the bad release:
gh release delete v1.14.18-patched --repo johnnymo87/opencode-patched

# 3. Fix the patch stack, re-run build workflow, iterate.
```

If fundamentally broken and time-sensitive: stay on v1.4.3 for now, file bugs in opencode-patched, retry the refresh once upstream ships a newer release.

---

## Definition of Done

- `patches/` in `opencode-patched` contains only the patches that still need to exist (no opus-4-7; maybe no tool-fix).
- `apply.sh` and `README.md` are consistent with the actual patch set.
- `gh release view v1.14.18-patched --repo johnnymo87/opencode-patched` returns a release with 4 platform assets.
- `ssh devbox 'opencode --version'` (or locally on devbox) reports `1.14.18`.
- All beads tasks `workstation-5k6, 80r, b0p, 97f, e1a, e39, 57y, 3fq` are `closed`.
- All `build-failure` and `patch-drift` issues across the three repos are closed (or annotated as stale).
