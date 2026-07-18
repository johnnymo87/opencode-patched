# CI Efficiency Findings — opencode-patched GitHub Actions

Read-only investigation. **No workflow/code changes were made.** All recommendations
below are proposals; nothing here has been applied.

## Method & evidence base

- Enumerated all 5 workflows in `.github/workflows/`.
- Pulled the last **300 runs** via `gh run list` (span **2026-06-22 → 2026-07-18**,
  fully covering the Jul 1–17 billing window with no truncation).
- Computed **billed** minutes per run from the per-job `jobs` API
  (`started_at`→`completed_at`), applying GitHub's real billing rules:
  **each job rounded UP to a whole minute**, **macOS ×10**, Windows ×2, Linux ×1.
- The `/timing` billing endpoint returns zeros for this token (missing billing
  scope), so per-job wall-clock is the measurement source.

### Currency note
Figures are in **quota-minutes** (macOS already multiplied ×10) to match the
"3,000 included / 3,239 consumed" framing. Dollar figures use overage rates
**Linux $0.008/actual-min, macOS $0.08/actual-min**.

## Measured spend, Jul 1–17 window (billed / quota-minutes)

| Workflow | Runs | Billed min | Notes |
|---|---:|---:|---|
| **Build and Release** | 40 | **~747** | 10 success ≈387, **30 FAILURE ≈360** |
| Sync upstream opencode Releases | 51 | ~102 | 2 billed/run (inflated by `fetch-depth: 0`) |
| Sync Tool Fix PR Changes | 51 | ~51 | 1 billed/run |
| Sync Vim PR Changes | 51 | ~51 | 1 billed/run |
| Check Upstream Patch Status | 1 | ~0 | monthly cron |
| **Measured total** | | **~951** | |

**[assumption] Reconciliation gap:** the account-level report cites ~3,239
min for this repo in-window, but visible run records sum to **~951** billed min
(~3.4×gap). I cannot reconcile the delta from run data with this token — it may
reflect a different accounting window, runner-provisioning overhead not shown in
job wall-time, or other repos folded into the figure. **This does not change the
ranking of fixes below**: macOS legs + the failed-build retry storm dominate the
measured spend, and both scale with whatever the true number is.

## Workflow inventory

| Workflow | Triggers | Jobs / runners | Guards |
|---|---|---|---|
| build-release.yml | `workflow_dispatch`, `workflow_call` | build-linux (ubuntu), **build-macos (macos-latest, ×10)**, release (ubuntu), notify-on-failure (ubuntu) | no `timeout-minutes`, no `concurrency` |
| sync-upstream.yml | cron `0 1,9,17 * * *` (every 8h) + dispatch | check-new-release (ubuntu, `fetch-depth: 0`), trigger-build (ubuntu, conditional) | none |
| sync-tool-fix-pr.yml | cron `0 1,9,17 * * *` | 1× ubuntu | none |
| sync-vim-pr.yml | cron `0 1,9,17 * * *` | 1× ubuntu | none |
| check-sunset.yml | cron monthly + dispatch | 1× ubuntu | none |

There are **no `push`/`pull_request` triggers**, so path filters are **not
applicable** (nothing to gate on file changes). Everything is cron- or
dispatch-driven.

---

# P0 — do these first

## P0-1 — Failed-build retry storm (no circuit breaker) — **[measured] ~360 billed min/window (~half of all build spend), ~36 billed min/day ongoing**

**Root cause (confirmed):** `sync-upstream.yml` runs every 8h, reads
`anomalyco/opencode releases/latest`, and if no `v<version>-patched` release
exists it triggers `build-release`. Since **v1.17.18-patched (Jul 10)**, every
newer upstream release (**v1.17.19, v1.17.20, v1.18.1, v1.18.2, v1.18.3**) fails
at **patch-apply (~15 s)** — the patches no longer apply cleanly. Open
`build-failure` issues **#20–#24** corroborate this.

Because a failed build creates **no release**, the *next* sync run (8h later)
again sees "no `v1.18.3-patched` release" and **re-triggers the identical doomed
build**. Confirmed: failures recur at exactly the cron times (01/09/17), all
`attempt=1`, fail-fast. Each failed build burns **macOS 1 min ×10 = 10 + linux 1
+ notify 1 = 12 billed min**, 3×/day, indefinitely, until a human updates the
patches. It also spams `build-failure` issues.

**Fix (zero coverage loss):** add a circuit breaker in `check-new-release`
before triggering — skip if a build for that exact version already failed. Cheap
signals already present: an open `Build failed for v<version>` issue, or a recent
failed `build-release` run for that version. Optionally add manual re-arm.

**Impact:** eliminates ~360 billed min this window and ~36 billed min/day
going forward (~$2.9/window in $ terms, but ~360 of your 3,000 included minutes).

## P0-2 — macOS leg is ×10 and rebuilds everything redundantly — **[measured] macOS = ~88% of a successful build's billed minutes (30 of 34)**

Both `build-linux` and `build-macos` run `bun run script/build.ts --all`, which
**cross-compiles all four targets (incl. darwin) on each runner**. The linux job
already produces the darwin binaries; the **macOS runner is only genuinely needed
for `codesign --sign -` (ad-hoc signing) and the arm64 smoke test.** So the ×10
macOS runner spends most of its time building linux+windows binaries it discards.

Measured successful build (run 29062607570): build-macos 142 s → billed **3 min
×10 = 30**, vs whole run's ~34 billed min.

**Fix (no coverage loss):** build all 4 targets once on ubuntu; a lightweight
macOS job downloads the darwin artifacts, `codesign`s them, runs the smoke test,
re-uploads. macOS job drops from a full `bun install`+build (~3 min) to
sign+test (~30–60 s) → billed ~30 → ~10. **[derived] ≈20 billed min saved per
successful build (~200/window at 10 successes).** Still macOS-signed and
smoke-tested — coverage identical.

## P0-3 — No `timeout-minutes` anywhere → default **360 min** — **[derived] tail-risk up to 3,600 billed min from a single hung macOS job**

Every job inherits GitHub's 360-minute default. A hung `bun install` or network
stall on macOS could bill **360 × 10 = 3,600** quota-minutes from one run — larger
than the entire monthly included allotment. Observed max run wall today is only
13 min, so this is insurance, not a current leak, but it's free.

**Fix:** add `timeout-minutes` to every job — e.g. **15** for build jobs, **5**
for sync/sunset jobs.

---

# P1 — high value, low effort

## P1-1 — Three sync workflows on the identical cron — **[measured] ~204 billed min/window combined; ~140 recoverable**

`sync-upstream`, `sync-tool-fix-pr`, `sync-vim-pr` all fire at `0 1,9,17`, each
spinning a **fresh ubuntu VM + `actions/checkout`** just to make 1–2 `gh` API
calls. That's 3× VM-startup + checkout overhead for work that shares nothing.

**Fix:** consolidate into **one** scheduled workflow with three steps (or a
small matrix sharing a single checkout). **[derived] ~204 → ~64 billed
min/window (~140 saved).** No loss of monitoring coverage.

## P1-2 — `sync-upstream` uses `fetch-depth: 0` but never reads git history — **[measured] ~51 billed min/window**

`check-new-release` only calls `gh api` / `gh release list`; it never touches the
cloned history, yet does a **full-history checkout**. This is why this sync bills
**2** min/run vs **1** for the others.

**Fix:** drop `fetch-depth: 0` (default shallow, or `persist-credentials`/no
checkout at all since only `gh` is used). **[derived] ~51 billed min/window
saved.**

## P1-3 — No `concurrency` / `cancel-in-progress` on build-release — **[derived]**

If sync double-triggers, or a manual dispatch overlaps a sync-triggered run, two
full macOS (×10) builds run to completion. Nothing cancels a superseded build.

**Fix:** add `concurrency: { group: build-${{ inputs.version }},
cancel-in-progress: true }` (or a queue guard) so redundant/superseded builds are
cancelled before the macOS leg burns minutes.

---

# P2 — worth considering

## P2-1 — Sync cadence every 8h is aggressive — **[assumption]**

Three checks/day against a fork that ships releases every few days. **Daily**
(`0 6 * * *`) cuts sync minutes ~3× and still detects upstream releases within
24h. Trade-off: up to ~24h extra release-detection latency. Combined with P1-1
consolidation, sync spend drops from ~204 → ~20 billed min/window.

## P2-2 — `notify-on-failure` + issue spam — **[measured] ~30 billed min/window**

Fires on every failed build creating/commenting issues (#12–#24). Mostly
**subsumed by P0-1** — fixing the retry storm removes the repeated failures that
drive this. Keep the notifier itself (useful), just stop the storm feeding it.

## P2-3 — Path filters — **NOT applicable**

No `push`/`pull_request` triggers exist, so there is nothing to path-filter. No
action; noted so it isn't re-investigated.

---

## Priority summary (recoverable billed min / window, measured or derived)

| Item | Est. saving/window | Type | Coverage impact |
|---|---:|---|---|
| P0-1 retry-storm circuit breaker | ~360 | measured | none |
| P0-2 build-once + macOS sign-only | ~200 | derived | none |
| P0-3 `timeout-minutes` | tail-risk (≤3,600/run) | derived | none |
| P1-1 consolidate sync workflows | ~140 | derived | none |
| P1-2 drop `fetch-depth: 0` | ~51 | measured | none |
| P1-3 build concurrency guard | variable | derived | none |
| P2-1 daily sync cadence | ~120 (with P1-1) | assumption | +≤24h latency |
| **Addressable (P0+P1)** | **~750 of ~951 measured (~79%)** | | **zero coverage loss** |

The two P0 items alone (retry storm + macOS restructure) address ~560 billed
min/window — the bulk of the waste — without touching platform coverage,
signing, or smoke tests.
