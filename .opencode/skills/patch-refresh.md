# Skill: patch-refresh

Guidance for refreshing the opencode patch stack when upstream releases a new version.

## Repo Ownership

Each patch lives in exactly one repo. Never edit a patch in the wrong repo.

| Patch | Owned by repo | Upstream PR guide |
|-------|---------------|-------------------|
| `caching.patch` | `~/projects/opencode-cached` | PR #5422 |
| `vim.patch` | `~/projects/opencode-patched` (this repo) | PR #12679 |
| `tool-fix.patch` | `~/projects/opencode-patched` (this repo) | PR #16751 |

## When to Edit Sibling Repos

- **`caching.patch` broken?** → Open `~/projects/opencode-cached`, edit `patches/caching.patch` there.
- **`vim.patch` or `tool-fix.patch` broken?** → Edit in this repo (`~/projects/opencode-patched`).

Do not copy or duplicate patch content across repos.

## When to Use Upstream PRs as Behavioral Guides

Use the upstream PR diff as a behavioral reference, not as a direct patch to apply:

- **vim** (`PR #12679`): The PR defines intended vim motions and config surface. When rebasing, fetch the PR diff (`gh pr diff 12679 --repo anomalyco/opencode`) and use it to understand the intended behavior. Port only what is still missing from upstream; drop anything already merged.
- **tool-fix** (`PR #16751`): The PR defines the regression shape. Before refreshing, run the regression test from the PR against a plain upstream checkout. If the fix is already present upstream, **drop `tool-fix.patch` entirely**. If absent, regenerate from the PR diff.

## Refresh Workflow (Any Patch)

1. Check whether the upstream release already includes the behavior (run regression test or typecheck).
2. If included: drop the patch and update `patches/apply.sh`.
3. If not included: fetch the PR diff as a behavioral reference and rebase the patch minimally.
4. Verify with `bun --cwd packages/opencode typecheck` and any targeted regression tests.
5. Do not commit unless explicitly requested.
