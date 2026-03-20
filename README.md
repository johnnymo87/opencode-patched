# opencode-patched

**OpenCode with [prompt caching](https://github.com/anomalyco/opencode/pull/5422) + [vim keybindings](https://github.com/anomalyco/opencode/pull/12679)**

This repository combines two unmerged upstream patches into a single OpenCode binary, built automatically for 4 platforms.

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
      |-> builds v{VER}-patched       -- applies caching + vim patches, publishes
:01  opencode-patched/sync-vim-pr     -- checks PR #12679 for changes

:02  workstation/update-opencode-patched -- updates Nix config, opens PR
```

### Build Process

1. Clone upstream OpenCode at the release tag
2. Fetch `caching.patch` from [opencode-cached](https://github.com/johnnymo87/opencode-cached) (always latest from `main`)
3. Apply `caching.patch`, then local `vim.patch`
4. Build with Bun for 4 platforms (linux/darwin x arm64/x64)
5. Publish release as `v{VERSION}-patched`

### Patch Independence

The two patches modify completely different areas of the codebase:
- **Caching**: `provider/config.ts`, `provider/transform.ts`, `session/prompt.ts`, `config/config.ts`
- **Vim**: `cli/cmd/tui/component/vim/*`, `cli/cmd/tui/component/prompt/index.tsx`, `cli/cmd/tui/app.tsx`

Zero file overlap between the patches.

## Maintenance

### When the Caching Patch Breaks

This is handled by [opencode-cached](https://github.com/johnnymo87/opencode-cached). If the caching patch fails on a new upstream version, opencode-cached won't release, and this repo won't attempt a build.

### When the Vim Patch Breaks

1. The build fails and creates a GitHub issue automatically
2. Regenerate from the PR: `gh pr diff 12679 --repo anomalyco/opencode > patches/vim.patch`
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Vim PR Updates

The `sync-vim-pr.yml` workflow checks every 8 hours if PR #12679's diff has changed. If it has, it creates a GitHub issue for manual review.

### Sunset Criteria

Monthly automated check (`check-sunset.yml`) monitors both upstream PRs:
- **Vim PR merged**: Drop `vim.patch`, switch workstation to opencode-cached, archive this repo
- **Caching PR merged**: Drop caching fetch from `apply.sh`, check upstream directly
- **Both merged**: Switch workstation to upstream OpenCode, archive this repo and opencode-cached

## Credits

- **OpenCode**: [anomalyco/opencode](https://github.com/anomalyco/opencode)
- **Caching PR**: [PR #5422](https://github.com/anomalyco/opencode/pull/5422) by [@ormandj](https://github.com/ormandj)
- **Caching builds**: [opencode-cached](https://github.com/johnnymo87/opencode-cached)
- **Vim PR**: [PR #12679](https://github.com/anomalyco/opencode/pull/12679) by [@leohenon](https://github.com/leohenon)

## License

MIT (same as upstream OpenCode)
