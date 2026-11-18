# Discord Takeover

An iOS proof-of-concept that logs a Discord session into the app through Discord's
own browser handoff flow.

The app runs a small local HTTP server on `127.0.0.1:6463`, opens
`https://discord.com/handoff?rpc=6463&key=<random>` in Safari, and receives the
one-time `handoffToken` that Discord's web app sends back. The token is exchanged at
`/api/v9/auth/handoff/exchange` for a session token, which is then shown in the app.

## How it works

1. Tap the round button. The app starts the local server, arms a Picture-in-Picture
   keep-alive (so iOS does not suspend it while Safari is in the foreground) and opens
   the handoff page.
2. Discord's web app navigates back to `http://127.0.0.1:6463/rpc?...` with a
   `BROWSER_HANDOFF` payload containing the token.
3. The app exchanges the token with the same `key` that was in the URL and shows the
   resulting user info / session token. The keep-alive is stopped immediately.
4. A short history of previous keys is kept so a handoff page opened before an app
   restart still exchanges successfully; repeated requests for the same token reuse the
   cached result instead of failing on a consumed token.

## Build

- Open `DiscordTakeover.xcodeproj` in Xcode 26+.
- Select your own development team and change the bundle identifier if needed.
- Run on a physical device. Picture-in-Picture is required for background execution; the
  simulator and devices with PiP disabled cannot complete the background handoff.
- The `audio` background mode and the `discord-handoff` URL scheme are already declared
  in `Info.plist`.

No signing identity, team ID or provisioning profile is included in the repository.

## Files

| File | Purpose |
| --- | --- |
| `HandoffServer.swift` | Local HTTP server, token exchange, key history |
| `HandoffView.swift` | SwiftUI screen: round button, status, result, logs |
| `PiPKeepAlive.swift` | Picture-in-Picture keep-alive while Safari is in front |

## Legal

For educational purposes and for accounts you are authorized to access. Use it only on
your own device and your own Discord account.
