# Stellar OAuth Demo

SwiftUI validation host for Stellar OAuth, SMB library scanning, and PosterWall.

The **Scan** tab performs a resumable SMB full scan, displays the current file and
committed-page counters, and supports pause/resume from the latest SQLite checkpoint.
The checkpoint remains compact while `scan_frontier` and `scan_seen` durably track
unfinished pages and replay-safe identities in `library.sqlite`.
After enumeration it resolves video paths and artwork through the development media
service only:

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

The **Library** tab reads the materialized local library and presents one poster per
logical movie or series. API calls never use a production media-service origin. Artwork
images use the HTTPS variant URL returned by the development service. Localized metadata,
the selected poster, and scan-queue completion are committed together in `library.sqlite`;
the demo no longer rewrites a full `poster_metadata.json` file for every matched item.
The same transaction incrementally updates the affected search document, avoiding an
all-library search-index rebuild at the end of every scan.

The demo pre-fills the supplied test SMB host, share, and username. Enter the test
password in the app; it remains in memory and is not written to SQLite or preferences.

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
