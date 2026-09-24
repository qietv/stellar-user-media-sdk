# BDMVIOContext local patch

Source: https://github.com/TracyPlayer/BDMVIOContext

Base revision: `639c793ff0cac9a9e3601db49e5790b5ba18f321`.
`Sources/udfread` is unchanged from that revision; its copyright and LGPL notices are preserved
in the source files. The base revision has no separate root license file.

These sources are checked in so both SwiftPM and Xcode use the same fix without modifying their
dependency caches. They are internal targets of the SDK package, so a remote SDK dependency does
not require a local package override. KSPlayer remains pinned by the SDK. The upstream manifest
and example tests are omitted; regression tests live in the SDK suite.

## MPLS crash fix

The observed Xcode crash parsed `1234567912.txt` (17,024 bytes) as an MPLS playlist. The text
`1234` became a playlist offset of `825373492` (`0x31323334`), and the unchecked pointer read
at that offset raised `EXC_BAD_ACCESS` before the upstream assertion could run.

- Only non-hidden `.mpls` files from PLAYLIST are parsed, case-insensitively.
- MPLS metadata is read completely into owned storage, with cancellation, short-read/EOF checks,
  a 16 MiB allocation limit, and deterministic download cleanup.
- `MPLSParser.swift` validates the signature/version and bounds every section, item, angle,
  stream entry, stream attribute and mark before reading it. Invalid bytes throw instead of
  reaching pointer subscripts or assertions. Time and accumulated stream-size overflow are checked.
- Failed initialization closes the manager, close is idempotent, and UDF directory handles are
  released after enumeration.

The legacy pointer helpers remain for the separate DVD IFO parser; this patch does not claim
to harden that parser. The UDF C implementation and playlist-selection behavior are unchanged.

Run from `platforms/swift`:

```sh
GIT_LFS_SKIP_SMUDGE=1 swift test --filter 'MPLSSafetyTests|RemoteDiscAdapterTests'
```

When replacing this copy with an upstream release, retain these regression tests and verify that
the release includes equivalent filename, read-completion and nested-bounds checks.
