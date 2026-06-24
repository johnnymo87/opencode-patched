# ProjectCopy.refreshAfterBoot per-boot cost — fork-patch design

- **Bead:** workstation-wvv2 (builds on shipped workstation-sqd5)
- **Date:** 2026-06-23
- **Author:** swarm Worker 1 (design-only round)
- **Status:** DESIGN — awaiting coordinator/human decision. No code written.
- **Update (round 2):** added §8 — consumer inventory of the tracked-directory
  index + a **disable-vs-cooldown** verdict. **New leading recommendation:
  DISABLE `refreshAfterBoot` on headless deploys via an env flag** (bigger win
  than the cooldown; nothing in the headless/serve/TUI path depends on the boot
  refresh). The §1–§7 cooldown design remains the fallback if we want to keep
  bounded auto-discovery in the same binary.

---

## 1. Problem

`ProjectCopy.refreshAfterBoot` (`packages/core/src/project/copy.ts:126`) runs
**once on every location/instance boot**. It is wired into the per-location
service map at `packages/core/src/location-layer.ts:108`:

```ts
const projectCopyRefresh = Layer.effectDiscard(ProjectCopy.refreshAfterBoot).pipe(Layer.provide(services))
```

The location service map (`LocationServiceMap.lookup`) builds a **`Layer.fresh`**
stack per location with **`idleTimeToLive: "60 minutes"`**. So every time a
location is (re)booted — idle eviction + re-access, a reconnect/poll storm, a
cold serve start — the full refresh fires again.

### Cost of one `refresh()` (now `refreshImpl` after patched.5)

For a tracked project with ~136 directories (a big multi-worktree `mono`):

1. `directories.list(projectID)` — 1 DB `SELECT` of all tracked dirs.
2. `fs.isDir` per tracked dir (~136 stats), fan-out (bounded to 4 by patched.5).
3. For each **source** dir (`strategy === undefined && exists`, ~100+):
   `strategy.list(sourceDir)` (git-worktree strategy) runs, per source dir:
   - `git.find(sourceDir)` → `fs.up` walk for `.git` **+ 2 git subprocesses**
     (`rev-parse --show-toplevel`, `rev-parse --git-common-dir`), and
   - `git.worktreeList(repo)` → **1 git subprocess** (`worktree list --porcelain`),
   - `canonical(entry)` = `fs.isDir` per discovered worktree.
   → **~3 git subprocesses per source dir** ⇒ **~300 subprocesses** for ~100
     source dirs. This subprocess fan-out is the dominant cost.
4. One write transaction reconciling discovered vs. removed dirs.

**Observed live 2026-06-23:** a cold serve boot pegged one core at 111–114% for
~3–4 min running these bootstrap refreshes, then idled. That is the refresh
**cost** (it logs `project copy refresh started`/`done` and completes) — NOT the
silent step-end spin (separate problem, Worker 3 / upstream #29762; do not
conflate).

### What patched.5 already did (and did not do)

`patches/project-copy-debounce.patch` (workstation-sqd5, shipped in patched.5)
added only:

- **(a)** a module-scope single-flight `Map<projectID, Deferred>` that coalesces
  **concurrent** `refresh()` calls for the same projectID onto one in-flight run,
  and
- **(b)** `REFRESH_CONCURRENCY = 4` replacing `concurrency: "unbounded"` at both
  `Effect.forEach` fan-out sites.

This stops the reconnect-**storm** wedge (many concurrent refreshes → 19.6 GB
RSS / HTTP wedge). It does **nothing** for the per-boot recompute **cost**:
every boot that is not concurrent with another still pays the full O(#dirs) scan
+ ~300 subprocesses.

### Upstream status (verified 2026-06-23)

`copy.ts` still exists on current upstream `dev` and still uses
`concurrency: "unbounded"` at both sites. Upstream additionally **removed** the
`boot.wait()` gate at the head of `refreshAfterBoot`, i.e. it fires the refresh
**more** eagerly. There is no upstream fix to ride. A fork patch is the path.

---

## 2. Two callers of `refresh()` — the key design lever

`copies.refresh({ projectID })` has exactly two callers:

1. **`refreshAfterBoot`** (`copy.ts:133`) — automatic, once per boot. **This is
   the bottleneck.**
2. **HTTP handler `projectCopy.refresh`**
   (`packages/server/src/handlers/project-copy.ts:34`, route
   `POST /experimental/project/{projectID}/copy/refresh`) — an **explicit,
   user/client-triggered rescan**.

This split is the central design lever: **any throttle must apply to the boot
path only, never to the explicit HTTP rescan.** A user who asks for a rescan must
get a real one. Therefore the gate belongs in `refreshAfterBoot`, not inside
`refresh()`.

---

## 3. Options considered

### Option A — In-memory per-projectID cooldown at the boot path  *(RECOMMENDED)*

Add a module-scope `Map<projectID, lastSuccessEpochMs>` (sibling to the existing
`refreshInFlight` map, same file, same rationale). In `refreshAfterBoot`, after
`boot.wait()` and before logging `started`:

- if `now - last < REFRESH_COOLDOWN_MS` → log `project copy refresh skipped
  (cooldown)` and return (never enters `refresh()` / single-flight);
- otherwise run `refresh()`; **on success only**, record `now`.

**Effect on the bottleneck.** Within one serve process, boots of a project go
from O(#boots) refreshes to **≈ 1 execution per projectID per cooldown window**.
Combined with the existing single-flight, the behaviour is essentially optimal:

- single-flight collapses **concurrent** boots → 1 execution;
- cooldown collapses **sequential** boots within the window → skipped (a single
  `Map` lookup, no DB read, no stats, no subprocesses).

**Persistence.** In-memory ⇒ lost on serve restart. Each fresh serve pays once
per projectID on its first boot of that project, then skips for the window.
Across the ~4-serve pool the worst case is ~4 refreshes per window per project
(one per serve), and the single-flight already de-storms each of those. Net: a
massive reduction from "every boot" with the smallest possible surface.

**Patch size / risk.** ~+20–30 lines in `copy.ts` (one `Map`, one const, the
guard + success-record in `refreshAfterBoot`, a skip log) + 1 `it.live` test.
**Zero** schema, **zero** migration, pure additive module state. Lowest rebase
cost of any option — important for a carry-patch that survives every upstream
bump. Composes with the existing patch in the same file.

### Option B — DB-persisted cooldown timestamp

Same gate, but persist "last refreshed" in SQLite so it survives serve restarts
⇒ **≈ 1 refresh per projectID per window across the whole box**.

- **B1:** add a nullable column `time_directories_refreshed integer` to the
  `project` table (precedent exists: `time_initialized integer` is already a
  nullable per-project timestamp). Read it at boot, write it on success.
- **B2:** a dedicated `project_copy_refresh(project_id PK, time_refreshed)`
  table. More isolation, more surface.

**Cross-serve coherence.** Read timestamp at boot; skip if fresh. The TOCTOU
across serves is benign — worst case two serves each refresh once, each bounded
by its own single-flight.

**Patch size / risk.** Medium-to-high **carry cost**. Drizzle migrations here are
explicit, timestamped TS files registered in a generated, append-only
`migration.gen.ts` (a rebase/merge-conflict magnet), plus a `schema.sql` edit.
Every upstream bump must re-carry the migration + the gen-list line + the schema
change. That is real friction for a marginal gain over A (surviving the rare
rolling restart).

### Option C — Incremental / cached `git worktree list` keyed on admin-dir mtime

Cache `find()` per source dir (its result is static for a path) and cache
`worktreeList` output keyed on the mtime of `<git-common-dir>/worktrees`. On
refresh, stat the admin dir; if unchanged, reuse the cached list and skip the ~3
subprocesses for that dir; else re-run.

**Effect.** Makes each refresh cheaper **when worktree sets are stable**, but
still runs per boot (still O(#dirs) stats + cache lookups) and a cold process =
cold cache = full cost on the first boot — it does **not** address the
"every-boot" frequency that is the actual pain.

**Patch size / risk.** Largest and most subtle (mtime 1s granularity races,
NFS, `git worktree prune`, repos with zero worktrees where the `worktrees`
admin dir does not exist, the worktree's own `.git` being a file). Highest
rebase surface (touches `copy-strategies.ts` / `git.ts`). Wrong tool for the
observed problem.

---

## 4. Recommendation

**Ship Option A now.** Keep **Option B1 in the back pocket** as a follow-up only
if rolling-pool-restart herds prove to still hurt in practice. Do **not** pursue
Option C unless a *single* first-boot refresh on a huge project is itself shown
to be intolerable even at concurrency 4 (in which case C layers on top of A
later — they are orthogonal).

Rationale:

- The observed pain is **per-boot within long-lived serves** (idleTTL 60m
  re-boots + reconnect storms). Option A eliminates that class with the
  smallest, lowest-risk, zero-schema patch.
- It is the natural extension of the patched.5 patch: same file, same
  module-scope-map pattern; the two together give "≈1 execution per projectID
  per process per window" with no new infrastructure.
- It leaves the explicit HTTP `projectCopy.refresh` rescan fully functional.
- Option B's only marginal win (surviving serve restarts) is bounded and rare;
  its migration surface is recurring rebase cost. Defer it.

---

## 5. Correctness tradeoffs (addressed)

1. **Stale rows linger up to the cooldown.** A worktree deleted on disk stays in
   the `project_directory` table for ≤ cooldown (until the next non-skipped
   boot reconciles it). **This is safe** because the DB row is *advisory, not
   authoritative*: every consumer resolves a directory through `canonical()` /
   `fs.isDir` at **use** time, and a missing dir yields
   `DirectoryUnavailableError` (see `copy.ts` `canonical`, and `source`). The
   refresh's only job is DB hygiene; a bounded, self-healing staleness window is
   acceptable. Symmetrically, a worktree *added* on disk shows up within ≤
   cooldown on the next boot — or instantly via the explicit HTTP rescan.
2. **Record on success only.** A failed refresh (the `catchCause` path) must NOT
   arm the cooldown, so a transient failure retries on the next boot rather than
   being suppressed for the whole window.
3. **Interaction with the single-flight.** The cooldown is checked *before*
   entering `refresh()`. Concurrent first boots all see a cold cooldown, enter
   `refresh()`, and coalesce via the existing single-flight to one execution;
   each records the (identical) success timestamp — idempotent. Subsequent boots
   within the window short-circuit before the single-flight. No interference.
4. **Explicit rescan decoupling (Option A).** The HTTP rescan does the real work
   but does **not** update the in-memory cooldown. Worst case: one redundant
   boot-refresh shortly after a manual rescan. Accepted to keep the patch
   minimal and the two paths decoupled. (Option B could couple them by writing
   the timestamp inside `refresh()` on success — a reason to prefer B *if* that
   coupling is ever desired.)
5. **Cross-serve coherence (Option A).** None beyond per-process; each serve
   refreshes at most once per window per project. Acceptable; the single-flight
   bounds the herd. Option B is the lever if box-wide coherence is required.

---

## 6. Implementation sketch (for the later build round — NOT executed now)

Extend `patches/project-copy-debounce.patch`, all within
`packages/core/src/project/copy.ts`:

```ts
// module scope, next to refreshInFlight
export const REFRESH_COOLDOWN_MS = <T> * 60_000 // see open question
const refreshCooldown = new Map<Project.ID, number>()
```

```ts
// inside refreshAfterBoot, after boot.wait()
const last = refreshCooldown.get(location.project.id)
if (last !== undefined && Date.now() - last < REFRESH_COOLDOWN_MS) {
  yield* Effect.logInfo("project copy refresh skipped (cooldown)", {
    projectID: location.project.id,
    ageMs: Date.now() - last,
  })
  return
}
yield* Effect.logInfo("project copy refresh started", { projectID: location.project.id })
const result = yield* copies.refresh({ projectID: location.project.id })
refreshCooldown.set(location.project.id, Date.now())   // success only — after refresh resolves
yield* Effect.logInfo("project copy refresh done", { ... })
```

**Test (TDD, `it.live` in `project-copy.test.ts`):** drive `refreshAfterBoot`
twice for the same projectID within the window and assert the strategy's `list`
is invoked on the first boot only (the second is skipped); a third call with a
mocked/elapsed clock past the window re-invokes. Reuse the `countingStrategy`
helper already added by patched.5. Keep the existing 3 single-flight/concurrency
tests green.

**Estimated delta:** ~+20–30 lines patch, +1 test. Core typecheck + the existing
project-copy test suite must stay green; then `apply.sh` + build + the usual
rolling deploy + live-verify (a cold serve boot should now show one
`started`/`done` per projectID per window, and skipped lines for subsequent
re-boots, with CPU not pegging on every boot).

---

## 7. Open question for human decision (escalate to coordinator)

**`REFRESH_COOLDOWN_MS` (T).** Must be `< idleTTL` (60 min) to be meaningful,
and long enough to absorb reconnect storms + frequent re-boots, but short enough
that disk/DB drift self-heals promptly on the boot path.

- **Proposed default: 10 minutes.** Covers storms and frequent re-boots; a
  worktree add/remove reconciles within ≤10 min on the next boot, and the
  explicit HTTP rescan remains instant.
- Alternatives: 15 min (fewer refreshes, longer drift) or 5 min (more refreshes,
  fresher DB).

**Secondary decision: A vs. B1.** Recommendation is A (ship now, zero schema).
Confirm whether box-wide cross-restart coherence is wanted enough to justify the
recurring migration carry-cost of B1; default is **no — defer B1**.

Both are policy knobs, not correctness issues; flagging for a human call before
the build round.

---

## 8. Round 2 — Consumer inventory & the "can we just DISABLE it?" verdict

The human asked whether, on our **headless cloudbox** usage, we can simply
**disable / neuter** `refreshAfterBoot` instead of cooldown-ing it. Short
answer: **yes — and it's the bigger, simpler win.** Full inventory below.

### 8.1 Pre-verified facts (not re-derived)

- **Project identity is git-derived, not index-derived.** `Project.resolve`
  (core `project.ts:118`) = `git.find` → `id = hash(git remote) ?? previous
  ?? root`. It never reads `project_directory`. So session→project resolution
  does not depend on the index at all.

### 8.2 WRITERS of the `project_directory` index

| # | Writer | Location | Registers | Depends on refreshAfterBoot? |
|---|--------|----------|-----------|------------------------------|
| 1 | `saveProjectDirectory` (called from `fromDirectory`) | `packages/opencode/src/project/project.ts:329` | the **opened directory** as a **source** dir (no strategy), on **every** project resolution / location open | **No** — independent of refresh |
| 2 | `ProjectCopy.create` | core `copy.ts:209` | a worktree **copy** (strategy `git_worktree`), when one is created via the API | No |
| 3 | `ProjectCopy.refresh` | core `copy.ts:266/277` | **the only discovery+prune path**: discovers out-of-band worktree copies of source dirs (`git worktree list`) and prunes dirs missing on disk | **This is what refreshAfterBoot triggers** |
| 4 | `migrateProjectId` | opencode `project.ts:204` | DELETEs the dir list on a project-ID migration; "relies on it being re-populated" | source dir re-populated immediately by #1 in the same `fromDirectory` flow; only copies wait for a later refresh |

**Key takeaway:** the *primary* writer of source dirs is #1 (on open), **not**
refresh. `refreshAfterBoot` uniquely provides only (a) auto-**discovery** of
out-of-band worktree copies and (b) auto-**pruning** of deleted dirs.

### 8.3 READERS of the index

| Reader | Location | Class | Needs refresh-discovered copies? |
|--------|----------|-------|----------------------------------|
| `Project.directories()` (core interface) | core `project.ts:59` | plumbing | — (just `projectDirectories.list`) |
| HTTP `GET …/project/{id}/directories` | opencode `…/httpapi/handlers/project.ts:53` | serve API surface | passes through whatever is in the table |
| TUI `context/project.tsx:45` (`sync()` → `mainDir`) | TUI client | **headless-TUI** | **No** — `mainDir = findLast(strategy===undefined)`, i.e. a **source** dir; source dirs are registered on open |
| TUI `dialog-move-session.tsx:74` (move session) | TUI client | **headless-TUI** | wants copies, **but calls its own on-demand `projectCopy.refresh` first** (`:66`) — does not rely on refreshAfterBoot |
| app `home.tsx` / `dialog-select-directory.tsx` | desktop/web app | **desktop-app-only** | yes for full freshness; **not our headless usage** |
| `ProjectCopy.source()` `directories.contains` (create gate) | core `copy.ts:179` | serve (create) | No — source dir registered on open ⇒ `contains()` true |
| `ProjectCopy.remove()` `directories.get` | core `copy.ts:221` | serve (remove) | No — operates on the copy being removed |

**Fork patches:** NONE of `serve-lease` / `attach-route-resolve` /
`event-*` / pigeon read the index. Only `project-copy-debounce.patch` touches
ProjectCopy. → **no fork-patch dependency on refreshAfterBoot.**

**Event:** `project.directories.updated` has **no TUI/app subscriber** that
refetches on it; it still fires on create/remove/explicit-refresh. Neutering the
boot refresh only drops the boot-time emission.

### 8.4 Does anything headless depend on refreshAfterBoot having run? — **No**

- Session→project resolution is git-derived (§8.1).
- Source-dir registration happens on open (§8.2 #1), not via refresh.
- TUI `mainDir` derives from source dirs (present without refresh).
- The one TUI consumer that wants discovered copies (move-session dialog) does
  its **own** on-demand refresh.
- `ProjectCopy.create/remove` gates use source dirs (on open) or the target
  copy — never refresh-discovered data.
- No fork patch reads the index.

### 8.5 What concretely degrades if refreshAfterBoot is gone

- **For us (headless serve + TUI):** effectively nothing. Out-of-band worktree
  copies are not auto-listed in the index until an explicit refresh — but the
  only place that wants them (move-session dialog) refreshes on demand. Deleted
  dirs linger as **advisory** rows (every consumer stat-guards at use time via
  `canonical()`/`fs.isDir` → `DirectoryUnavailableError`).
- **One cosmetic TUI nuance:** without refresh, every opened dir is registered
  with `strategy === undefined` (refresh is what tags worktree copies as
  `git_worktree`). So `mainDir` (TUI directory switcher highlight) is derived
  from a possibly-less-precise set, but it always returns a real, stat-guarded
  directory — not a correctness break.
- **For the desktop app (not our usage):** the home page's per-directory
  session grouping would miss out-of-band worktrees until a refresh. This is the
  behavior we trade away — and only when the flag is set.

### 8.6 VERDICT & minimal patch shape

**Recommend: DISABLE `refreshAfterBoot` behind an env flag, default = current
upstream behavior; our cloudbox serves set the flag to off.** This eliminates
100% of the per-boot cost (vs. the cooldown's "≈1 refresh per window"), is the
smallest diff, and nothing headless depends on it. Gating (rather than hard
removal) preserves upstream parity by default and mirrors the existing
env-gated fork patches (`serve-lease` is `OPENCODE_ROUTING_DB`-gated; unset =
no-op).

**Minimal diff (extends `project-copy-debounce.patch`, stays confined to
`copy.ts` — the file we already patch, so no new file / no schema):**

```ts
export const refreshAfterBoot = Effect.gen(function* () {
  // Headless deploys (cloudbox serve pool) opt out of the per-boot project-copy
  // refresh entirely. Nothing in the serve/TUI path depends on the boot refresh
  // having run: source dirs self-register via Project.saveProjectDirectory on
  // open; the move-session dialog triggers its own on-demand refresh; project
  // identity is git-derived, not index-derived (Project.resolve). Unset = the
  // upstream every-boot behavior. See workstation-wvv2.
  if (process.env["OPENCODE_PROJECT_COPY_REFRESH_ON_BOOT"] === "0") return
  const location = yield* Location.Service
  // … unchanged …
})
```

Plus a one-line deploy change in the **workstation** repo: set
`OPENCODE_PROJECT_COPY_REFRESH_ON_BOOT = "0"` as a **systemd `Environment=`** on
the `opencode-serve@` units in `hosts/cloudbox/configuration.nix` (NOT
`home.base.nix` `initExtra`, which is interactive-shell-only and never reaches
the serve units), consistent with how the other `OPENCODE_*` serve flags are
set. (Per coordinator, 2026-06-23.)

- **Estimated patch size:** ~+4–6 lines in `copy.ts` (the guard + comment),
  inside the existing patch; **zero** schema/migration; **+1** test (assert
  `refreshAfterBoot` short-circuits when the flag is `"0"`). Risk: very low.
- **Explicit refresh preserved:** the gate is only at the boot entry point;
  `copies.refresh()` (HTTP endpoint + move-session dialog) is untouched.

**Disable vs. cooldown — when to pick which:**

| | Disable (flag, §8.6) | Cooldown (Option A, §3) |
|---|---|---|
| Per-boot cost | **0** | ≈1 refresh / projectID / window / serve |
| Boot-time auto-discovery of out-of-band copies | gone (recover via explicit refresh) | preserved (throttled) |
| Code | ~4–6 lines, no state | ~20–30 lines + module map + test |
| Best for | **headless cloudbox (our case)** | a binary that must keep periodic auto-discovery (e.g. desktop app pointed at it) |

**Recommendation:** ship the **disable flag** for cloudbox; it supersedes the
cooldown for our usage. Keep the §1–§7 cooldown design on the shelf as the
fallback if we later want bounded auto-discovery without a hard off. The two are
composable (flag fully off > cooldown > unbounded) but we only need one.

### 8.7 Open questions for the human (round 2)

1. **Default polarity of the flag.** Recommended: default = upstream behavior
   (on), opt-out via `OPENCODE_PROJECT_COPY_REFRESH_ON_BOOT=0` set by our nix.
   Alternative: default-off in the fork build (no nix plumbing, but changes
   behavior for any non-cloudbox use of the fork binary). Recommend the former.
2. **Disable vs. cooldown** for cloudbox. Recommend **disable** (bigger win,
   simpler). Confirm we are OK losing boot-time auto-discovery of out-of-band
   worktree copies (recoverable via the explicit refresh the move dialog already
   triggers).
