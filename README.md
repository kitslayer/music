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
gh release download latest -p Music.ipa -D dist --clobber
xtool install dist/Music.ipa
```

Every push to `main` replaces the `latest` prerelease, so that command never
needs a run id. The build is also uploaded as a workflow artifact, but the
artifact API has returned 503 for hours at a time, which is why the release is
the documented path.

A free Apple developer certificate expires after 7 days, so re-running
`xtool install` is the weekly refresh.

## Layout

```
App/Core        Subsonic client, models, session, Keychain
App/Features    One directory per screen
```

`Music.xcodeproj` uses a file-system synchronized group, so new Swift files
under `App/` are picked up without editing the project file.
