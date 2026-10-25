# Maintained Dependency Fork Policy

- Status: normative, 2026-10-24
- Decisions: [ADR 0005](adr/0005-libxev-fork.md) for libxev,
  [ADR 0006](adr/0006-dependency-forks.md) for lsquic and h1spec
- Scope: humans and agents changing dependency pins, downstream patches,
  compliance submodules, or the build/vendor graph

This page is the canonical rule for maintaining downstream forks of libxev,
lsquic, and h1spec. It replaces local patch overlays and the assumption that a
downstream fix must wait for an upstream release.

## Current state (2026-10-26, 2.1.6 patch line)

| Dependency | Upstream | Maintained fork | Mirror branch | Integration branch | Pinned commit |
| --- | --- | --- | --- | --- | --- |
| libxev | `mitchellh/libxev` | `farbenbuilds/libxev` | `main` | `uwz/zig-0.16` | `c49f6dfb83038c146232472c063e4b2681d098d8` |
| lsquic | `litespeedtech/lsquic` | `farbenbuilds/lsquic` | `master` | `uwz/main` | `85bd081c9103c077a7cc98271d09334d0f1043d4` |
| h1spec | `uNetworking/h1spec` | `farbenbuilds/h1spec` | `main` | `uwz/main` | `999ba9e8f318b1c0ebbff1278b98bc5833f1af18` |

- `build.zig.zon` pins the libxev and lsquic fork commits. All four dependency
  views must agree on URL, revision, Zig package hash, and Nix hash.
- `vendor/h1spec` is a git submodule. `.gitmodules` and the gitlink must both
  point at the maintained fork commit.
- `patches/` and `vendor/lsquic_overlay` are deleted. No build or CI step runs
  `patch` or Perl.
- `scripts/check_dependency_forks.sh` runs the libxev, lsquic, and h1spec
  provenance checks in lint and release gates.
- ADR 0001 is accepted for implementation in 2.2.0. The live listener remains
  capability-gated until the WebTransport compliance work lands; `SECURITY.md`
  keeps the current "not live" statement until then.
- XEV-003, XEV-004, and XEV-005 are merged into `uwz/zig-0.16` and pinned at
  `c49f6dfb83038c146232472c063e4b2681d098d8`. They repair the kqueue rearm
  state, duplicate completion queueing, nested-submit dispatch, pending-delete
  flush, and active-count accounting. The 2.1.6 scheduler keeps its
  second-boundary guard until a separate fork patch normalizes libxev timer
  timespecs. See [libxev_kqueue_findings.md](libxev_kqueue_findings.md).

## Mirror validation in CI

`scripts/dependency_mirrors.env` records the reviewed commit of every mirror
branch. Pull-request and `main` lint verify that the fork branch still equals
that record. This keeps a code PR green when upstream advances; it does not
hide a fork-only commit or a rewritten mirror. The lsquic mirror was
fast-forwarded to `413ca7c1acb443b0f9f7aa28611ca723c6738844` for 2.1.6; the
integration pin remains `85bd081c9103c077a7cc98271d09334d0f1043d4`.

Exact live equality is required at release and by the weekly
`Dependency Mirrors` workflow:

```sh
sh scripts/check_dependency_forks.sh --exact-mirrors
```

Both forms use `scripts/check_mirror_state.sh`. After a reviewed sync, update
the matching value in `scripts/dependency_mirrors.env` in the same change that
advances the fork mirror. Never update the record to match an unreviewed fork
head.

## Upstream relationship

Upstream repositories are fetch-only:

- Never push to `mitchellh/libxev`, `litespeedtech/lsquic`, or
  `uNetworking/h1spec`.
- Never open issues, pull requests, comments, or discussions there.
- Never submit a downstream patch upstream, even when it looks generally
  useful. The patch and its rationale stay in the fork ledger.
- Fetch upstream only to synchronize the read-only mirror and review
  compatible changes.

The maintained forks exist to keep downstream behavior reproducible. A private
or unrecorded fork is prohibited.

## Branch model

| Ref | Role | Mutation rules | Build or pin |
| --- | --- | --- | --- |
| Fork mirror branch | Exact read-only mirror of the upstream default branch. | Fast-forward only. No downstream commits, merges, or tags. Repairs use the documented mirror repair. | Never build or pin. |
| `uwz/zig-0.16` (libxev) | Downstream integration branch based on the newest upstream commit compatible with Zig 0.16.0. | Append-only from first push. Merge compatible upstream commits with `git merge --no-ff`; never force-push or rewrite history. | Pin a full 40-hex commit only. |
| `uwz/main` (lsquic, h1spec) | Downstream integration branch based on the newest upstream commit compatible with the project. | Append-only from first push. Merge compatible upstream commits with `git merge --no-ff`; never force-push or rewrite history. | Pin a full 40-hex commit only. |
| `uwz/zig-0.17` (future) | libxev integration branch for the next toolchain line. | Created during the Zig 0.17 upgrade. Do not merge 0.17-only upstream `main` into `uwz/zig-0.16`. | Pin a full 40-hex commit only. |

All mirror and integration branches require protection. Only maintainers may
push to a mirror branch; fork write access is limited to build/vendor
maintainers. A mirror blocks deletion and non-fast-forward updates except the
recorded maintainer repair; an integration branch requires review and blocks
force-push and deletion.

Optional annotated tags may mark tested integration commits for humans. Tags
are never authoritative in `build.zig.zon` or `.gitmodules`; the full commit is
what CI, releases, and benchmark provenance record.

## Pinning rules

### Zig package dependencies

- Pin only a full 40-hex commit in `build.zig.zon`. A branch, tag, short SHA,
  or local path is not valid.
- Update all four manifest views in the same change:
  `build.zig.zon`, `build.zig.zon.json`, `build.zig.zon.nix`, and
  `build.zig.zon.txt`. Regeneration with `sh scripts/update_zon_files.sh` is
  not proof because it can skip when zon2nix or nix is absent.
- Record the fork commit, upstream base commit, Zig package hash, Nix hash,
  license, and ledger IDs in the update or release notes.
- Rebuild from an empty Zig and vendor cache so a stale artifact cannot hide a
  dependency problem.
- Never edit a fetched package under `zig-pkg` or any global cache.

### h1spec submodule

- `.gitmodules` must use `https://github.com/farbenbuilds/h1spec`.
- The gitlink recorded in the parent tree must be a full 40-hex commit.
- The checked-out submodule HEAD must match the gitlink.
- No workflow may apply a local patch to the submodule.

## Mirror synchronization

Run these commands in a fork clone where `origin` is the maintained fork and
`upstream` is the read-only upstream. Replace the branch names for the target
dependency.

```sh
git fetch origin main
git fetch upstream main
git switch main
git merge --ff-only upstream/main
git push origin main
git fetch origin main
test "$(git rev-parse origin/main)" = "$(git rev-parse upstream/main)"
```

For lsquic, replace `main` with `master` on both sides. Synchronize the mirror
at least weekly, before every integration pin, and within 24 hours of an
upstream security advisory or release. Update `scripts/dependency_mirrors.env`
in the same reviewed change.

A failed fast-forward means the mirror is no longer exact. Repair is sanctioned
only as a recorded incident: after fresh fetches, run
`git push --force-with-lease origin upstream/main:main` (or
`upstream/master:master` for lsquic), record the incident, confirm the remote
equality again, and confirm branch protection is active. That is the sole
permitted force-push.

Every sync is a security review:

1. Prove the fork mirror and upstream default branch resolve to the same
   commit.
2. Review the mirror-to-integration range for every downstream patch and
   conflict resolution.
3. Review upstream changes to build scripts, workflows, submodules, checked-in
   binaries, licenses, networking, TLS, memory ownership, and platform
   backends.
4. Route the review through build/vendor and the owning domain specialist.
   Verification owns the test and benchmark gates.
5. Backport a compatible security fix even when upstream has moved to a newer
   toolchain or release. A security fix is not deferred because the mirror head
   is unbuildable here.

## Integration synchronization

After migration, start from a clean fork clone and choose the newest upstream
commit that still supports the project. Use a scratch branch and a pull
request; never push directly to an integration branch.

```sh
git fetch origin main
git fetch upstream main
git fetch origin uwz/main
test "$(git rev-parse origin/main)" = "$(git rev-parse upstream/main)"
git log --oneline origin/main..origin/uwz/main
git switch --create sync/main-YYYYMMDD origin/uwz/main
git merge --no-ff <compatible-upstream-commit>
```

Resolve conflicts in favor of the patch ledger invariants, rebuild and test,
then push the scratch branch, open a PR to `uwz/main`, merge after gates, and
fetch the resulting integration commit. For libxev, use `uwz/zig-0.16` instead
of `uwz/main` and choose only commits compatible with Zig 0.16.0.

Integration sync runs before every dependency-changing release and within
7 days of a compatible upstream fix that touches the event loop, QUIC/HTTP3,
HTTP/1.1, or the toolchain. If the fix needs a new downstream patch, add a
ledger row and a `uwz` commit; do not fold it into an unrelated merge.

## Patch ledger

Every downstream change has a ledger row and a matching commit. The ledger is
the durable answer to why a fork diverges.

| ID | Fork | Area | Upstream reference | Invariant | Test evidence | Retirement criterion |
| --- | --- | --- | --- | --- | --- | --- |
| XEV-001 | libxev | Windows IOCP accept | [mitchellh/libxev#252](https://github.com/mitchellh/libxev/issues/252) | `AcceptEx` transfers ownership of the connected socket. Clear `internal_accept_socket` on success and error so the next re-arm allocates a fresh socket. | Native `windows-2025` runtime and AcceptEx re-arm regression. | Upstream or fork base contains an equivalent fix. |
| XEV-002 | libxev | Winsock error mapping | None (downstream) | Unmapped Winsock errors return a stable error instead of panicking. | Native `windows-2025` runtime suite. | Upstream error mapping covers every returned Winsock code. |
| XEV-003 | libxev | kqueue rearm state | [mitchellh/libxev#245](https://github.com/mitchellh/libxev/pull/245) | A completion reported by `submit()` and returning `.rearm` stays registered and active instead of becoming dead. | macOS `kqueue: cancel after a rearm of a completion reported at submit`; downstream 12/28 invalid-state starts before and 0/29 after. | Upstream or fork base contains the equivalent rearm state fix. |
| XEV-004 | libxev | kqueue duplicate queueing | None (downstream; related issues #169 and #122) | A level-triggered readiness event for a completion already in the completion queue is skipped before `perform()`. | macOS `kqueue: a still-readable completion is queued once across submits`; downstream signal-watcher shutdown regression. | Upstream or fork base de-duplicates level-triggered events inside `submit()`. |
| XEV-005 | libxev | kqueue dispatch accounting | None (downstream; related to #169, #122, and #224) | A completion is performed and called back at most once per dispatch, pending deletes flush before `no_wait` returns, and `EV_ERROR`/non-kqueue rearm keep the active count balanced. | Exact head `86d628a`: macOS arm64 65/65 tests in Debug and ReleaseSafe; downstream 647/647 Linux tests. | Upstream or fork base contains equivalent dispatch and accounting guards. |
| LSQ-001 | lsquic | QPACK header errors | None (downstream QPACK policy) | Positive header-callback results and ambiguous content lengths reset only the request stream with `H3_MESSAGE_ERROR`; resource shortages use `H3_REQUEST_REJECTED`. | `scripts/http3_compliance/run.sh` `oversized_qpack` and sibling request case. | Upstream lsquic provides equivalent stream-scoped handling. |
| LSQ-002 | lsquic | Generated version table | None (generated by `gen-verstrs.pl`) | The pinned tree contains `lsquic_versions_to_string.c`, so the build runs no Perl and carries no overlay. | `zig build lib` compiles the pinned tree. | Upstream ships the generated file or the build can generate it without Perl. |
| H1S-001 | h1spec | Deno connection cleanup | None (downstream test runner) | Each test connection is unreferenced when opened and closed when its test completes, so the runner exits without leaking sockets. | h1spec compliance job exits cleanly. | Upstream h1spec closes and unrefs completed connections itself. |

Patch commits use this format:

```text
uwz(<area>): <imperative summary>

Ledger: <ID>
Upstream: <issue or pull request URL, or "None (reason)">
Invariant: <behavior the patch guarantees>
Test evidence: <command or test that fails without the patch>
Retirement criterion: <condition that makes the patch unnecessary>
```

One commit carries one patch. Do not mix formatting, dependency refreshes, or
unrelated upstream merges into a `uwz` commit. A generated build input that is
not a patch gets its own ledger row and commit.

## Security and provenance review

Each mirror sync and integration merge is a supply-chain review:

- Confirm the mirror equality and inspect the exact commit range being merged.
- Inspect build scripts, workflows, submodules, binaries, license changes, and
  any change to networking, TLS, memory ownership, or platform backends.
- Require build/vendor and the owning domain specialist review for dependency
  changes. Verification confirms the gates and records the commands.
- Prefer a smaller reviewed range over a large periodic merge. Backport a
  compatible security fix even when newer upstream commits require a different
  toolchain or release.
- Record the review in the pull request: mirror range, integration range,
  findings, tests, and the resulting pin.
- Retain an archive or local bare mirror of every pinned integration commit,
  and prefer signed commits or annotated tags. These are evidence, not pin
  authority.

## CI and release provenance

- `scripts/check_libxev_fork.sh` verifies the libxev full commit, all four
  dependency views, remote reachability, integration-branch ancestry, and
  mirror equality.
- `scripts/check_lsquic_fork.sh` performs the same checks for lsquic, including
  the absence of `patches/` and `vendor/lsquic_overlay` from the package.
- `scripts/check_h1spec_fork.sh` verifies the fork URL, full gitlink, checked-out
  submodule, integration-branch ancestry, mirror equality, and absence of a
  local patch in the compliance workflow.
- `scripts/check_dependency_forks.sh` runs all three checks in lint and release
  gates. `--exact-mirrors` also requires the live upstream branch to match the
  reviewed record; the release workflow and the weekly `Dependency Mirrors`
  workflow use that form.
- Before release, resolve each pinned commit from a second machine and against
  the retained archive or local bare mirror. Release and benchmark provenance
  record the fork commits and their upstream bases; tags are never
  authoritative.
- The native Windows runtime job remains the gate for XEV-001 and XEV-002. The
  HTTP/3 compliance job remains the gate for LSQ-001 and the WebTransport work
  accepted by ADR 0001. The macOS arm64 and FreeBSD kqueue jobs run XEV-003
  through XEV-005; the 2.1.6 release recorded 65/65 macOS tests in Debug and
  ReleaseSafe on the exact XEV-005 tree.

## Migration record

### libxev (completed in 2.1.0)

- `uwz/zig-0.16` created at upstream `9ce8e8e6...` with XEV-001 and XEV-002.
- `build.zig.zon` pins `cbf01bc432a84cd91a99c1cb1031b46416d044c7`.
- The former overlay, audit patch, and overlay build step are deleted.
- `scripts/check_libxev_fork.sh` is the provenance gate.

### libxev kqueue hardening (completed in 2.1.6)

- `farbenbuilds/libxev` PR #1 merged with a merge commit at
  `c49f6dfb83038c146232472c063e4b2681d098d8`, based on
  `cbf01bc432a84cd91a99c1cb1031b46416d044c7`.
- XEV-003 and XEV-004 preserve a submit-reported rearm completion and deduplicate
  level-triggered completion queueing.
- XEV-005 guards nested submits in both dispatch loops, flushes pending
  `EV_DELETE` changes from `no_wait`, and balances `EV_ERROR`/non-kqueue rearm
  active counts.
- The exact XEV-005 tree passed 65/65 macOS arm64 kqueue tests in Debug and
  ReleaseSafe, 142/146 Linux tests (4 skipped), and the downstream suite at
  647/647 on Linux.
- `build.zig.zon` and all four dependency views pin
  `c49f6dfb83038c146232472c063e4b2681d098d8`.

### lsquic and h1spec (implemented for 2.2.0)

- `farbenbuilds/lsquic` `uwz/main` created at upstream v4.10.2
  `a9616720...` with LSQ-001 and LSQ-002; `build.zig.zon` pins
  `85bd081c9103c077a7cc98271d09334d0f1043d4`.
- `farbenbuilds/h1spec` `uwz/main` created at upstream `f0a5650a...` with
  H1S-001; `.gitmodules` and the gitlink pin
  `999ba9e8f318b1c0ebbff1278b98bc5833f1af18`.
- `patches/` and `vendor/lsquic_overlay` are deleted. `builds/vendor/lsquic.zig`
  imports the fork tree directly, and the h1spec workflow no longer applies a
  patch.
- ADR 0001 is accepted for implementation in 2.2.0. The live WebTransport path
  remains capability-gated until the compliance work lands.

## Rollback

- If a fork is unreachable or a pin fails, revert the dependency migration
  commit set. If a revert is not possible, restore the last known-good
  upstream pin, the former overlay/patch from the pre-migration commit or a
  retained archive, and the matching build and CI wiring. Update all dependency
  views and notices in the same change.
- After a release pins a fork, publish a new patch release rather than rewriting
  the pinned commit.
- If a `uwz` patch proves wrong, add a revert commit with the same ledger ID and
  a retirement note. Integration branches are append-only from first push.

## Prohibited actions

- Editing `zig-pkg`, a global package cache, or a fetched dependency in place.
- Pinning a branch, tag, short SHA, or local path for a maintained dependency.
- Building or pinning a fork mirror branch.
- Adding downstream commits to a mirror or rewriting it outside the documented
  repair.
- Carrying a private, undocumented fork or an unledgered patch.
- Pushing, opening issues or pull requests, commenting, or submitting patches
  to `mitchellh/libxev`, `litespeedtech/lsquic`, or `uNetworking/h1spec`.
- Force-pushing a mirror except the documented repair, or force-pushing or
  rewriting any `uwz/*` commit.
- Disabling branch protection, or bypassing provenance checks outside the
  documented mirror repair.
- Reintroducing `patches/`, `vendor/lsquic_overlay`, or a CI `patch` step for a
  maintained dependency.
- Weakening the fork provenance, Windows runtime, HTTP/3, or release gates to
  make a pin pass.

## References

- [ADR 0005](adr/0005-libxev-fork.md): libxev fork adoption.
- [ADR 0006](adr/0006-dependency-forks.md): lsquic and h1spec fork adoption.
- [ADR 0001](adr/0001-http3-datagram-and-webtransport.md): HTTP/3 datagrams
  and WebTransport activation.
- [CONTRIBUTE.md](../CONTRIBUTE.md): dependency-update workflow.
- [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md): licenses and
  downstream modifications.
- `build.zig.zon`, `.gitmodules`, `scripts/check_dependency_forks.sh`,
  `scripts/check_libxev_fork.sh`, `scripts/check_lsquic_fork.sh`, and
  `scripts/check_h1spec_fork.sh`.
