# libxev Fork Policy

- Status: normative, 2026-10-24
- Decision: [ADR 0005](adr/0005-libxev-fork.md)
- Scope: humans, build/vendor agents, transport/runtime agents, and release
  reviewers working on the libxev dependency, its Windows IOCP patch, or the
  event-loop build graph.

This page is the canonical rule for maintaining libxev. It replaces ad hoc
fork decisions and the assumption that a downstream fix can only wait for an
upstream release.

## Current state (2026-10-24, 2.1.0)

- `build.zig.zon` pins <https://github.com/farbenbuilds/libxev> at the full
  commit `cbf01bc432a84cd91a99c1cb1031b46416d044c7` on `uwz/zig-0.16`. The
  branch is based on upstream `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` and
  carries XEV-001 and XEV-002 as ledgered commits.
- The Windows IOCP `AcceptEx` ownership fix lives in the fork. The former
  `patches/libxev_iocp_accept_socket.patch` and
  `vendor/libxev_overlay` are deleted; `builds/targets/native.zig` imports the
  dependency's `xev` module directly.
- `scripts/check_libxev_fork.sh` verifies the full 40-hex commit, the URL,
  revision, Zig package hash, and Nix hash across all four dependency views,
  and resolves the commit from the fork. `scripts/check_vendor_overlay.sh`
  checks only the lsquic overlay.
- The maintained downstream fork's default branch `main` is an exact mirror of
  upstream `main` at
  `451a2bc03644c2b70fb28a808313d12989bfa8e3` ("update to Zig 0.17").
- The project remains on Zig 0.16.0. Upstream `main` is not compatible with
  this project's Zig 0.16.0 build, although upstream manifest metadata still
  declares a 0.16.0 minimum. The fork's `main` is therefore a mirror only and
  must never be pinned.
- Upstream issue <https://github.com/mitchellh/libxev/issues/252> (IOCP accept
  reuses a connected socket) is still open. XEV-001 retirement therefore
  follows this project's integration branch, not an upstream release schedule.
- The native Windows runtime job and the XEV-001 re-arm regression are the
  remaining behavioral gate for this pin; they run in CI, not on the Linux
  release host.

## Upstream relationship

`farbenbuilds/libxev` maintains the downstream revision µWebZockets builds.
Upstream `mitchellh/libxev` is fetch-only:

- Never push to `mitchellh/libxev`.
- Never open issues, pull requests, comments, or discussions there.
- Never submit a downstream patch upstream, even when the fix looks generally
  useful. The downstream patch and its rationale stay in the fork ledger.
- Fetch upstream `main` only to synchronize the read-only mirror and to review
  compatible changes.

This rule keeps one source of truth for downstream behavior and prevents a
split conversation about a patch that this project must carry regardless of
upstream timing.

## Branch model

| Ref | Role | Mutation rules | Build or pin |
| --- | --- | --- | --- |
| `main` | Exact read-only mirror of `mitchellh/libxev` `main`. | Fast-forward only. No downstream commits, merges, or tags. Repairs use the documented mirror repair. | Never build or pin. |
| `uwz/zig-0.16` | Downstream integration branch based on the newest upstream commit compatible with Zig 0.16.0. It carries auditable `uwz(<area>): ...` patch commits. | Append-only from first push. Merge compatible upstream commits with `git merge --no-ff`; never force-push or rewrite history. | Pin a full 40-hex commit only. |
| `uwz/zig-0.17` (future) | Integration branch for the next toolchain line. | Created during the Zig 0.17 upgrade. Do not merge 0.17-only upstream `main` into `uwz/zig-0.16`. | Pin a full 40-hex commit only. |

The integration branch was created at the validated `9ce8e8e6...` pin and now
carries XEV-001 and XEV-002. Later integration syncs may merge newer upstream commits that
still support Zig 0.16.0. A toolchain upgrade starts a new branch instead of
bending the old one.

Fork `main` and `uwz/zig-0.16` require branch protection. Only maintainers may
push to `main`, and fork write access is limited to the build/vendor
maintainers. `main` blocks deletion and non-fast-forward updates except the
recorded maintainer mirror-repair bypass; `uwz/zig-0.16` requires review and
blocks force-push and deletion. The mirror repair is the sole permitted bypass
and requires confirming protection is active again afterward. Protection is
enabled before the first pin.

Optional annotated tags may mark tested integration commits for humans. Tags
are never authoritative in `build.zig.zon`; the manifest records the commit,
and the commit hash is what CI, releases, and benchmark provenance record.

## Pinning rules

- Pin only a full 40-hex commit in `build.zig.zon`. A branch, tag, short SHA,
  or local path is not a valid libxev pin.
- Update all four manifest views in the same change:
  `build.zig.zon`, `build.zig.zon.json`, `build.zig.zon.nix`, and
  `build.zig.zon.txt`. A check must compare the libxev URL, revision, Zig
  hash, and Nix hash across all four. Regeneration with
  `sh scripts/update_zon_files.sh` is not proof because it can skip when
  zon2nix or nix is absent; `scripts/check_libxev_fork.sh` performs the
  comparison in `lint.yml`.
- Record the fork commit, its upstream base commit, the Zig package hash, the
  Nix hash, and the license in the update or release notes.
- Rebuild from an empty Zig and vendor cache so a stale artifact cannot hide a
  dependency problem.
- Never edit a fetched package under `zig-pkg` or any global cache.
- The pin is `farbenbuilds/libxev` commit
  `cbf01bc432a84cd91a99c1cb1031b46416d044c7`, based on
  `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`, with XEV-001 as its only
  downstream modification.

## Mirror synchronization

Run these commands in a fork clone where `origin` is
`farbenbuilds/libxev` and `upstream` is `mitchellh/libxev`:

```sh
git fetch origin main
git fetch upstream main
git switch main
git merge --ff-only upstream/main
git push origin main
git fetch origin main
test "$(git rev-parse origin/main)" = "$(git rev-parse upstream/main)"
```

Synchronize the mirror at least weekly, before every integration pin, and
within 24 hours of an upstream security advisory or release. A failed
fast-forward means `main` is no longer a mirror; stop and repair it before
touching the integration branch.

Mirror repair is sanctioned only as a recorded incident: after fresh
`git fetch origin main` and `git fetch upstream main`, run
`git push --force-with-lease origin upstream/main:main`, record the incident,
then `git fetch origin main`, confirm the `origin/main` equality, and confirm
`main` protection is active again. That is the sole permitted bypass.

Every sync is a security review, not a mechanical pull:

1. Prove `git rev-parse origin/main` equals `git rev-parse upstream/main`.
2. After migration, review `main..uwz/zig-0.16` for every downstream patch and
   conflict resolution.
3. Review upstream changes to build scripts, workflows, submodules, checked-in
   binaries, licenses, networking, TLS, memory ownership, and platform
   backends.
4. Route the review through build/vendor and transport/runtime. Verification
   owns the test and benchmark gates.
5. Backport a compatible security fix even when upstream `main` has already
   moved to a newer Zig release. A security fix is not deferred because the
   mirror head is unbuildable here.

## Integration synchronization (after migration only)

After migration, start from a clean fork clone and choose the newest upstream
commit that still supports the project's pinned Zig version:

```sh
git fetch origin main
git fetch upstream main
git fetch origin uwz/zig-0.16
test "$(git rev-parse origin/main)" = "$(git rev-parse upstream/main)"
git log --oneline origin/main..origin/uwz/zig-0.16
git switch --create sync/zig-0.16-YYYYMMDD origin/uwz/zig-0.16
git merge --no-ff <compatible-upstream-commit>
```

Resolve conflicts in favor of the patch ledger invariants, then rebuild and
test. Use `--no-ff` so each upstream merge remains visible in history. Never
force-push or rewrite history; the branch is append-only from first push.

Push the tested result and pin the merged integration commit:

```sh
git push origin sync/zig-0.16-YYYYMMDD
# Open a PR to uwz/zig-0.16, run the gates, and merge it.
git fetch origin uwz/zig-0.16
git rev-parse origin/uwz/zig-0.16
```

Integration changes always go through the scratch branch and pull request;
there is no direct-push path to `uwz/zig-0.16`. Do not leave a tested local
commit unpushed. Create or update the archive or local bare mirror for every
new pinned integration commit.

Integration sync runs before every libxev-changing release and within 7 days
of a compatible upstream fix that touches the event loop, IOCP, or Zig
compatibility. If the fix needs a new downstream patch, add a ledger row and a
`uwz` commit; do not fold it into an unrelated merge.

## Patch ledger

Every downstream libxev change has a ledger row and a matching commit. The
ledger is the durable answer to why the fork diverges.

| ID | Area | Upstream reference | Invariant | Test evidence | Retirement criterion | Current home |
| --- | --- | --- | --- | --- | --- | --- |
| XEV-001 | Windows IOCP accept | [mitchellh/libxev#252](https://github.com/mitchellh/libxev/issues/252) | `AcceptEx` transfers ownership of the connected socket. Clear `internal_accept_socket` on both success and error so the next re-arm allocates a fresh socket and never calls `AcceptEx` on a connected one. | The fork commit `cbf01bc432a84cd91a99c1cb1031b46416d044c7` carries the change. The native `windows-2025` runtime job and the AcceptEx re-arm regression are the behavioral gate; the Linux release host can only run the cross-target compile gate. | The integration base contains an equivalent upstream fix, or the patch is no longer needed. Remove it with a follow-up revert commit and record the retirement in this ledger. | `farbenbuilds/libxev` commit `cbf01bc432a84cd91a99c1cb1031b46416d044c7` on `uwz/zig-0.16`. |
| XEV-002 | Windows Winsock error mapping | None; observed in the native Windows runtime job | Winsock codes are not a subset of `Win32Error`. Map known codes and return `error.Unexpected` for the rest instead of constructing an invalid enum. | The fork commit `cbf01bc432a84cd91a99c1cb1031b46416d044c7` carries the change. The native `windows-2025` runtime suite is the behavioral gate. | Upstream maps unknown Winsock codes without trapping. | `farbenbuilds/libxev` commit `cbf01bc432a84cd91a99c1cb1031b46416d044c7` on `uwz/zig-0.16`. |

Patch commits use this format:

```text
uwz(<area>): <imperative summary>

Ledger: XEV-00N
Upstream: <issue or pull request URL>
Invariant: <behavior the patch guarantees>
Test evidence: <command or test that fails without the patch>
Retirement criterion: <condition that makes the patch unnecessary>
```

One commit carries one patch. Do not mix formatting, dependency refreshes, or
unrelated upstream merges into a `uwz` commit.

## Security and provenance review

Each mirror sync and integration merge is a supply-chain review:

- Confirm the mirror equality and inspect the exact commit range being merged.
- Inspect build scripts, workflows, submodules, binaries, license changes, and
  any change to networking, TLS, memory ownership, or platform backends.
- Require build/vendor and transport/runtime review for libxev changes.
  Verification confirms the gates and records the commands and outcomes.
- Prefer a smaller reviewed range over a large periodic merge. If a compatible
  upstream security fix lands after a release, review and backport it on
  `uwz/zig-0.16` even when newer upstream commits require a different Zig
  version.
- Record the review in the pull request: mirror range, integration range,
  findings, tests, and the resulting pin.
- Retain an archive or local bare mirror of every pinned integration commit,
  and prefer signed commits or annotated tags. These are evidence, not pin
  authority.

A private or unrecorded fork is prohibited. Any divergence from upstream must
be reachable through the fork, a ledger row, and a `uwz` commit.

## CI and release provenance

The pin is migrated; CI enforces the following:

- The manifest pins a full 40-hex fork commit; CI verifies the libxev URL,
  revision, Zig hash, and Nix hash across all four manifest views. Lint adds
  this comparison because regeneration alone can skip when zon2nix or nix is
  absent.
- `scripts/check_libxev_fork.sh` resolves the exact commit at
  `farbenbuilds/libxev`, checks branch ancestry, and rejects a branch, tag, or
  short SHA. `scripts/check_vendor_overlay.sh` now covers only lsquic.
- Lint also runs the stale-phrase grep gate for current-state claims that the
  migration must remove.
- A pre-release check resolves the pinned fork commit from a second machine
  and against the retained archive or local bare mirror. Release and benchmark
  provenance record the fork commit and its upstream base; tags are never
  authoritative.
- The Windows runtime job remains the gate for XEV-001 and for the native
  IOCP path.

## Migration record (completed in 2.1.0)

The 2.1.0 release performed the migration. The checklist remains as the audit
record for the sequence and for any future integration branch.

1. [x] Synchronized the fork mirror and proved
   `test "$(git rev-parse origin/main)" = "$(git rev-parse upstream/main)"`.
2. [x] Created `uwz/zig-0.16` at
   `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`, pushed it, and enabled branch
   protection before the first pin.
3. [x] Applied the AcceptEx ownership change as the first
   `uwz(win-iocp): ...` commit with ledger ID XEV-001. The native Windows
   regression remains the CI behavioral gate.
4. [x] Pushed the tested integration commit
   `cbf01bc432a84cd91a99c1cb1031b46416d044c7`. It is not a local-only commit.
5. [x] Removed the overlay injection from `builds/targets/native.zig`, deleted
   `vendor/libxev_overlay` and the audit patch, and removed the overlay entry
   from `build.zig.zon` `.paths`.
6. [x] Updated `build.zig.zon` to the full 40-hex integration commit,
   regenerated all four manifest views, and added
   `scripts/check_libxev_fork.sh` to compare the URL, revision, Zig hash, and
   Nix hash.
7. [x] Added the `CHANGELOG.md` entry and updated `THIRD_PARTY_NOTICES.md`,
   `docs/roadmap.md`, the CI provenance section, and ADR 0004.
8. [x] Swept the current-state assertions in the files listed by the previous
   checklist revision.
9. [x] Updated ADR 0005's `Release` field to 2.1.0.
10. [x] Added the stale-phrase grep gate to lint, scoped to the migration
    files. It rejects phrases that describe the pre-migration upstream pin,
    the overlay as authoritative, a missing integration branch, or the fork as
    a future state. The gate's phrase list lives in
    `scripts/check_libxev_fork.sh`.
11. [ ] Archive or local bare mirror for the new integration commit, plus
    resolution of the pinned commit from a second machine. Carried to the
    2.2.0 release-engineering checklist because it is release infrastructure,
    not library behavior.
12. [ ] Native Windows runtime job. It runs in CI; the Linux release host
    performed the cross-target compile gate and the Debug, ReleaseSafe,
    sanitizer, package-consumer, Nix, format, docs, release, and lint gates.

## Rollback

- If the fork is unreachable or a pin fails, revert the migration commit set.
  If a revert is not possible, restore the last known-good upstream pin and
  the fork pin history from the retained archive. Never substitute a branch,
  tag, or the fork mirror `main`.
- After a release pins the migration, publish a new patch release rather than
  rewriting the pinned commit.
- If a `uwz` patch proves wrong, add a revert commit with the same ledger ID
  and a retirement note. The integration branch is append-only from first
  push.

## Prohibited actions

- Editing `zig-pkg`, a global package cache, or a fetched dependency in place.
- Pinning a branch, tag, short SHA, or local path for libxev.
- Building or pinning the fork mirror `main`.
- Adding downstream commits to `main` or rewriting the mirror outside the
  documented repair.
- Carrying a private, undocumented fork or an unledgered patch.
- Pushing, opening issues or pull requests, commenting, or submitting patches
  to `mitchellh/libxev`.
- Force-pushing `main` except the documented mirror repair, or force-pushing
  or rewriting any `uwz/*` commit.
- Disabling branch protection, or bypassing the provenance checks outside the
  documented mirror repair.
- Merging a Zig 0.17-only upstream `main` into `uwz/zig-0.16`.
- Weakening the overlay, provenance, Windows runtime, or release gates to make
  a pin pass.

## References

- [ADR 0005](adr/0005-libxev-fork.md): adoption of the maintained fork.
- [ADR 0004](adr/0004-windows-iocp-accept-and-queued-close.md): historical
  Windows IOCP overlay and queued-close decision.
- [CONTRIBUTE.md](../CONTRIBUTE.md): dependency-update workflow.
- [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md): license and
  modification disclosure.
- `build.zig.zon`, `scripts/check_libxev_fork.sh`, and
  `scripts/check_vendor_overlay.sh`.
