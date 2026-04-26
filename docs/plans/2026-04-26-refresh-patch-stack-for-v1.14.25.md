# Refresh Patch Stack for v1.14.25 Implementation Plan

> **For Claude:** Use superpowers:executing-plans. This plan executes in this session, not a separate worktree (the work is small and mechanical).

**Goal:** Refresh the patch stack (`caching` in `opencode-cached`; `vim`, `tool-fix`, `mcp-reconnect`, `eager-input-streaming` in `opencode-patched`) onto upstream `anomalyco/opencode@v1.14.25`. Cut `v1.14.25-cached` and `v1.14.25-patched` releases. Bump `workstation` to consume `v1.14.25-patched`. Apply on cloudbox.

**Architecture:** Work directly on `main` in both `~/projects/opencode-cached` and `~/projects/opencode-patched`. Refresh hunks against a fresh checkout in `/tmp/opencode-refresh/opencode-v1.14.25-stack` (mirrors CI conditions). Patch order in `apply.sh`: `caching → vim → tool-fix → mcp-reconnect → eager-input-streaming`.

**Tech Stack:** Upstream opencode (TypeScript, Bun), git, bash, gh CLI, Nix.

---

## Background: Per-Patch Verdict (against clean v1.14.25)

Tested with `git apply --check` against fresh `anomalyco/opencode@v1.14.25`:

| Patch | Status | Failure detail |
|---|---|---|
| `caching.patch` | ❌ partial conflict | `agent.ts` hunk #1 + #2, `provider.ts` hunk #1 reject. All 3 are tiny context-only refreshes (see Task A). |
| `vim.patch` | ❌ partial conflict | `prompt/index.tsx` hunk #1 reject. Trivial — 4 new memos inserted upstream between the anchor lines (see Task C). |
| `tool-fix.patch` | ✅ clean | Despite ~944-line churn in `message-v2.ts`, the targeted hunk anchors still match. |
| `mcp-reconnect.patch` | ✅ clean | |
| `eager-input-streaming.patch` | ✅ clean | |

## Background: The 3 caching.patch rejects

All three rejects collapse to the same upstream refactor: **`PositiveInt` was moved out of inline declarations in `config/agent.ts` and `config/provider.ts` into `@/util/schema`**, and **`@/util/schema` now exports `NonNegativeInt` directly**. Upstream changed:

- `config/agent.ts` line 18 — local `const PositiveInt = …` removed (now imported).
- `config/provider.ts` line 6 — local `const PositiveInt = …` removed; import line is now `import { PositiveInt, withStatics } from "@/util/schema"`.
- `config/agent.ts` second hunk's anchor — `permission: Schema.optional(PermissionRef)` is now `permission: Schema.optional(ConfigPermission.Info)`.
- `@/util/schema` already exports `NonNegativeInt`.

So the patch's hunks that introduce `NonNegativeInt` next to a local `PositiveInt` are now both **wrong context** AND **redundant**. The fix is:

1. **Drop the `+const NonNegativeInt = …` introduction lines** (it's already provided by util/schema).
2. **Update the import line in `config/provider.ts`** from `import { PositiveInt, withStatics }` to `import { NonNegativeInt, PositiveInt, withStatics }` (or whatever order — stick with alphabetical).
3. **Add a `NonNegativeInt` import to `config/agent.ts`** (this file currently imports nothing from util/schema, since `PositiveInt` came in via the upstream import). Actually — verify: does `agent.ts` currently import `PositiveInt` from util/schema? If yes, just add `NonNegativeInt` to that existing import. If no (i.e. agent.ts does not currently use `PositiveInt`), add a new import line.
4. **Refresh the second hunk's anchor in `agent.ts`** from `Schema.optional(PermissionRef)` to `Schema.optional(ConfigPermission.Info)`.

## Background: The vim.patch reject

The `prompt/index.tsx` hunk had an anchor at the existing `auto` signal, which was preceded by `shell` memo. Upstream inserted 4 new memos (`editorPath`, `editorSelectionLabel`, `editorFileLabel`, etc) between `shell` and `auto`. The patch wants to insert one new line: `const vimEnabled = useVimEnabled()`. The fix is to update the surrounding context lines in the hunk to include the new upstream memos so the inserted line lands in the same logical spot (before `const [auto, setAuto] = createSignal<AutocompleteRef>()`).

---

## Compaction-Resilience Checklist

If resuming this plan after compaction:

1. Read this whole doc.
2. Check release status:
   ```bash
   gh release view v1.14.25-cached --repo johnnymo87/opencode-cached --json tagName 2>/dev/null | jq -r .tagName
   gh release view v1.14.25-patched --repo johnnymo87/opencode-patched --json tagName 2>/dev/null | jq -r .tagName
   ```
3. Check workstation pin: `grep 'version = ' ~/projects/workstation/users/dev/home.base.nix | head -1`. If `1.14.25`, only step left is rebuild on cloudbox/devbox.
4. Resume at the first unchecked task below.

**Current state at plan-write time (2026-04-26 17:55):**
- workstation pinned at `1.14.20` (just bumped today for the Vertex caching fix; commit `fea73f1`).
- `v1.14.20-cached`, `v1.14.20-patched` are the latest cached/patched releases (also just rebuilt for the Vertex fix).
- Most recent failed CI on opencode-cached was the Apr 26 16:09 attempt at `1.14.25` (hit the agent.ts/provider.ts rejects we're now fixing).

---

## Task List

- [ ] **A.** Refresh caching.patch in `opencode-cached` (agent.ts + provider.ts conflicts)
- [ ] **B.** Verify refreshed caching.patch applies cleanly + full bun test suite passes against v1.14.25
- [ ] **C.** Refresh vim.patch in `opencode-patched` (prompt/index.tsx context)
- [ ] **D.** Verify full patch stack applies in CI order against v1.14.25
- [ ] **E.** Commit + push opencode-cached; dispatch build-release for 1.14.25
- [ ] **F.** Wait for cached release; commit + push opencode-patched; dispatch build-release for 1.14.25
- [ ] **G.** Bump `workstation/users/dev/home.base.nix`: version `1.14.20`→`1.14.25`, all 4 platform hashes
- [ ] **H.** Apply `home-manager switch --flake .#cloudbox`
- [ ] **I.** Hand-off note for the next session

---

### Task A: Refresh caching.patch

**Working dir:** `/tmp/opencode-refresh/opencode-v1.14.25-stack` (already cloned anomalyco/opencode@v1.14.25). Make sure it's clean.

**Step A.1:** Apply the patch with `--reject` to leave `.rej` files for surgical fixing:

```bash
cd /tmp/opencode-refresh/opencode-v1.14.25-stack
git checkout . && find . -name '*.rej' -delete && rm -f packages/opencode/src/provider/config.ts packages/opencode/test/provider/config.test.ts
git apply --reject ~/projects/opencode-cached/patches/caching.patch 2>&1 | tail -10
ls **/*.rej
```

Expected: Two reject files (`agent.ts.rej`, `provider.ts.rej`); all other files applied.

**Step A.2:** Resolve `provider.ts.rej` first (it's the simplest):

The reject hunk wants to insert `const NonNegativeInt = …` after a local `PositiveInt` declaration. Upstream removed the local declaration and imports `PositiveInt` from `@/util/schema`, which already exports `NonNegativeInt`. Edit `~/projects/opencode-cached/patches/caching.patch`: find the hunk for `packages/opencode/src/config/provider.ts` (it should be hunk #1 of that file) and replace it with a hunk that just adds `NonNegativeInt` to the existing import.

Old hunk (the one that rejects):
```
@@ -3,6 +3,7 @@ import { zod } from "@/util/effect-zod"
 import { withStatics } from "@/util/schema"

 const PositiveInt = Schema.Number.check(Schema.isInt()).check(Schema.isGreaterThan(0))
+const NonNegativeInt = Schema.Number.check(Schema.isInt()).check(Schema.isGreaterThanOrEqualTo(0))

 export const Model = Schema.Struct({
   id: Schema.optional(Schema.String),
```

Replacement (against v1.14.25 upstream context):
```
@@ -1,4 +1,4 @@
 import { Schema } from "effect"
 import { zod } from "@/util/effect-zod"
-import { PositiveInt, withStatics } from "@/util/schema"
+import { NonNegativeInt, PositiveInt, withStatics } from "@/util/schema"

 export const Model = Schema.Struct({
```

**Step A.3:** Apply only the patched provider.ts hunk to verify (use `--include` filter or apply the whole patch and check):

```bash
cd /tmp/opencode-refresh/opencode-v1.14.25-stack
git checkout . && find . -name '*.rej' -delete && rm -f packages/opencode/src/provider/config.ts packages/opencode/test/provider/config.test.ts
git apply --reject ~/projects/opencode-cached/patches/caching.patch 2>&1 | grep -E 'reject|error|fail'
```

Expected: only `agent.ts.rej` remaining (no `provider.ts.rej`).

**Step A.4:** Resolve `agent.ts.rej`. There are two rejected hunks.

**Hunk #1** (introduces `NonNegativeInt`, after a local `PositiveInt`): same fix as provider.ts. Look at upstream agent.ts to see what's currently imported from `@/util/schema`:

```bash
grep '@/util/schema' /tmp/opencode-refresh/opencode-v1.14.25-stack/packages/opencode/src/config/agent.ts
```

If `agent.ts` already imports something from `@/util/schema`, replace this hunk with one that adds `NonNegativeInt` to that import. If `agent.ts` does NOT import from `@/util/schema`, replace it with a hunk that adds a new import line. Note `agent.ts` itself uses `PositiveInt`, so it must already import it — find that import and add `NonNegativeInt` next to it.

**Hunk #2** (adds `cache:` and `promptOrder:` fields to the agent schema): the only context-line change is `permission: Schema.optional(PermissionRef)` → `permission: Schema.optional(ConfigPermission.Info)`. Update that single context line in the hunk. The added (`+`) lines stay identical.

The patch's `+++ b/packages/opencode/src/config/agent.ts` hunk header `@@ -54,6 +55,30 @@` may also need its line numbers adjusted since the v1.14.25 file is structurally similar but with different surrounding content. Verify by reading lines 50–60 of the upstream file:

```bash
sed -n '50,60p' /tmp/opencode-refresh/opencode-v1.14.25-stack/packages/opencode/src/config/agent.ts
```

Then update the hunk header `@@ -<old-start>,<old-count> +<new-start>,<new-count> @@` to match. **`git apply` is strict about line counts and start positions** — easiest path is to re-derive the hunk by manually editing upstream and using `git diff` to regenerate.

**Recommended approach for Step A.4:**

Rather than hand-edit the patch, do this:

```bash
cd /tmp/opencode-refresh/opencode-v1.14.25-stack
git checkout .  # clean slate
find . -name '*.rej' -delete
rm -f packages/opencode/src/provider/config.ts packages/opencode/test/provider/config.test.ts

# Apply caching.patch with rejects
git apply --reject ~/projects/opencode-cached/patches/caching.patch 2>/dev/null

# Manually merge agent.ts.rej into agent.ts using your editor or sed. The two
# hunks are: (1) add `NonNegativeInt` import; (2) add cache + promptOrder
# fields above `permission`.
$EDITOR packages/opencode/src/config/agent.ts packages/opencode/src/config/agent.ts.rej

# Once agent.ts is merged correctly:
rm packages/opencode/src/config/agent.ts.rej
rm -f packages/opencode/src/config/agent.ts.orig

# Sanity-check by trying to build
cd packages/opencode && bunx tsc --noEmit 2>&1 | head -20
```

Then regenerate the canonical patch:

```bash
cd /tmp/opencode-refresh/opencode-v1.14.25-stack
# Add the new file (provider/config.ts) so git diff includes it
git add -N packages/opencode/src/provider/config.ts packages/opencode/test/provider/config.test.ts
git diff > /tmp/caching-v1.14.25.patch
diff /tmp/caching-v1.14.25.patch ~/projects/opencode-cached/patches/caching.patch | head -50  # sanity-check diff is small
cp /tmp/caching-v1.14.25.patch ~/projects/opencode-cached/patches/caching.patch
```

### Task B: Verify caching.patch

**Step B.1:** Clean checkout, apply, run tests:

```bash
cd /tmp && rm -rf opencode-test && git clone --depth 1 --branch v1.14.25 https://github.com/anomalyco/opencode.git opencode-test
cd opencode-test
git apply --check ~/projects/opencode-cached/patches/caching.patch && echo "CHECK OK"
git apply ~/projects/opencode-cached/patches/caching.patch
bun install
cd packages/opencode
bun test test/provider/config.test.ts test/provider/transform.test.ts test/session/llm.test.ts
```

Expected: all tests pass (the patch is the same patch we shipped today, just rebased — only the agent.ts/provider.ts mechanical fix should differ).

**Step B.2:** Cleanup: `rm -rf /tmp/opencode-test`

### Task C: Refresh vim.patch

**Step C.1:** In `/tmp/opencode-refresh/opencode-v1.14.25-stack` (with caching.patch already applied from Task A), apply vim.patch with rejects:

```bash
cd /tmp/opencode-refresh/opencode-v1.14.25-stack
git apply --reject ~/projects/opencode-patched/patches/vim.patch 2>&1 | tail -5
ls **/*.rej
```

Expected: only `prompt/index.tsx.rej`.

**Step C.2:** Look at the rejected hunk vs. current upstream:

```bash
cat packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx.rej
sed -n '105,130p' packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx
```

The patch wants to insert `const vimEnabled = useVimEnabled()` between the `shell` memo and the `auto` signal. Upstream inserted new memos (`editorPath`, `editorSelectionLabel`, `editorFileLabel`) between them. The fix is to either:
  - (a) move the inserted line to the new "right" spot (before the `auto` signal but after the new upstream memos), or
  - (b) keep it adjacent to `shell` (where the original PR put it).

Choose (a) — keep it adjacent to `auto`, since that's where the original vim PR (`anomalyco/opencode#12679`) intended it. Manually edit `packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx` to add the line in the right spot, then regenerate the patch:

```bash
$EDITOR packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx
rm packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx.rej packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx.orig 2>/dev/null

# Regenerate vim.patch — but only the diff vs. the post-caching baseline.
# Easiest way: stash the caching.patch changes, regenerate, restore.
# Actually simpler: regenerate the full vim.patch from a clean v1.14.25 base,
# since vim.patch is a standalone patch.
```

Better approach: regenerate vim.patch from a clean v1.14.25 (without caching applied), since vim.patch doesn't depend on caching.patch:

```bash
cd /tmp && rm -rf opencode-vim-rebase && git clone --depth 1 --branch v1.14.25 https://github.com/anomalyco/opencode.git opencode-vim-rebase
cd opencode-vim-rebase
git apply --reject ~/projects/opencode-patched/patches/vim.patch
# Manually fix prompt/index.tsx to insert `const vimEnabled = useVimEnabled()` before the `auto` signal
$EDITOR packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx
rm packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx.rej

# Regenerate. vim.patch creates new files (vim/*.ts) so use `git add -N` to include them in diff.
git add -N packages/opencode/src/cli/cmd/tui/component/vim/index.ts packages/opencode/src/cli/cmd/tui/component/vim/vim-handler.ts packages/opencode/src/cli/cmd/tui/component/vim/vim-indicator.ts packages/opencode/src/cli/cmd/tui/component/vim/vim-motion-jump.ts packages/opencode/src/cli/cmd/tui/component/vim/vim-motions.ts packages/opencode/src/cli/cmd/tui/component/vim/vim-scroll.ts packages/opencode/src/cli/cmd/tui/component/vim/vim-state.ts packages/opencode/test/cli/tui/vim-motions.test.ts 2>/dev/null
git diff > /tmp/vim-v1.14.25.patch
cp /tmp/vim-v1.14.25.patch ~/projects/opencode-patched/patches/vim.patch
```

### Task D: Verify full stack applies

**Step D.1:** Use the actual `apply.sh` to mirror CI:

```bash
cd /tmp && rm -rf opencode-stack-test && git clone --depth 1 --branch v1.14.25 https://github.com/anomalyco/opencode.git opencode-stack-test

# Override the URL fetch in apply.sh — instead, copy local caching.patch into
# the script's working dir, or temporarily patch apply.sh to use a local file.
# Simplest: just run each git apply manually in CI order.
cd opencode-stack-test
git apply ~/projects/opencode-cached/patches/caching.patch && echo "✓ caching"
git apply ~/projects/opencode-patched/patches/vim.patch && echo "✓ vim"
git apply ~/projects/opencode-patched/patches/tool-fix.patch && echo "✓ tool-fix"
git apply ~/projects/opencode-patched/patches/mcp-reconnect.patch && echo "✓ mcp-reconnect"
git apply ~/projects/opencode-patched/patches/eager-input-streaming.patch && echo "✓ eager-input-streaming"
```

All five must succeed. If any fails, the stack interaction needs debugging.

**Step D.2:** Optional but recommended — run a subset of the test suite to catch breakage:

```bash
cd opencode-stack-test
bun install
cd packages/opencode
bun test test/provider/ test/session/llm.test.ts 2>&1 | tail -10
```

**Step D.3:** Cleanup: `rm -rf /tmp/opencode-stack-test /tmp/opencode-vim-rebase /tmp/opencode-refresh`

### Task E: Ship caching.patch

```bash
cd ~/projects/opencode-cached
git status  # should show only patches/caching.patch modified
git diff --stat patches/caching.patch
git add patches/caching.patch
git commit -m "fix: rebase caching patch onto v1.14.25

Upstream v1.14.25 moved PositiveInt and NonNegativeInt into
@/util/schema (previously defined inline in config/agent.ts and
config/provider.ts), and renamed PermissionRef to ConfigPermission.Info
in config/agent.ts. Refresh the affected hunks: drop the inline
NonNegativeInt declarations (use util/schema's exports) and update
context lines to match v1.14.25."
git push

# Trigger fresh build for 1.14.25 (no v1.14.25-cached release exists yet).
gh workflow run build-release.yml --repo johnnymo87/opencode-cached --field version=1.14.25
sleep 3
gh run list --repo johnnymo87/opencode-cached --workflow=build-release.yml --limit 1
# Watch
RUN_ID=$(gh run list --repo johnnymo87/opencode-cached --workflow=build-release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo johnnymo87/opencode-cached --exit-status
```

### Task F: Ship patched stack

Wait for `v1.14.25-cached` release to exist, then:

```bash
gh release view v1.14.25-cached --repo johnnymo87/opencode-cached --json tagName
# Should print: {"tagName":"v1.14.25-cached"}

cd ~/projects/opencode-patched
git status
git diff --stat patches/vim.patch
git add patches/vim.patch
git commit -m "fix: refresh vim.patch context for v1.14.25

Upstream v1.14.25 inserted new memos (editorPath, editorSelectionLabel,
editorFileLabel) in prompt/index.tsx between the existing 'shell' memo
and the 'auto' signal. Refresh the patch's anchor so 'vimEnabled' lands
adjacent to the 'auto' signal (matching the original PR #12679 intent)."
git push

gh workflow run build-release.yml --repo johnnymo87/opencode-patched --field version=1.14.25
sleep 3
RUN_ID=$(gh run list --repo johnnymo87/opencode-patched --workflow=build-release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo johnnymo87/opencode-patched --exit-status
```

### Task G: Bump workstation

Compute SRI hashes for all 4 platforms:

```bash
cd /tmp && mkdir -p ocp-1.14.25 && cd ocp-1.14.25
for asset in opencode-linux-arm64.tar.gz opencode-darwin-arm64.zip opencode-linux-x64.tar.gz opencode-darwin-x64.zip; do
  curl -sL "https://github.com/johnnymo87/opencode-patched/releases/download/v1.14.25-patched/$asset" -o "$asset" &
done
wait
for f in opencode-linux-arm64.tar.gz opencode-darwin-arm64.zip opencode-linux-x64.tar.gz opencode-darwin-x64.zip; do
  hash=$(nix hash file --base64 --type sha256 "$f")
  echo "$f -> sha256-$hash"
done
```

Edit `~/projects/workstation/users/dev/home.base.nix`:
- Change `version = "1.14.20"` → `version = "1.14.25"`
- Replace all 4 platform hashes with the new ones

```bash
cd ~/projects/workstation
git diff users/dev/home.base.nix
git add users/dev/home.base.nix
git commit -m "chore(deps): update opencode-patched to 1.14.25"
git push
rm -rf /tmp/ocp-1.14.25
```

### Task H: Apply

```bash
cd ~/projects/workstation
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -10
opencode --version  # 1.14.25
readlink -f $(which opencode)  # confirm new derivation path
```

### Task I: Hand-off

- macOS / other devbox machines won't auto-update yet; the nightly `update-opencode-patched.yml` workflow will detect `1.14.25` is the new latest and open a PR.
- If you ran this on cloudbox, the running OpenCode session is on the OLD binary — restart OpenCode to use the new one.
- Note in the next session: the next upstream version refresh likely needs no plan — only Task G (bump version + hashes) and Task H (rebuild) if all 5 patches still apply cleanly.
