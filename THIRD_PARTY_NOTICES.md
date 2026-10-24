# Third-Party Notices

µWebZockets includes or links the following third-party software:

| Component | Version or revision | License |
| --- | --- | --- |
| zslay | 0.2.1 | MIT |
| libxev | cbf01bc432a84cd91a99c1cb1031b46416d044c7 (farbenbuilds fork, base 9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf) | MIT |
| BoringSSL | 0.20261020.0 (d3bf4795ad5b79d646cddf2fec687da5b9b502db) | ISC-style and component licenses |
| Fiat Crypto (via BoringSSL) | BoringSSL revision above | Apache-2.0 |
| lsquic | 85bd081c9103c077a7cc98271d09334d0f1043d4 (farbenbuilds fork, base 4.10.2 a9616720af78b9aab895145c1792d5305c480ae8) | MIT and bundled component licenses |
| ls-qpack | 2.7.0 | MIT |
| ls-hpack | fda48e02491d865cce00612be8cc10c2622b8e55 | MIT |
| libdeflate | 1.26 | MIT |
| zlib | 1.3.2 | zlib License |
| h1spec | 999ba9e8f318b1c0ebbff1278b98bc5833f1af18 (farbenbuilds fork, base f0a5650a20c575fbea0f7179a3a9cfa50f20ba6e) | MIT |

The zslay, libxev, and zlib license texts are in the licenses directory, and
the C and C++ license texts are in `licenses/vendor`. Sources are selected by
immutable Zig package hashes or pinned release tags; the repository retains
only the `vendor/h1spec` compliance submodule. Releases publish the tagged
source only, with these license texts in-tree, so no binary archive copies
licenses separately.

The maintained downstream forks are
<https://github.com/farbenbuilds/libxev>,
<https://github.com/farbenbuilds/lsquic>, and
<https://github.com/farbenbuilds/h1spec>. `build.zig.zon` pins libxev at
`cbf01bc432a84cd91a99c1cb1031b46416d044c7` on `uwz/zig-0.16` and lsquic at
`85bd081c9103c077a7cc98271d09334d0f1043d4` on `uwz/main`; the h1spec
submodule points at `999ba9e8f318b1c0ebbff1278b98bc5833f1af18` on `uwz/main`.

- libxev carries XEV-001 and XEV-002, which clear the IOCP accept socket after
  `AcceptEx` transfers it to the completion and map the remaining Winsock
  errors.
- lsquic carries LSQ-001, which keeps positive header-callback results and
  ambiguous content lengths stream-scoped, and LSQ-002, which commits the
  generated version table so the build runs no Perl.
- h1spec carries H1S-001, which closes and unreferences completed test
  connections so the Deno runner exits cleanly.

No local `patches/` directory, `vendor/lsquic_overlay`, or CI `patch` step
remains. `scripts/check_dependency_forks.sh` verifies every pin, the dependency
views, remote reachability, and the fork mirrors. See
[ADR 0005](docs/adr/0005-libxev-fork.md),
[ADR 0006](docs/adr/0006-dependency-forks.md), and
[docs/dependency_forks.md](docs/dependency_forks.md).
