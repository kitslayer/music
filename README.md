# Music

A native SwiftUI music client for [Navidrome](https://www.navidrome.org/),
built for one iPhone and nothing else.

Written from scratch. There is no WebKit here: no web view, no CSS, no
JavaScript. Scrolling, gestures, swipe-back and the tab bar are the system's,
and playback is `AVQueuePlayer`, so gapless, background audio and the lock
screen work the way they do in any other iOS app.

Play counts, ratings and playlists live on the Navidrome server and are read and
written over the Subsonic API, so a desktop client stays in sync with this one
automatically -- neither app owns that state.

## Building

There is no Mac in this loop. GitHub Actions compiles on a macOS runner and
publishes an unsigned `.ipa`; it is signed and installed on-device with
[xtool](https://github.com/xtool-org/xtool):

```sh
gh run download <run-id> -n Music-unsigned-ipa -D dist
xtool install dist/Music-unsigned.ipa
```

A free Apple developer certificate expires after 7 days, so re-running
`xtool install` is the weekly refresh.

## Layout

```
App/Core        Subsonic client, models, session, Keychain
App/Features    One directory per screen
```

`Navidrome.xcodeproj` uses a file-system synchronized group, so new Swift files
under `App/` are picked up without editing the project file.
