# Third-Party Notices

µWebZockets includes or links the following third-party software:

| Component | Version or revision | License |
| --- | --- | --- |
| zslay | 0.2.1 | MIT |
| libxev | 9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf | MIT |
| BoringSSL | dd73e69a4e86fa178a4d19033c691e9b42cc1088 | ISC-style and component licenses |
| Fiat Crypto (via BoringSSL) | BoringSSL revision above | Apache-2.0 |
| lsquic | 4.10.0 | MIT and bundled component licenses |
| ls-qpack | 2.7.0 | MIT |
| ls-hpack | 38ceca78054d4175ba3f6411b1b83ac5c485e542 | MIT |
| libdeflate | 1.26 | MIT |
| zlib | 1.3.2 | zlib License |
| h1spec | f0a5650a20c575fbea0f7179a3a9cfa50f20ba6e | MIT |

The zslay, libxev, and zlib license texts are in the licenses directory, and
the C and C++ license texts are in `licenses/vendor`. Sources are selected by
immutable Zig package hashes or pinned release tags; the repository retains
only the `vendor/h1spec` compliance submodule. Releases publish the tagged
source only, with these license texts in-tree, so no binary archive copies
licenses separately.

The pre-generated files in `vendor/lsquic_overlay` apply
`patches/lsquic_h3_message_error.patch` to the pinned lsquic sources so positive
header-callback results remain `H3_MESSAGE_ERROR` stream errors as documented by
the pinned API. `scripts/check_vendor_overlay.sh` verifies the overlay against
the audit patch, and the build no longer runs `patch` or Perl. The h1spec CI job
applies `patches/h1spec_deno_cleanup.patch` only to close and unreference
completed test connections. The upstream sources remain unchanged.

`vendor/libxev_overlay/src/backend/iocp.zig` applies
`patches/libxev_iocp_accept_socket.patch` to the pinned libxev revision. The
overlay clears the IOCP accept socket after `AcceptEx` transfers it to the
completion, on both success and error paths, so a persistent accept loop cannot
reuse the connected socket. `scripts/check_vendor_overlay.sh` regenerates the
overlay from the pinned source and audit patch; the Zig package cache and the
upstream sources remain unchanged. The patch is carried only until the upstream
revision contains the fix, which is tracked in
[ADR 0004](docs/adr/0004-windows-iocp-accept-and-queued-close.md).
