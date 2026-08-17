# Stellar OAuth Demo

Minimal SwiftUI validation host for the `StellarAuth` implementation in this repository.

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

The Gateway must register the public client `stellarplayer-ios-demo` with the exact
redirect URI `https://dev-auth-stellarplayer.2dland.cn/oauth/callback` before sign-in
can complete.

The domain must serve [`Server/apple-app-site-association`](Server/apple-app-site-association)
without a redirect at `/.well-known/apple-app-site-association` with an
`application/json` content type.
