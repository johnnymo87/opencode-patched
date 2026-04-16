# Skill: darwin-signing

Use when editing `.github/workflows/build-release.yml`, bumping Bun, or debugging `Killed: 9` / SIGKILL reports for the darwin binaries.

## Why the CI workflow signs Mach-O binaries explicitly

Apple Silicon (Sequoia 15.4+) SIGKILLs any Mach-O binary whose code signature is missing, truncated, or malformed. The failure mode end users see is:

```
$ opencode
Killed: 9
```

`codesign -dv` reports `code object is not signed at all`, and `codesign --force --sign -` fails with `invalid or unsupported format for signature` — the Mach-O is corrupt, not merely unsigned.

**The GitHub macOS runner does not enforce this.** Unsigned or malformed binaries still run there, so CI smoke tests pass even when end-user Macs will refuse the binary. Do not trust "CI green" as proof the darwin asset works.

## The Bun 1.3.12 trap

Bun 1.3.12 (`bun build --compile --target=bun-darwin-*`) shipped with a regression in `src/macho.zig` where `LC_CODE_SIGNATURE.datasize` is smaller than the `SuperBlob` the internal signer actually stamps. The result is a truncated signature that macOS rejects and `codesign` cannot repair.

**Fix merged upstream:** [oven-sh/bun#29272](https://github.com/oven-sh/bun/pull/29272). Not in a release as of 2026-04-16.

**Our workaround:** set `BUN_NO_CODESIGN_MACHO_BINARY=1` during `bun build`, so Bun writes no signature slot at all. Then sign ourselves with `codesign --force --sign -` on the macOS runner. This produces a clean ad-hoc signature macOS accepts.

## Workflow invariants

`.github/workflows/build-release.yml` must maintain all of:

1. `build-macos` runs on `macos-latest` (not cross-compiled from Linux — Linux has no `codesign`).
2. `BUN_NO_CODESIGN_MACHO_BINARY: "1"` is set in the `env:` of the "Build CLI" step for as long as `bun-version: latest` resolves to a version with the #29120 regression unfixed.
3. An explicit `codesign --force --sign - <bin>` step runs after build, before zip, for both `opencode-darwin-arm64` and `opencode-darwin-x64`.
4. A smoke test runs the signed arm64 binary (`bin/opencode --version`). This is the only CI signal that would actually catch a signing regression — the smoke test that runs pre-sign does not.
5. `zip -r` is used for the archive (Info-ZIP preserves the Mach-O signature, which lives inside the file, not in xattrs).

## When to remove `BUN_NO_CODESIGN_MACHO_BINARY`

Drop the env var once `setup-bun` with `bun-version: latest` resolves to a Bun version containing [#29272](https://github.com/oven-sh/bun/pull/29272). Keep the explicit `codesign` step even after that — it is cheap defense in depth, and older Bun versions can sneak back in via pinning.

To verify: in a test workflow, comment out `BUN_NO_CODESIGN_MACHO_BINARY`, run the build, and check that the smoke test on the signed arm64 binary still passes. If `codesign` step still emits `invalid or unsupported format for signature`, Bun is still broken — restore the env var.

## Related files

- `.github/workflows/build-release.yml` — the workflow described above
- Workstation consumer: `johnnymo87/workstation/users/dev/home.base.nix` (`opencode-platforms`) — pins release asset hashes. A re-release invalidates these; bump them in a workstation PR.
