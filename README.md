# Kopi

A clipboard history for macOS, inspired by [Ditto](https://ditto-cp.sourceforge.io/) on Windows.
Kopi sits in the menu bar and keeps everything you copy. Press a shortcut anywhere, type a few
letters, and paste an older clip straight into the app you are using.

## Features

- **History of everything you copy**: plain and rich text, images, files from Finder and any other
  pasteboard data. Kopi stores every format the source app offered, so a pasted clip keeps its
  formatting.
- **Popup on a global shortcut** (⌃Q by default, like Ctrl+Q in Ditto), at the text cursor, the
  mouse pointer or the center of the screen. The app you were typing in stays in front and gets
  the paste.
- **Hold to paste, as in Ditto**: keep ⌃ down and tap Q again to move down the list, then let go of
  ⌃ to paste the selected clip. Holding ⌃Q for over a second and letting go pastes the newest clip.
  A quick ⌃Q just opens the popup; pressing ⌃Q again after letting go closes it. Can be turned off in
  Settings.
- **Search as you type.** Every word must match. Case-insensitive, Cyrillic and other scripts
  included.
- **Quick paste**: ⌘1 to ⌘9 paste the first nine clips, ⌘0 the tenth.
- **Paste as plain text** (⇧↩), or only copy a clip back to the clipboard (⌥↩).
- **Pinned clips** stay at the top and are never deleted automatically.
- **Groups** (folders) for clips you reuse. Switch between All, Pinned and your groups with ⇥.
- **A repeated copy is not stored twice**: the existing clip moves to the top instead.
- **Privacy**: copies that password managers mark as secret (the
  [nspasteboard.org](http://nspasteboard.org) markers) are never recorded, and you can exclude
  whole apps.
- **Limits**: maximum number of clips, delete after N days, maximum clip size (a bigger copy keeps
  only its text).
- Pause recording, launch at login, and history stored in SQLite.

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask vodorod-11/tap/kopi
```

Or download `Kopi-<version>.dmg` from [Releases](https://github.com/vodorod-11/kopi/releases), open
it and drag Kopi to Applications.

Kopi is not notarized by Apple yet, so macOS may refuse to open it the first time. Go to System
Settings › Privacy & Security and click **Open Anyway** next to Kopi. Then give it the two
permissions under [Permissions](#permissions).

## Keys in the popup

| Key | Action |
| --- | --- |
| hold ⌃, tap Q again | move down (wraps to the top); let go of ⌃ to paste |
| type | search |
| ↑ ↓, ⇞ ⇟, ⌘↑ ⌘↓ | move the selection |
| ↩ or double-click | paste into the previous app |
| ⇧↩ | paste as plain text |
| ⌥↩ | copy to the clipboard only |
| ⌘1 … ⌘9, ⌘0 | paste clip 1 to 10 |
| ⌘P | pin / unpin |
| ⌘⌫ | delete the clip |
| ⇥ / ⇧⇥ | next / previous group (All, Pinned, your groups) |
| ⎋ | clear the search, then close |
| ⌘, | settings |

Right-click a clip for the same actions and to move it into a group. Right-click a group to rename
or delete it (its clips go back to the history).

## Build

Needs macOS 14 or later and Xcode 15 or later (developed with Xcode 27.2).

```sh
swift test                      # unit tests
scripts/build-app.sh            # build/Kopi.app and build/Kopi.zip, universal binary
scripts/make-dmg.sh             # build/Kopi-<version>.dmg from build/Kopi.app
```

Move `build/Kopi.app` to `/Applications` and open it. The first launch shows a short welcome.

### Permissions

Kopi needs two permissions. Settings › General shows the state of both, with a button that opens
the right page in System Settings.

1. **Paste from Other Apps** (macOS 15.4 and later). By default macOS asks every time an app reads
   what another app copied. In System Settings › Privacy & Security › Paste from Other Apps, set
   Kopi to **Always Allow**, then relaunch Kopi (macOS applies the change after a relaunch). Until
   then Kopi records nothing, and its menu bar icon shows a warning.
2. **Accessibility**, so Kopi can press ⌘V in the app you were using. Without it, choosing a clip
   only puts it on the clipboard, and you press ⌘V yourself.

### Keep permissions across rebuilds

macOS ties these permissions to the app's code signature. An ad-hoc signed build (the default) gets
a new signature every time, so you would have to allow it again after each rebuild. Signing with a
fixed identity avoids that. A self-signed certificate is enough:

1. Keychain Access › Certificate Assistant › Create a Certificate…, name `Kopi Local Signing`,
   type **Code Signing**.
2. `KOPI_SIGN_IDENTITY="Kopi Local Signing" scripts/build-app.sh`

## Releasing

Push a version tag:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The [Release workflow](.github/workflows/release.yml) runs the tests, builds the universal app,
packs `Kopi-0.2.0.dmg` and `Kopi-0.2.0.zip`, publishes them as a GitHub release with checksums,
and updates the Homebrew cask in [vodorod-11/homebrew-tap](https://github.com/vodorod-11/homebrew-tap)
from [packaging/homebrew/kopi.rb](packaging/homebrew/kopi.rb).

Repository secrets that switch on the optional steps:

| Secret | For |
| --- | --- |
| `HOMEBREW_TAP_TOKEN` | a token that can push to `vodorod-11/homebrew-tap` (fine-grained, Contents: read and write) |
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY` | signing with a fixed certificate (base64 of the `.p12`, its password, the certificate name) |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | notarization, which needs a paid Apple Developer account and a Developer ID Application certificate |

Without signing secrets a release is signed ad-hoc. It works, but macOS forgets Kopi's permissions
after every update, and Gatekeeper asks for "Open Anyway" on first launch. Signing every release
with the same certificate keeps the permissions; notarization also removes the Gatekeeper step.

## Where things are

- History: `~/Library/Application Support/Kopi/kopi.sqlite`. Set `KOPI_DATABASE` to use another
  file, for example for testing.
- Settings: `defaults read io.github.vodorod-11.kopi`

## Code

| Path | What |
| --- | --- |
| `Sources/KopiCore` | storage (SQLite), clip model, search and thumbnails; no AppKit, unit-tested |
| `Sources/Kopi` | the app: pasteboard monitor, popup, global shortcut, paste, settings, menu bar |
| `Tests/KopiCoreTests` | store tests: dedupe, search, limits, groups, images, files |
| `Tests/KopiTests` | pasteboard round trips on private pasteboards, shortcut names, the hold gesture |
| `scripts/build-app.sh` | builds and signs the `.app` bundle |
| `scripts/make-icon.swift` | draws `Resources/AppIcon.icns` |

macOS has no clipboard-change notification, so Kopi polls the pasteboard's change count every
0.3 s. That is cheap, and reading the change count never triggers the privacy prompt. The popup is
a non-activating panel, so the app you were typing in stays active and receives the ⌘V.

## Not yet

- Sending clips to other Macs (Ditto's "friends")
- Editing clips and saved text snippets
- Global shortcuts that paste clip N without opening the popup

## License

Copyright © 2026 the Kopi authors.

Kopi is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at
your option) any later version. It is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE. See [LICENSE](LICENSE) for the full text.
