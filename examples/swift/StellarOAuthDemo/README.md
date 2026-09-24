# Stellar OAuth Demo

SwiftUI validation host for Stellar OAuth, SMB library scanning, and PosterWall.

The **Scan** tab performs a resumable SMB full scan, displays the current file and
committed-page counters, and supports pause/resume from the latest SQLite checkpoint.
The checkpoint remains compact while `scan_frontier` and `scan_seen` durably track
unfinished pages and replay-safe identities in `library.sqlite`.
File admission covers Infuse-style video containers (including ASF, DVR-MS, ISO/IMG,
MXF, OGM/OGV, WM, and VWTV) plus STRM pointers. `BDMV`, `AVCHD`, `DVD`, and `VIDEO_TS`
directory structures are detected as one synthetic library item, so their internal
transport files are not indexed as separate videos.

After enumeration, each changed item first runs through the SDK filename parser and a
bounded local-metadata intake. The demo classifies same-directory NFO/JSON, artwork,
subtitle, and chapter sidecars; reads NFO/JSON documents up to 2 MiB; persists the
normalized result in `library.sqlite`; and gives compatible local metadata precedence
when building the match query. It then resolves online metadata and artwork through the
development media service:

```text
https://dev-api-st.2dland.cn/v1/media-info/
```

Metadata work is incremental and limited to four concurrent files. Requests are shared
by a single-flight cache, paced to ten requests per second, persisted in
`metadata_cache.sqlite`, and retried with `Retry-After`-aware exponential backoff. A
401/403 suspends further requests for that run, and a confirmed no-match is terminal
until the file changes and creates new scan work. The demo consumes that work in stable
200-item keyset pages joined directly with file and binding facts, so enrichment does not
materialize the full library snapshot in memory.

Technical probing remains optional because it opens and inspects media content. Enabling
**Inspect technical metadata (low priority)** schedules one `.probe` worker that uses the
same seekable `MediaSourceSession` range-read bridge as remote screenshots and commits
its stream/container summary atomically with queue completion.

The **Library** tab reads the materialized local library and presents one poster per
logical movie or series. API calls never use a production media-service origin. Artwork
images use the HTTPS variant URL returned by the development service. Localized metadata,
the selected poster, and scan-queue completion are committed together in `library.sqlite`;
the demo no longer rewrites a full `poster_metadata.json` file for every matched item.
The same transaction incrementally updates the affected search document, avoiding an
all-library search-index rebuild at the end of every scan.

The demo pre-fills the supplied test SMB host, share, and username. Enter the test
password in the app; it remains in memory and is not written to SQLite or preferences.

A paused or recovered scan locks its source connection and scope fields so that resuming cannot
silently use a different source. The Source card explains this state; both username and password
remain editable while paused. **Edit source** unlocks the form without deleting checkpoints or
queued metadata work. Automatic scans and automatic recovery selection wait while the connection
is being edited; manually starting the same source can resume its saved scan.

The password control keeps a single UIKit secure text field with `.password` semantics; it does
not masquerade as a one-time-code field. Progress updates preserve the responder, selection and
composition, and returning to the field preserves the draft. The keyboard's Done key dismisses
editing, and the scan page supports interactive keyboard dismissal while scrolling.

For first-install keyboard investigations, Debug builds emit `smb-password-focus-started`,
`smb-password-focus-returned`, `smb-password-keyboard-will-show` and
`smb-password-keyboard-visible` phases in the `Launch` log category. These contain timing and
focus diagnostics only, never password contents or length.
Compare them with `smb-scan-appeared` and `media-library-prepare-finished` to distinguish UI/input
startup from database preparation. Keyboard-visible time includes the system keyboard animation;
that notification may be absent with a hardware keyboard. Keyboard-service connection warnings
alone do not establish whether the main thread stalled.

After the focus call returns, a Debug-only main-queue probe runs every 100 ms until the keyboard
appears, focus ends, the app becomes inactive, or 15 seconds elapse. The
`smb-password-focus-observed` phase reports `main-queue-max-delay-seconds` and the probe count;
delays of at least 250 ms also emit `smb-password-main-queue-delayed`. A long keyboard wait with
many timely probes means the main queue remained responsive between those samples. A large
probe delay requires a call-stack capture to identify the blocking work. This is diagnostic
instrumentation, not a workaround for the keyboard-service delay. A timeout alone is inconclusive
because an already visible or hardware keyboard may not produce a new notification.

For interactive device testing, select the **StellarOAuthDemo-Device** scheme. It runs the same
Debug configuration without attaching LLDB. The normal **StellarOAuthDemo** scheme retains its
debugger for breakpoints and crash investigations. A physical-device cold-start A/B/A comparison
on 2026-09-09 measured the first password keyboard at 7.627 s with the debugger, 0.166 s without
it, then 12.006 s after re-enabling it. Each trial terminated the old process; these were not
repeat taps in an already running app. See [the keyboard investigation](KEYBOARD_INVESTIGATION.md)
for measurements and remaining limits.

To reproduce the first focus automatically, temporarily add `--smb-keyboard-probe` to a Debug
scheme's Run > Arguments. After normal startup preparation it opens Scan and requests focus
on the actual password field once the form is attached and the app is active (up to 10 seconds).
It does not type a password or start a scan. Remove the argument to return to normal navigation.
Neither shared scheme enables this argument by default. Keep iPhone Mirroring and hardware
keyboards disconnected when measuring the on-device software keyboard; focus-return timing
without a keyboard-visible event does not validate software-keyboard presentation.

## Media detail browsing

The Library opens a backdrop-led movie or series page with metadata, file versions,
stream details, and optical-disc title selection. Series expose season and episode
browsing, specials, library/all-episode filtering, and alternate orders when available.
Cast and crew link to biographies and filmographies; a work that is already in the
library resolves back to its local files. Search and media-type/year sorting are
available on the poster wall.

Read [the API assessment](DETAILS_API_ASSESSMENT.md) for verified development-service
behavior and remaining Infuse gaps. In particular, filmographies are capped at 40
items; ratings, trailers, and automatic collections are not exposed by this API.
Credits and the order menu may return 503. Each section offers its own retry, and a
verified cached aired order can still provide episode details when other orders fail.

Run the metadata contract tests from this directory:

```sh
GIT_LFS_SKIP_SMUDGE=1 swift test
```

The tests compile the app's real DTOs and client, inject a URL protocol, and create
isolated SQLite caches. They do not sign in, scan SMB, or call live metadata endpoints.
For Xcode builds, run `xcodebuild` from this demo directory: KSPlayer's upstream
manifest detects sibling FFmpegKit checkouts relative to the current working directory.
`GIT_LFS_SKIP_SMUDGE=1` avoids fetching the upstream missing dSYMs LFS object.

## Validation status

Physical-device acceptance passed on 2026-08-18 using this signed project and the
registered claimed-HTTPS callback. The run covered sign-in, Keychain session restore,
profile and access-token refresh, account switching, and sign-out. It completed without
biometric, device-passcode, Keychain-confirmation, or runtime-permission prompts, and
without displaying or logging OAuth token values.

## Signing setup

1. Open `StellarOAuthDemo.xcodeproj`.
2. Select the `StellarOAuthDemo` target and open **Signing & Capabilities**.
3. Choose the `Lenghu Technology (Wuhan) Co., Ltd.` team (`KR72GJ2FX7`).
4. Keep the bundle identifier as `cn.2dland.stellarplayer.oauthdemo`.
5. Confirm that **Associated Domains** contains
   `webcredentials:dev-auth-stellarplayer.2dland.cn`. The HTTPS OAuth callback
   is deliberately not registered as an `applinks` universal link, because it
   must finish the active `ASWebAuthenticationSession` instead of opening the
   app as an unrelated navigation. Debug builds use the same domain with
   `?mode=developer` so AASA changes can be tested without waiting for Apple’s
   CDN cache; enable **Settings > Developer > Associated Domains Development**
   on the test device. Release builds use the CDN-backed form without the query.
6. Run on iOS 17.4 or newer. A physical device is recommended for claimed HTTPS
   validation.

The project references `platforms/swift` as a local Swift package. It intentionally
does not display or log access and refresh token values.

The development Gateway has registered the public client `stellarplayer-ios-demo` with
the exact redirect URI `https://dev-auth-stellarplayer.2dland.cn/oauth/callback`. Other
deployments must register their own exact client and redirect policy before sign-in can
complete.

The domain must serve [`Server/apple-app-site-association`](Server/apple-app-site-association)
without a redirect at `/.well-known/apple-app-site-association` with an
`application/json` content type.
