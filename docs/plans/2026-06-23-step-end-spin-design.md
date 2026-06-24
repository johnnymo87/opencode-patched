# Step-End 100% CPU Infinite-Loop — Repro + Profiling Design & Fork-vs-Upstream Recommendation

Date: 2026-06-23
Author: Worker 3 (swarm; coordinator ses_10959f45fffeA7tx7XQChIeZVP)
Status: DESIGN / INVESTIGATION PLAN ONLY (no fix implemented this round)
Upstream: anomalyco/opencode #29762 (OPEN), #32965 (dup auto-closed as "question", NOT fixed)
Deployed: opencode v1.17.7-patched.5 (base source read via `git -C ~/projects/opencode show v1.17.7:<path>`)

---

## 1. Symptom (recap, kept distinct from peers)

Main JS thread pins one core at ~98-100% indefinitely, **no further log output**, **no
disk/DB I/O**, onset **right after a model stream step / step-end**. Native gdb profiles
(upstream) show the main thread frozen at the **same fixed PC `0x0000000003b3faad`** across
all samples while every other thread is parked in `pthread_cond_timedwait`/`futex` → a pure
**userspace busy loop on the single JS thread**, not GC, not I/O, not resource exhaustion.
Intermittent; a clean boot often does not repro.

This is **distinct** from:
- Worker 1's ProjectCopy boot refresh cost (which *logs* its work and *completes*).
- Worker 2's event fan-out churn.

Do not conflate. The fingerprint here is **silence + single-core spin + fixed PC + zero I/O**.

---

## 2. Localized suspect(s)

### 2.1 Primary suspect — unbounded Myers diff in the step-end summary

Call chain (all on the single Bun/Effect JS thread):

1. Stream emits `step-finish`.
   - `packages/opencode/src/session/processor.ts:744` (and the v2 path
     `packages/core/src/session/runner/publish-llm-event.ts:376`) publish `SessionEvent.Step.Ended`.
2. `processor.ts:745` and `prompt.ts:1305` invoke
   `summary.summarize(...).pipe(Effect.ignore, Effect.forkIn(scope))`.
   - **`forkIn(scope)` does NOT move this off-thread.** Effect fibers are cooperatively
     scheduled on the one JS thread. A synchronous, non-yielding CPU loop inside the forked
     fiber blocks the entire event loop just the same — which is exactly the observed
     "TUI responsive-ish but nothing progresses, no logs" shape.
3. `packages/opencode/src/session/summary.ts:113` `summarize` → `computeDiff` →
   `summary.ts:98` `snapshot.diffFull(from, to)`, where `from` = first `step-start` part's
   snapshot, `to` = last `step-finish` part's snapshot.
4. `packages/opencode/src/snapshot/index.ts:545` `diffFull`:
   - runs `git diff --numstat`/`--name-status` between the two snapshot trees,
   - then for each changed file builds the patch text via the helper at
     **`snapshot/index.ts:705`**:
     ```ts
     const patch = (file, before, after) =>
       formatPatch(structuredPatch(file, file, before, after, "", "",
                                   { context: Number.MAX_SAFE_INTEGER }))
     ```

`structuredPatch` is jsdiff (npm `diff@8.0.2`, pinned in root `package.json`). Its core
Myers routine `Diff.prototype.diff` (`diff/libesm/diff/base.js`) is **O(N·D)** in time and
memory, where D is the edit distance:

- `base.js:34` `maxEditLength = newLen + oldLen` — the default ceiling is the **worst case**.
- `base.js:35-39` it *accepts* `options.maxEditLength` and `options.timeout` (default
  `Infinity`) — **opencode passes neither.**
- `base.js:131` main loop: `while (editLength <= maxEditLength && Date.now() <= abortAfterTimestamp)`.
- `base.js:157` `extractCommon` tight snake-extending `while` loop doing
  `this.equals(oldTokens[oldPos+1], newTokens[newPos+1])` — **per-line string comparison**;
  this is the hottest inner basic block.

For a **full-file modification** of a ~2 MB / ~12,500-line file (nearly every line differs),
D ≈ N+M, so the search explores ~O((N+M)²) diagonals, each storing path component arrays →
hundreds of millions of iterations and **~1 GB of path-array allocation** (matches #29762's
"RSS increases by ~1 GB"). It *does* terminate (bounded by `maxEditLength`), but for large N
it can take many minutes → indistinguishable from an infinite hang.

**Why the 2 MB number in the upstream repro matters:** `snapshot/index.ts:32`
`const limit = 2 * 1024 * 1024`. Files **larger** than 2 MB are excluded from the snapshot
index (`add()` builds the `large`/`block` sets), so they never reach `diffFull`. Hence the
reporter's "full-file diff in a file that's smaller than 2 MB" — the worst case is a file
**just under** the cutoff that is **fully rewritten**.

**Why fixed PC `0x...3b3faad` is consistent:** the dominant work is `extractCommon`'s
per-line `equals` → a string-compare primitive compiled to a small JIT/binary basic block;
a sampler repeatedly catches the same address. The offset (~62 MB) plausibly lands in the
Bun static binary `.text` (a WTF/JSC string-compare/interpreter routine) rather than the
anon-rwx JIT region — to be confirmed by the profiling plan (§4).

### 2.2 Secondary, NOT-yet-explained variant (the flat-RSS spin)

#32965's second capture is the important caveat: the spin began after a **read-only
`explore` subagent** stream step (grep/glob/read only, **no write/edit/apply_patch**) and
**RSS stayed flat at ~824 MB** for the whole hang.

With no file modifications, `git --numstat` between the two snapshots yields ~no rows →
`diffFull` makes ~no jsdiff calls → **§2.1 cannot explain this capture.** Flat RSS also
rules out the large O(N·D) path-array allocation. So either:
- (a) it is a **second, distinct busy loop** that merely shares the "right after a stream
  step" timing (candidates: streamed-response/message reconstruction such as
  `message-v2.ts toModelMessagesEffect`, an Effect scheduling/retry loop, or a watcher), or
- (b) a degenerate jsdiff call on **non-file** text (unlikely on this path).

**Honest conclusion:** §2.1 is the well-substantiated, deterministically reproducible root
cause behind #29762. The flat-RSS variant is real but **uncharacterized**; the highest-value
single artifact is a JS-level profile that maps the fixed PC and tells us whether the two
captures are the *same* loop or *two* bugs. The plan below is built to answer exactly that.

---

## 3. Repro plan

Three repro tiers, cheapest/most-deterministic first.

### R0 — Micro-repro (no model, no server, no git): proves the jsdiff spin directly
A tiny standalone script that imports `diff@8.0.2` and calls the *exact* production
expression on two ~2 MB strings that differ on (almost) every line:

```
formatPatch(structuredPatch("foo.json","foo.json", before, after, "", "",
                            { context: Number.MAX_SAFE_INTEGER }))
```
- `before` = 12,500-row JSON (as in the upstream `generate.py`).
- `after`  = the same shape regenerated with different random payloads (full-file change).
- Wrap in `performance.now()`; expect it to run for many seconds→minutes pinning one core.
- This is the **fastest deterministic signal** and the **regression harness** for any fix
  (compare wall-time / `maxEditLength` bound before vs after). It removes glm-5.2/model
  nondeterminism entirely.

### R1 — End-to-end deterministic (matches upstream #29762 steps)
1. Empty git repo containing the upstream `generate.py` (12,500 rows, indent=2, sort_keys).
2. Run it **once** to create the initial `foo.json` (establishes the `step-start` snapshot
   baseline; this file is < 2 MB so it is *in* the snapshot index).
3. Start opencode (against the patched serve or a scratch instance) and ask the agent to
   **re-run** `generate.py` via the bash tool. The rewrite changes ~every payload line →
   `to` snapshot differs from `from` by a **full-file modification** → `computeDiff` →
   `diffFull` → unbounded `structuredPatch` → spin at the next step-end.
   - The "modified" (not "added") second run is the pathological case; "added" (before="")
     is cheap because Myers finds the all-insert path in ~O(N).
4. Confirmation: process pins one core, logs go silent right after the `stream ... step N`
   line, no DB writes.

### R2 — The flat-RSS variant (best-effort, non-deterministic)
We cannot trigger this on demand. Reporters correlate it with **large existing sessions**
running **repeated read-only tool loops** in a **subagent** (glm-5.2 via zai). Plan:
- Build a soak harness that replays/loops an `explore` subagent over a large repo with many
  read-only grep/glob/read steps against a **large existing session** DB, with the JSC
  sampling profiler **armed from launch** (§4.2) and a 1 Hz `/proc/<pid>` RSS/stat sampler.
- If/when it spins, the always-on sampler already captured the hot JS frame — no need to
  attach to a live hang. This is the only realistic way to catch (b)-class loops.

### Read-only opportunistic capture
A live hung serve is **not currently available** (checked: serve pid 510161 is healthy at
~22% CPU; the only momentary 100% process was a TUI `attach`, state-`R` transiently, not a
sustained spin). The plan must NOT depend on a wild hang being present, but if one appears:
`gcore` it, read `/proc/<pid>/maps` to classify the fixed PC's region, and run the
post-mortem PC-classification in §4.3 — all read-only.

---

## 4. Profiling plan — mapping the native fixed PC to a JS frame

The upstream blocker is "the blocked event loop makes it hard to profile." The fix is to use
profilers that sample from a **separate thread** (so a busy main thread is still observable),
and to symbolize JIT frames.

### 4.1 JSC Sampling Profiler (preferred; separate sampling thread)
Bun runs JavaScriptCore. JSC's sampling profiler runs on its own thread and can sample a
busy main thread. Launch the repro (R0 in a `bun` process, or the serve) with:
```
JSC_useSamplingProfiler=1 JSC_samplingProfilerPath=/tmp/oc-spin JSC_alwaysGeneratePCToCodeOriginMap=1 \
  bun <repro>     # or: ... opencode serve ...
```
Then read the dumped hot-function table. Expectation: the dominant frame is jsdiff
`extractCommon`/`diff` (called from `structuredPatch` → `Snapshot.diffFull`). If instead the
top frame is in message reconstruction / scheduler, that identifies the §2.2 variant.

### 4.2 Bun inspector CPU profile (start-before-trigger)
`opencode serve` launched with `--inspect` (or `BUN_INSPECT`), connect a CPU profiler,
`Profiler.start` **before** running R1, trigger, capture. Must start the profile first
because once hung you cannot interact. Good for a flame graph of the synchronous call stack.

### 4.3 perf + JIT map (bridges the gdb-style native PC → JS)
For the exact gdb fingerprint, run under `perf record -g` with JSC jitdump enabled so
`perf` can symbolize JIT frames:
```
JSC_jitDumpDir=/tmp/jit JSC_dumpJITMemoryPath=... perf record -g -p <pid> -- sleep 20
perf inject --jit -i perf.data -o perf.jit.data ; perf report -i perf.jit.data
```
Then cross-check: does the symbolized hot frame correspond to PC `0x...3b3faad` seen in gdb?
Also classify the PC by region from `/proc/<pid>/maps`:
- in Bun binary `.text` → a C++/WTF/JSC primitive (e.g. string `equals`) called in the loop
  (consistent with jsdiff `extractCommon`),
- in anon `rwx` JIT region → JIT'd JS body of the loop.

### 4.4 Cheap corroboration without any profiler
Temporarily (in a scratch build, not the deployed patch) wrap the §2.1 `patch()` helper with
a synchronous `console.error` + `performance.now()` guard, or pass
`{ timeout: 250 }` to `structuredPatch` and log when it aborts. If the spin disappears /
the abort fires on R1, §2.1 is confirmed as the #29762 root cause. (Investigation aid only;
not the shipped fix.)

**Deliverable artifacts to attach upstream:** the JSC sampling-profiler hot-function table +
the perf-jit flame graph + the R0 micro-repro — i.e. the native-PC→JS mapping the maintainers
explicitly asked daveBifo for.

---

## 5. Fork-fix vs upstream — recommendation

**Recommendation: do BOTH, lead with a small fork-fix for the proven §2.1 path; in parallel
contribute the repro + JS-level profile to upstream #29762; do NOT fork-fix the §2.2
flat-RSS variant until the profiler localizes it.**

### Why fork-fix §2.1 now (evidence)
- **Single, isolated call site.** The defect is one expression at `snapshot/index.ts:705`
  with no `maxEditLength`/`timeout`. Low blast radius.
- **The guard already exists in the dependency.** jsdiff 8.0.2 honors `maxEditLength` and
  `timeout` (`base.js:35-39,121,131`). The fix is an options change, not new algorithm work.
- **Backward-compatible degradation.** `FileDiff.patch` is already `Schema.optional`
  (`snapshot/index.ts:23` comment confirms legacy rows omit it). So a line-count/size guard
  that **skips patch text** for huge full-file changes (keeping `additions`/`deletions` from
  `--numstat`, which we already have) is safe and invisible to consumers.
- **Real wedge on our box, poor upstream cadence.** #29762 has been OPEN since 1.15.11, still
  reproduces at 1.17.8, and the corroborating dup #32965 was **auto-closed by a bot as a
  "question"** (not fixed). Waiting on upstream is not a viable mitigation.
- **Fits the existing patch-set.** The repo already carries targeted `.patch` files
  (`project-copy-debounce.patch`, `retry-cap.patch`, …); none touch snapshot/summary today
  (verified), so there is no overlap/conflict.

Two equivalent fork-fix shapes (decision for implementation round, not this round):
- (A) **Bound the algorithm:** pass `{ maxEditLength, timeout }` to `structuredPatch`; on
  abort, emit a `FileDiff` with counts but `patch: ""` (or a "diff too large" marker).
- (B) **Size/line guard before diffing:** if `before.length + after.length` (or changed-line
  count from numstat) exceeds a threshold, skip `structuredPatch` and emit counts-only.
  (B) is the most predictable; (A) is the most general. They compose.

### Why also contribute upstream (evidence)
- The **native-PC→JS mapping** and the **R0 micro-repro** are artifacts upstream explicitly
  lacks and asked for; contributing them is high-leverage for the whole community and raises
  the odds of a real upstream fix we can later drop our patch for.
- The **§2.2 flat-RSS variant is unexplained.** Shipping only the §2.1 fix may leave a second
  spin live on our box. We must not blindly fork-fix a loop we have not localized.

### What to escalate to the coordinator / human
1. **Approve carrying a fork patch** for §2.1 (vs. upstream-only)? (Recommended: yes, shape
   (A)+(B).)
2. **Do we invest in the R2 soak harness now**, or wait for the next wild occurrence with the
   JSC sampler armed? (Cost vs. urgency tradeoff.)
3. **Threshold/policy choice** for the guard (max edit length, max changed lines, or byte
   size, and what placeholder to show in the UI for an omitted patch).

---

## 6. Suspect file/line index (for the implementation round)

| What | Location |
|------|----------|
| 2 MB snapshot-index cutoff | `packages/opencode/src/snapshot/index.ts:32` |
| **Unbounded `structuredPatch` (root cause)** | `packages/opencode/src/snapshot/index.ts:705` (inside `diffFull`, def at `:545`) |
| `computeDiff` (from/to snapshot selection) | `packages/opencode/src/session/summary.ts:90-99` |
| `summarize` → `computeDiff` | `packages/opencode/src/session/summary.ts:101-127` |
| step-end → `summarize` (forked, same thread) | `packages/opencode/src/session/processor.ts:744-749`; `packages/opencode/src/session/prompt.ts:1305` |
| step-finish event (v2 path) | `packages/core/src/session/runner/publish-llm-event.ts:376-385` |
| jsdiff Myers core + bounds | `diff@8.0.2/libesm/diff/base.js:34-39,121,131,157` |
| jsdiff version pin | root `package.json` (`"diff": "8.0.2"`) |
